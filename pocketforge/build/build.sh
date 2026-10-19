#!/bin/bash
# One-step PocketForge build of MBHaxe from pinned inputs:
#   pinned Haxe/haxelibs/forks (../setup-deps.sh) -> Debian bookworm sysroot (sysroot.sh)
#   -> libhl + hdlls (hashlink, WITH_SDL_GLES=ON, WITH_HL_JIT=OFF) -> Haxe->C -> marblegame
#   -> ABI gates (gates.sh) -> deterministic tarball + manifest.
#
# usage: pocketforge/build/build.sh --arch <aarch64|x86_64> [--variant product|diag]
#                                   [--work DIR] [--out DIR] [--jobs N] [--require-clean] [--app-root]
#   --variant diag   adds -D pf_diag (regression-harness build: autoplay, screenshots, GL error count)
#   --work DIR       caches and intermediates (default <repo>/.pf-build, gitignored)
#   --out DIR        artifacts (default WORK/out)
#   --require-clean  refuse a dirty MBHaxe tree (release builds; CI)
#   --app-root       also assemble the PocketForge app root (app-root.sh: bundled libraries,
#                    launch, app.toml) from the artifact, cross-checked against this sysroot
#
# Runs in the builder container (container.sh, CI) or directly on a Linux host with apt-get,
# dpkg-deb, cmake, ninja, git, curl, zstd and a gcc for the target. The container is the
# reference: its bookworm gcc 12 is what the recorded hashes come from.
#
# Output: OUT/mbhaxe-pf-<version>-<arch>[-diag].tar.zst (one top-level dir "mbhaxe-pf/"),
# the same name with .manifest.json and .tar.zst.sha256, and OUT/<arch>-<variant>.env with
# machine-readable results (also printed last). With --app-root, also app-root.sh's outputs
# (OUT/org.pocketforge.mbhaxe-<version>-<arch>[-diag].app.tar.zst, OUT/<arch>-<variant>.app.env).
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"
REPO=$(cd "$PF_BUILD_DIR/../.." && pwd -P)
# In the builder container the checkout belongs to another uid (CI runner, rootless mapping).
if [ -n "${PF_IN_BUILDER_CONTAINER:-}" ]; then
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
fi

ARCH='' VARIANT=product WORK='' OUT='' JOBS=$(nproc) REQUIRE_CLEAN=0 APP_ROOT=0
while [ $# -gt 0 ]; do
	case $1 in
	--arch) ARCH=$2; shift 2 ;;
	--variant) VARIANT=$2; shift 2 ;;
	--work) WORK=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--jobs) JOBS=$2; shift 2 ;;
	--require-clean) REQUIRE_CLEAN=1; shift ;;
	--app-root) APP_ROOT=1; shift ;;
	-h | --help) sed -n '2,23p' "$0"; exit 0 ;;
	*) pf_die "unknown argument: $1" ;;
	esac
done
pf_arch_info "$ARCH" > /dev/null # dies on an unknown arch
read -r DEBARCH TRIPLE _ <<< "$(pf_arch_info "$ARCH")"
case $VARIANT in product) HXFLAGS=() SUFFIX= ;; diag) HXFLAGS=(-D pf_diag) SUFFIX=-diag ;;
*) pf_die "unknown variant: $VARIANT" ;; esac
WORK=${WORK:-$REPO/.pf-build}
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
OUT=${OUT:-$WORK/out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
T0=$(date +%s)

# --- source identity -----------------------------------------------------------------------
cd "$REPO"
MB_SHA=$(git rev-parse HEAD)
DIRTY=false
[ -z "$(git status --porcelain --untracked-files=normal)" ] || DIRTY=true
[ "$DIRTY" = false ] || [ "$REQUIRE_CLEAN" = 0 ] || { git status --short >&2; pf_die "MBHaxe tree is dirty (--require-clean)"; }
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct HEAD)
export SOURCE_DATE_EPOCH
UPSTREAM_VERSION=$(sed -n 's/.*static var currentVersion = "\([0-9.]*\)".*/\1/p' src/MarbleGame.hx)
[ -n "$UPSTREAM_VERSION" ] || pf_die "cannot read currentVersion from src/MarbleGame.hx"
VERSION=$UPSTREAM_VERSION-pf.$(TZ=UTC0 date -d "@$SOURCE_DATE_EPOCH" +%Y%m%d).${MB_SHA:0:10}
[ "$DIRTY" = false ] || VERSION=$VERSION.dirty
NAME=mbhaxe-pf-$VERSION-$ARCH$SUFFIX
pf_log "building $NAME (work $WORK)"

# --- pinned Haxe toolchain, haxelibs and forks ----------------------------------------------
"$REPO/pocketforge/setup-deps.sh" "$WORK/deps" > "$WORK/setup-deps.log" 2>&1 || { tail -20 "$WORK/setup-deps.log" >&2; pf_die "setup-deps.sh failed"; }
# shellcheck disable=SC1091
. "$WORK/deps/env.sh"
. "$REPO/pocketforge/deps.lock"
HL_SRC=$WORK/deps/src/hashlink
HEAPS_SRC=$WORK/deps/src/heaps
[ "$(git -C "$HL_SRC" rev-parse HEAD)" = "$HASHLINK_SHA" ] || pf_die "hashlink checkout is not $HASHLINK_SHA"
[ "$(git -C "$HEAPS_SRC" rev-parse HEAD)" = "$HEAPS_SHA" ] || pf_die "heaps checkout is not $HEAPS_SHA"

# --- sysroot and toolchain wrapper ----------------------------------------------------------
"$PF_BUILD_DIR/sysroot.sh" "$DEBARCH" "$WORK/sysroot-$DEBARCH"
SR=$WORK/sysroot-$DEBARCH/root
TC=$WORK/toolchain-$ARCH
pf_write_toolchain "$TRIPLE" "$SR" "$TC"
CC=$TC/cc
BASE_CC=$(cat "$TC/base-cc")
CC_VERSION=$("$BASE_CC" --version | head -1)
pf_log "compiler: $CC_VERSION"
# Build paths must not leak into the binaries (__FILE__ in libhl/hdlls).
PREFIX_MAP="-ffile-prefix-map=$WORK=/pf/work -ffile-prefix-map=$REPO=/pf/MBHaxe"

# --- hashlink: libhl + hdlls ----------------------------------------------------------------
HL_BUILD=$WORK/build/hl-$ARCH HL_INST=$WORK/build/hl-$ARCH-install
rm -rf "$HL_BUILD" "$HL_INST"
cmake -S "$HL_SRC" -B "$HL_BUILD" -G Ninja \
	-DCMAKE_TOOLCHAIN_FILE="$TC/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_INSTALL_PREFIX="$HL_INST" \
	-DBUILD_TESTING=OFF -DWITH_SQLITE=OFF -DWITH_VIDEO=OFF -DWITH_SDL_GLES=ON -DWITH_HL_JIT=OFF \
	> "$WORK/hl-$ARCH-configure.log" 2>&1 || { tail -30 "$WORK/hl-$ARCH-configure.log" >&2; pf_die "hashlink configure failed"; }
cmake --build "$HL_BUILD" -j "$JOBS" > "$WORK/hl-$ARCH-build.log" 2>&1 || { tail -30 "$WORK/hl-$ARCH-build.log" >&2; pf_die "hashlink build failed"; }
cmake --install "$HL_BUILD" > /dev/null

# --- Haxe -> C ------------------------------------------------------------------------------
GEN=$WORK/gen/$ARCH-$VARIANT
rm -rf "$GEN"
mkdir -p "$GEN"
# Same hxml, output redirected out of the source tree (Haxe refuses a second -hl on the CLI).
grep -vE '^[[:space:]]*--?hl[[:space:]]' compile-linux-gles.hxml > "$GEN/build.hxml"
echo "-hl $GEN/marblegame.c" >> "$GEN/build.hxml"
haxe "$GEN/build.hxml" "${HXFLAGS[@]}" > "$WORK/haxe-$ARCH-$VARIANT.log" 2>&1 || { tail -30 "$WORK/haxe-$ARCH-$VARIANT.log" >&2; pf_die "haxe failed"; }
GEN_SHA=$(cd "$GEN" && find . -type f ! -name build.hxml -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)

# --- marblegame -----------------------------------------------------------------------------
STAGE=$WORK/stage/$ARCH-$VARIANT/mbhaxe-pf
rm -rf "$(dirname "$STAGE")"
mkdir -p "$STAGE/licenses"
cp "$HL_INST/lib/libhl.so.1" "$STAGE/libhl.so.1" # dereferences libhl.so.1 -> libhl.so.1.x.y
for h in fmt openal sdl ssl ui uv; do cp "$HL_INST/lib/$h.hdll" "$STAGE/"; done
# shellcheck disable=SC2086
"$CC" -O2 -std=c11 -D_GNU_SOURCE -fno-strict-aliasing $PREFIX_MAP \
	-I "$GEN" -I "$HL_SRC/src" -c -o "$WORK/build/marblegame-$ARCH-$VARIANT.o" "$GEN/marblegame.c" \
	2> "$WORK/cc-$ARCH-$VARIANT.log" || { tail -30 "$WORK/cc-$ARCH-$VARIANT.log" >&2; pf_die "marblegame compile failed"; }
"$CC" -o "$STAGE/marblegame" "$WORK/build/marblegame-$ARCH-$VARIANT.o" \
	"$STAGE/ui.hdll" "$STAGE/openal.hdll" "$STAGE/fmt.hdll" "$STAGE/sdl.hdll" "$STAGE/uv.hdll" "$STAGE/ssl.hdll" \
	"$STAGE/libhl.so.1" -lSDL2-2.0 -luv -lm -lpthread -Wl,-rpath,'$ORIGIN' -Wl,--as-needed \
	2>> "$WORK/cc-$ARCH-$VARIANT.log" || { tail -30 "$WORK/cc-$ARCH-$VARIANT.log" >&2; pf_die "marblegame link failed"; }

# Licences of everything compiled into the shipped binaries.
cp LICENSE "$STAGE/licenses/MBHaxe.txt"
cp "$HL_SRC/LICENSE" "$STAGE/licenses/hashlink.txt"
cp "$HL_SRC/include/mbedtls/LICENSE" "$STAGE/licenses/mbedtls.txt"   # ssl.hdll (static)
cp "$HL_SRC/include/mbedtls/apache-2.0.txt" "$STAGE/licenses/mbedtls-apache-2.0.txt"
cp "$HL_SRC/include/minimp3/LICENSE" "$STAGE/licenses/minimp3.txt"   # fmt.hdll
cp "$HEAPS_SRC/LICENSE" "$STAGE/licenses/heaps.txt"
cp "$WORK/deps/toolchain/haxe/LICENSE.txt" "$STAGE/licenses/haxe.txt" # Haxe standard library
cp "$HAXELIB_PATH"/colyseus-websocket/*/LICENSE "$STAGE/licenses/colyseus-websocket.txt"
# The format haxelib zip carries no licence file: upstream's BSD-2 LICENSE (HaxeFoundation/format
# 914c2fa2) is committed here. stubs/datachannel copies hxDatachannel classes (MIT, its LICENSE).
cp "$PF_BUILD_DIR/licenses/haxe-format.txt" "$STAGE/licenses/haxe-format.txt"
cp stubs/datachannel/LICENSE "$STAGE/licenses/hxDatachannel.txt"

# --- gates ----------------------------------------------------------------------------------
GATES_OUT=$("$PF_BUILD_DIR/gates.sh" --arch "$ARCH" "$STAGE") || { echo "$GATES_OUT" >&2; pf_die "ABI gates failed"; }
echo "$GATES_OUT" >&2
GATES_SUMMARY=$(echo "$GATES_OUT" | tail -1)
MAX_GLIBC=$(echo "$GATES_SUMMARY" | sed -n 's/.* max_glibc=\([^ ]*\).*/\1/p')
NEEDED=$(echo "$GATES_SUMMARY" | sed -n 's/.* needed=\([^ ]*\).*/\1/p')

# --- manifest -------------------------------------------------------------------------------
if [ -f /etc/pf-builder-packages.txt ]; then
	BUILDER="container" BUILDER_BASE=$(cat /etc/pf-builder-base-image)
	BUILDER_PKGS=$(pf_sha256 /etc/pf-builder-packages.txt)
else
	BUILDER="host" BUILDER_BASE="none" BUILDER_PKGS="none"
fi
(cd "$STAGE" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort | xargs sha256sum) > "$STAGE/SHA256SUMS"
{
	printf '{\n  "schema": "pocketforge.mbhaxe-build-manifest/v1",\n'
	printf '  "name": "mbhaxe-pf",\n  "version": "%s",\n  "arch": "%s",\n  "variant": "%s",\n' "$VERSION" "$ARCH" "$VARIANT"
	printf '  "source_date_epoch": %s,\n' "$SOURCE_DATE_EPOCH"
	printf '  "sources": {\n'
	printf '    "MBHaxe": {"repo": "https://github.com/pocketforge-os/MBHaxe", "commit": "%s", "dirty": %s},\n' "$MB_SHA" "$DIRTY"
	printf '    "hashlink": {"repo": "%s", "commit": "%s"},\n' "${HASHLINK_REPO%.git}" "$HASHLINK_SHA"
	printf '    "heaps": {"repo": "%s", "commit": "%s"},\n' "${HEAPS_REPO%.git}" "$HEAPS_SHA"
	printf '    "haxe": {"url": "%s", "sha256": "%s"},\n' "$HAXE_URL" "$HAXE_SHA256"
	printf '    "neko": {"url": "%s", "sha256": "%s"},\n' "$NEKO_URL" "$NEKO_SHA256"
	printf '    "format": {"url": "%s", "sha256": "%s"},\n' "$FORMAT_ZIP_URL" "$FORMAT_ZIP_SHA256"
	printf '    "colyseus-websocket": {"url": "%s", "sha256": "%s"}\n  },\n' "$COLYSEUS_WEBSOCKET_ZIP_URL" "$COLYSEUS_WEBSOCKET_ZIP_SHA256"
	printf '  "locks": {"LOCK.md": "%s", "pocketforge/deps.lock": "%s", "pocketforge/build/pins.lock": "%s"},\n' \
		"$(pf_sha256 LOCK.md)" "$(pf_sha256 pocketforge/deps.lock)" "$(pf_sha256 "$PF_BUILD_DIR/pins.lock")"
	printf '  "toolchain": {"builder": "%s", "base_image": "%s", "builder_packages_sha256": "%s", "debian_snapshot": "%s", "cc": "%s", "haxe": "%s"},\n' \
		"$BUILDER" "$BUILDER_BASE" "$BUILDER_PKGS" "$PF_DEBIAN_SNAPSHOT" "$CC_VERSION" "$(haxe --version)"
	printf '  "sysroot": {"debian_arch": "%s", "debs": %s, "debs_sha256_list_sha256": "%s"},\n' \
		"$DEBARCH" "$(wc -l < "$WORK/sysroot-$DEBARCH/debs.sha256")" "$(pf_sha256 "$WORK/sysroot-$DEBARCH/debs.sha256")"
	printf '  "generated_c_tree_sha256": "%s",\n' "$GEN_SHA"
	printf '  "gates": {"status": "PASS", "max_glibc": "%s", "needed": "%s"},\n' "$MAX_GLIBC" "$NEEDED"
	printf '  "files": [\n'
	sep=
	while read -r sum path; do
		printf '%s    {"path": "%s", "sha256": "%s", "size": %s}' "$sep" "$path" "$sum" "$(stat -c %s "$STAGE/$path")"
		sep=$',\n'
	done < "$STAGE/SHA256SUMS"
	printf '\n  ]\n}\n'
} > "$STAGE/MANIFEST.json"

# --- deterministic tarball ------------------------------------------------------------------
TARBALL=$OUT/$NAME.tar.zst
(cd "$(dirname "$STAGE")" && tar --sort=name --format=gnu --mtime="@$SOURCE_DATE_EPOCH" \
	--owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' -cf - mbhaxe-pf) \
	| zstd -q -19 -T1 > "$TARBALL.tmp"
mv "$TARBALL.tmp" "$TARBALL"
cp "$STAGE/MANIFEST.json" "$OUT/$NAME.manifest.json"
(cd "$OUT" && sha256sum "$NAME.tar.zst" > "$NAME.tar.zst.sha256")

RESULT=$OUT/$ARCH-$VARIANT.env
cat > "$RESULT" <<EOF
name=$NAME
version=$VERSION
arch=$ARCH
variant=$VARIANT
artifact=$TARBALL
artifact_sha256=$(pf_sha256 "$TARBALL")
manifest=$OUT/$NAME.manifest.json
manifest_sha256=$(pf_sha256 "$OUT/$NAME.manifest.json")
stage=$STAGE
marblegame_sha256=$(pf_sha256 "$STAGE/marblegame")
generated_c_tree_sha256=$GEN_SHA
max_glibc=$MAX_GLIBC
builder=$BUILDER
mbhaxe_commit=$MB_SHA
dirty=$DIRTY
seconds=$(($(date +%s) - T0))
EOF
cat "$RESULT"
if [ "$APP_ROOT" = 1 ]; then
	"$PF_BUILD_DIR/app-root.sh" --build "$RESULT" --work "$WORK" --out "$OUT" \
		--sysroot-debs "$WORK/sysroot-$DEBARCH/debs.sha256"
fi
