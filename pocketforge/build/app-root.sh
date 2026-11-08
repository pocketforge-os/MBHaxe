#!/bin/bash
# Assemble the PocketForge app root for MBHaxe (tsp-0qwbh.5) from one build.sh artifact:
#   build tarball (sha256 + inner SHA256SUMS verified) + bundled Debian libraries
#   (../app/bundle.lock, pinned .debs from the snapshot) + launch, app.toml, alsoft.conf
#   -> ABI and NEEDED-closure gates -> deterministic tarball + APP-MANIFEST.json.
#
# usage: pocketforge/build/app-root.sh --build ENV [--work DIR] [--out DIR] [--sysroot-debs FILE]
#   --build ENV          OUT/<arch>-<variant>.env written by build.sh (paths in it may be the
#                        builder container's /out; the artifact is then looked up next to ENV)
#   --work DIR           .deb cache and staging (default: the directory of ENV)
#   --out DIR            artifacts (default: the directory of ENV)
#   --sysroot-debs FILE  the build sysroot's debs.sha256: every bundled .deb must be listed in
#                        it, so the bundled library is the one marblegame was linked against
#                        (build.sh --app-root passes it)
#
# Output: OUT/org.pocketforge.mbhaxe-<build version>-<arch>[-diag].app.tar.zst (one top-level dir
# "org.pocketforge.mbhaxe/", the app directory /opt/pocketforge/apps/org.pocketforge.mbhaxe on the
# device), the same name with .manifest.json and .tar.zst.sha256, and OUT/<arch>-<variant>.app.env.
# The game data is not in it: the app's [fetch] (app.toml, ../app/pf-fetch.py) installs data/.
# Needs bash, coreutils, curl, dpkg-deb, readelf, tar and zstd (all in the builder container).
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"
APP_SRC=$(cd "$PF_BUILD_DIR/../app" && pwd)
APP_ID=org.pocketforge.mbhaxe

ENV_FILE='' WORK='' OUT='' SYSROOT_DEBS=''
while [ $# -gt 0 ]; do
	case $1 in
	--build) ENV_FILE=$2; shift 2 ;;
	--work) WORK=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--sysroot-debs) SYSROOT_DEBS=$2; shift 2 ;;
	-h | --help) sed -n '2,20p' "$0"; exit 0 ;;
	*) pf_die "unknown argument: $1" ;;
	esac
done
[ -f "$ENV_FILE" ] || pf_die "--build ENV is required (build.sh's OUT/<arch>-<variant>.env)"
ENV_DIR=$(cd "$(dirname "$ENV_FILE")" && pwd -P)
WORK=${WORK:-$ENV_DIR}
OUT=${OUT:-$ENV_DIR}
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd -P)
OUT=$(cd "$OUT" && pwd -P)
[ -z "$SYSROOT_DEBS" ] || [ -f "$SYSROOT_DEBS" ] || pf_die "no such file: $SYSROOT_DEBS"

envget() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1; }
ARCH=$(envget arch) VARIANT=$(envget variant) VERSION=$(envget version) BUILD_NAME=$(envget name)
ARTIFACT_SHA=$(envget artifact_sha256)
read -r _ TRIPLE _ <<< "$(pf_arch_info "$ARCH")"
case $VARIANT in product) SUFFIX= ;; diag) SUFFIX=-diag ;; *) pf_die "unknown variant in $ENV_FILE: $VARIANT" ;; esac
ARTIFACT=$(envget artifact)
[ -f "$ARTIFACT" ] || ARTIFACT=$ENV_DIR/$(basename "$ARTIFACT")
[ -f "$ARTIFACT" ] || pf_die "build artifact not found: $(envget artifact)"
NAME=$APP_ID-$VERSION-$ARCH$SUFFIX
pf_log "assembling $NAME from $(basename "$ARTIFACT")"

# --- verify and unpack the build artifact ---------------------------------------------------
[ "$(pf_sha256 "$ARTIFACT")" = "$ARTIFACT_SHA" ] || pf_die "artifact sha256 differs from $ENV_FILE"
if [ -f "$ARTIFACT.sha256" ]; then
	[ "$(cut -d' ' -f1 "$ARTIFACT.sha256")" = "$ARTIFACT_SHA" ] || pf_die "artifact sha256 differs from $ARTIFACT.sha256"
fi
W=$WORK/app-root/$ARCH-$VARIANT
rm -rf "$W"
mkdir -p "$W/build" "$W/debs"
zstd -dc "$ARTIFACT" | tar -xf - -C "$W/build"
[ "$(ls -A "$W/build")" = mbhaxe-pf ] || pf_die "artifact does not hold exactly one top-level mbhaxe-pf/"
B=$W/build/mbhaxe-pf
(cd "$B" && sha256sum --quiet --strict -c SHA256SUMS) || pf_die "artifact SHA256SUMS does not verify"
extra=$(cd "$B" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.json | sed 's|^\./||' | LC_ALL=C sort \
	| comm -23 - <(awk '{print $2}' "$B/SHA256SUMS" | LC_ALL=C sort))
[ -z "$extra" ] || pf_die "artifact files outside SHA256SUMS: $extra"
SOURCE_DATE_EPOCH=$(sed -n 's/^ *"source_date_epoch": *\([0-9]*\),.*/\1/p' "$B/MANIFEST.json")
[ -n "$SOURCE_DATE_EPOCH" ] || pf_die "no source_date_epoch in the build manifest"
MB_SHA=$(sed -n 's/.*"MBHaxe": {[^}]*"commit": "\([0-9a-f]*\)".*/\1/p' "$B/MANIFEST.json")

# --- app directory --------------------------------------------------------------------------
S=$W/stage/$APP_ID
mkdir -p "$S/lib" "$S/licenses/debian"
(cd "$B" && find . -type f ! -name SHA256SUMS ! -name MANIFEST.json -print0 | xargs -0 cp --parents -t "$S")
cp "$B/MANIFEST.json" "$S/BUILD-MANIFEST.json"
cp "$APP_SRC/app.toml" "$APP_SRC/alsoft.conf" "$S/"
install -m 0755 "$APP_SRC/launch" "$S/launch"
install -m 0755 "$PF_BUILD_DIR/../../tests/pf-probe/probe-launch" "$S/probe-launch" # tsp-0qwbh.10
APP_VERSION=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$APP_SRC/app.toml" | head -1)
grep -q "^id = \"$APP_ID\"$" "$APP_SRC/app.toml" || pf_die "app.toml [app].id is not $APP_ID"

# --- bundled Debian libraries ---------------------------------------------------------------
BUNDLE_JSON=$W/bundle.json
: > "$BUNDLE_JSON"
DEB_CACHE=$WORK/app-debs
mkdir -p "$DEB_CACHE"
n=0
while read -r arch pkg ver sha size soname pool; do
	case $arch in '' | '#'*) continue ;; esac
	[ "$arch" = "$ARCH" ] || continue
	deb=$DEB_CACHE/$sha.deb
	if [ ! -f "$deb" ] || [ "$(pf_sha256 "$deb")" != "$sha" ]; then
		url=http://snapshot.debian.org/archive/debian/$PF_DEBIAN_SNAPSHOT/$pool
		curl -fsSL --retry 5 -o "$deb.tmp" "$url" || pf_die "download failed: $url"
		mv "$deb.tmp" "$deb"
	fi
	[ "$(pf_sha256 "$deb")" = "$sha" ] || pf_die "$pkg: .deb sha256 mismatch (want $sha)"
	[ "$(stat -c %s "$deb")" = "$size" ] || pf_die "$pkg: .deb size mismatch (want $size)"
	if [ -n "$SYSROOT_DEBS" ]; then
		grep -q "^$sha " "$SYSROOT_DEBS" || pf_die "$pkg $ver ($sha) is not the .deb in the build sysroot"
	fi
	x=$W/debs/$pkg
	dpkg-deb -x "$deb" "$x"
	if [ "$(dpkg-deb -f "$deb" Package)" != "$pkg" ] || [ "$(dpkg-deb -f "$deb" Version)" != "$ver" ]; then
		pf_die "$pkg: control fields do not match bundle.lock"
	fi
	src=$x/usr/lib/$TRIPLE/$soname
	[ -e "$src" ] || pf_die "$pkg: $soname not in usr/lib/$TRIPLE"
	cp -L "$src" "$S/lib/$soname"
	# The file is named as the dependants' DT_NEEDED; its own SONAME can differ (Debian's
	# libsndio.so.7.0 compatibility name for SONAME libsndio.so.7). Recorded in the manifest.
	elf_soname=$(readelf -d -W "$S/lib/$soname" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
	[ -n "$elf_soname" ] || pf_die "$pkg: $soname has no SONAME"
	[ -f "$x/usr/share/doc/$pkg/copyright" ] || pf_die "$pkg: no usr/share/doc/$pkg/copyright"
	cp "$x/usr/share/doc/$pkg/copyright" "$S/licenses/debian/$pkg.copyright"
	[ "$n" = 0 ] || printf ',\n' >> "$BUNDLE_JSON"
	printf '    {"package": "%s", "version": "%s", "deb": "%s", "deb_sha256": "%s", "deb_size": %s, "file": "lib/%s", "file_sha256": "%s", "soname": "%s", "real_name": "%s", "copyright": "licenses/debian/%s.copyright"}' \
		"$pkg" "$ver" "$(basename "$pool")" "$sha" "$size" "$soname" "$(pf_sha256 "$S/lib/$soname")" "$elf_soname" \
		"$(basename "$(readlink -f "$src")")" "$pkg" >> "$BUNDLE_JSON"
	n=$((n + 1))
done < "$APP_SRC/bundle.lock"
[ "$n" -gt 0 ] || pf_die "bundle.lock has no rows for $ARCH"

# --- gates: ABI ceilings for every shipped ELF, and NEEDED closure ---------------------------
# Allowed = sonames the image provides (image-sonames.allow) + every ELF the app root ships.
ALLOW=$W/closure.allow
{
	cat "$APP_SRC/image-sonames.allow"
	for f in "$S"/* "$S"/lib/*; do
		[ -f "$f" ] && [ "$(od -An -tx1 -N4 "$f" | tr -d ' ')" = 7f454c46 ] && echo "* $(basename "$f")"
	done
} > "$ALLOW"
GATES_TOP=$("$PF_BUILD_DIR/gates.sh" --arch "$ARCH" --allow "$ALLOW" "$S") || { echo "$GATES_TOP" >&2; pf_die "app root gates failed (top level)"; }
GATES_LIB=$("$PF_BUILD_DIR/gates.sh" --arch "$ARCH" --allow "$ALLOW" "$S/lib") || { echo "$GATES_LIB" >&2; pf_die "app root gates failed (lib/)"; }
printf '%s\n%s\n' "$GATES_TOP" "$GATES_LIB" >&2
NEEDED_TOP=$(echo "$GATES_TOP" | tail -1 | sed -n 's/.* needed=\([^ ]*\).*/\1/p')
NEEDED_LIB=$(echo "$GATES_LIB" | tail -1 | sed -n 's/.* needed=\([^ ]*\).*/\1/p')
MAX_GLIBC=$(printf '%s\n%s\n' "$(echo "$GATES_TOP" | tail -1 | sed -n 's/.* max_glibc=GLIBC_\([^ ]*\).*/\1/p')" \
	"$(echo "$GATES_LIB" | tail -1 | sed -n 's/.* max_glibc=GLIBC_\([^ ]*\).*/\1/p')" | sort -V | tail -1)
# Nothing is bundled that no shipped ELF needs.
for f in "$S"/lib/*; do
	case ",$NEEDED_TOP,$NEEDED_LIB," in *",$(basename "$f"),"*) ;; *) pf_die "bundled $(basename "$f") is not needed by any shipped ELF" ;; esac
done
# The sonames the device image must provide: every NEEDED the app root does not ship itself.
IMAGE_NEEDED=$(echo "$NEEDED_TOP,$NEEDED_LIB" | tr ',' '\n' | LC_ALL=C sort -u | while read -r so; do
	[ -z "$so" ] || [ -e "$S/$so" ] || [ -e "$S/lib/$so" ] || echo "$so"
done | tr '\n' ',' | sed 's/,$//')

# --- manifest -------------------------------------------------------------------------------
# Modes independent of the host umask: directories and executables 0755, other files 0644.
find "$S" -type d -exec chmod 0755 {} +
find "$S" -type f -perm /111 -exec chmod 0755 {} +
find "$S" -type f ! -perm /111 -exec chmod 0644 {} +
(cd "$S" && find . -type f ! -name SHA256SUMS ! -name APP-MANIFEST.json -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum) > "$S/SHA256SUMS"
{
	printf '{\n  "schema": "pocketforge.mbhaxe-app-root/v1",\n'
	printf '  "app_id": "%s",\n  "app_version": "%s",\n  "arch": "%s",\n  "variant": "%s",\n' "$APP_ID" "$APP_VERSION" "$ARCH" "$VARIANT"
	printf '  "source_date_epoch": %s,\n' "$SOURCE_DATE_EPOCH"
	printf '  "build": {"name": "%s", "version": "%s", "artifact": "%s", "artifact_sha256": "%s", "manifest_sha256": "%s", "mbhaxe_commit": "%s"},\n' \
		"$BUILD_NAME" "$VERSION" "$(basename "$ARTIFACT")" "$ARTIFACT_SHA" "$(pf_sha256 "$B/MANIFEST.json")" "$MB_SHA"
	printf '  "locks": {"pocketforge/app/bundle.lock": "%s", "pocketforge/app/image-sonames.allow": "%s", "pocketforge/app/app.toml": "%s"},\n' \
		"$(pf_sha256 "$APP_SRC/bundle.lock")" "$(pf_sha256 "$APP_SRC/image-sonames.allow")" "$(pf_sha256 "$APP_SRC/app.toml")"
	printf '  "debian_snapshot": "%s",\n' "$PF_DEBIAN_SNAPSHOT"
	printf '  "bundled": [\n%s\n  ],\n' "$(cat "$BUNDLE_JSON")"
	printf '  "gates": {"status": "PASS", "max_glibc": "GLIBC_%s", "needed_from_image": "%s"},\n' "$MAX_GLIBC" "$IMAGE_NEEDED"
	printf '  "data": "not included; installed by the app.toml [fetch] (pocketforge/app/pf-fetch.py)",\n'
	printf '  "files": [\n'
	sep=
	while read -r sum path; do
		printf '%s    {"path": "%s", "sha256": "%s", "size": %s, "mode": "%s"}' "$sep" "$path" "$sum" \
			"$(stat -c %s "$S/$path")" "$(stat -c %a "$S/$path")"
		sep=$',\n'
	done < "$S/SHA256SUMS"
	printf '\n  ]\n}\n'
} > "$S/APP-MANIFEST.json"

# --- deterministic tarball ------------------------------------------------------------------
TARBALL=$OUT/$NAME.app.tar.zst
(cd "$(dirname "$S")" && tar --sort=name --format=gnu --mtime="@$SOURCE_DATE_EPOCH" \
	--owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' -cf - "$APP_ID") \
	| zstd -q -19 -T1 > "$TARBALL.tmp"
mv "$TARBALL.tmp" "$TARBALL"
cp "$S/APP-MANIFEST.json" "$OUT/$NAME.app.manifest.json"
(cd "$OUT" && sha256sum "$NAME.app.tar.zst" > "$NAME.app.tar.zst.sha256")

RESULT=$OUT/$ARCH-$VARIANT.app.env
cat > "$RESULT" <<EOF
app_name=$NAME
app_id=$APP_ID
app_version=$APP_VERSION
build_version=$VERSION
arch=$ARCH
variant=$VARIANT
app_artifact=$TARBALL
app_artifact_sha256=$(pf_sha256 "$TARBALL")
app_manifest=$OUT/$NAME.app.manifest.json
app_manifest_sha256=$(pf_sha256 "$OUT/$NAME.app.manifest.json")
app_stage=$S
build_artifact_sha256=$ARTIFACT_SHA
bundled=$n
needed_from_image=$IMAGE_NEEDED
max_glibc=GLIBC_$MAX_GLIBC
EOF
cat "$RESULT"
