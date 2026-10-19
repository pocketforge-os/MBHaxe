#!/bin/bash
# CI entry point for the regression harness (forge-neutral, tsp-0qwbh.8). Runs as root in the
# builder job container (PF_BASE_IMAGE after pocketforge/build/toolchain.sh) AFTER
# `pocketforge/build/ci.sh x86_64 diag WORK` has built the harness binary into WORK.
#
# usage: tests/pf-harness/ci.sh WORK
#
#   1. builds the aarch64 product binary (build.sh --require-clean) for the qemu-aarch64 smoke,
#      reusing WORK (its arm64 sysroot is the smoke's library root);
#   2. installs the harness runtime from the same pinned Debian snapshot (bookworm: cage 0.1.4 +
#      Xwayland as the headless compositor, Mesa 22.3 zink + lavapipe, strace, qemu-user-static,
#      the game's shared libraries). Not weston: bookworm's weston 10 headless backend has no
#      wl_seat and bookworm's SDL 2.26.5 crashes in Wayland_InitMouse without one (run.sh);
#   3. fetches the game data with pocketforge/app/pf-fetch.py, exactly as app.toml [fetch] pins it
#      (upstream release URL, SHA256, size), into WORK; the data is never committed, cached or
#      uploaded, and is deleted again at the end;
#   4. runs tests/pf-harness/run.sh on the x86_64 diag build with the arm64 smoke, as an
#      unprivileged user (cage refuses root; the game has no business running as root anyway);
#   5. prints the evidence to the job log (no artifact upload: the screenshots are game-derived
#      imagery and nothing is stored on the forge): PASS/FAIL lines, pngcheck output, screenshot
#      sha256s, version lines and, on failure or an early exit, the log tails and the exit() caller.
# Exit status: run.sh's (0 only on RESULT PASS).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
WORK=${1:?usage: tests/pf-harness/ci.sh WORK}
WORK=$(cd "$WORK" && pwd -P)
export PF_IN_BUILDER_CONTAINER=1
[ "$(id -u)" = 0 ] || { echo "error: run as root in the builder job container" >&2; exit 1; }
[ -f /etc/pf-builder-packages.txt ] || { echo "error: not a builder container (run pocketforge/build/toolchain.sh)" >&2; exit 1; }

X86=$WORK/stage/x86_64-diag/mbhaxe-pf
[ -x "$X86/marblegame" ] || { echo "error: no x86_64 diag build in $WORK (run pocketforge/build/ci.sh x86_64 diag WORK first)" >&2; exit 1; }

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

# ---- 1. aarch64 build for the qemu smoke ------------------------------------------------------
group "aarch64 product build (qemu smoke input)"
"$REPO/pocketforge/build/build.sh" --arch aarch64 --variant product --work "$WORK" --out "$WORK/out" --require-clean
endgroup
ARM=$WORK/stage/aarch64-product/mbhaxe-pf
ARM_SYSROOT=$WORK/sysroot-arm64/root

# ---- 2. harness runtime from the pinned snapshot ----------------------------------------------
# The game's DT_NEEDED closure (marblegame, libhl, hdlls) plus the harness tools (libc6-dev:
# headers for the es3strict shim, which run.sh compiles with gcc-12; xwayland: cage 0.1.4 will not
# start without the binary, though no X client ever connects). Versions come from
# PF_DEBIAN_SNAPSHOT via the apt sources toolchain.sh wrote.
HARNESS_PACKAGES="cage xwayland mesa-vulkan-drivers libgl1-mesa-dri libegl1 libegl-mesa0 libgles2
  libsdl2-2.0-0 libopenal1 libuv1 libturbojpeg0 libvorbisfile3 libpng16-16 zlib1g
  strace python3 qemu-user-static libc6-dev"
group "harness runtime packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# shellcheck disable=SC2086
apt-get -y install $HARNESS_PACKAGES
apt-get clean
rm -rf /var/lib/apt/lists/*
endgroup
for p in cage libwlroots10 libgl1-mesa-dri mesa-vulkan-drivers libsdl2-2.0-0 strace qemu-user-static python3; do
	echo "harness_package $(dpkg-query -W -f='${Package} ${Version}' "$p")"
done

# ---- 3. game data: pinned fetch only ----------------------------------------------------------
DATA_ROOT=$WORK/harness-data
OUT=$WORK/harness-out
rm -rf "$DATA_ROOT" "$OUT"
mkdir -p "$DATA_ROOT"
# The unprivileged harness user must reach the inputs: make WORK's ancestors traversable (this is
# a throwaway job container) and give it the output directory.
HUSER=pfharness
id -u "$HUSER" >/dev/null 2>&1 || useradd --system --create-home --user-group "$HUSER"
for d in "$WORK" "$REPO"; do
	while [ "$d" != / ]; do chmod o+x "$d"; d=$(dirname "$d"); done
done
chmod -R o+rX "$WORK/stage" "$ARM_SYSROOT" "$DATA_ROOT" "$HERE"
install -d -o "$HUSER" -g "$HUSER" "$OUT"
cleanup() { rm -rf "$DATA_ROOT" "$OUT/game/data" "$OUT/game-arm64/data"; }
trap cleanup EXIT
python3 -I "$REPO/pocketforge/app/pf-fetch.py" --app-toml "$REPO/pocketforge/app/app.toml" --root "$DATA_ROOT"

# ---- 4. harness --------------------------------------------------------------------------------
echo "x86_64-diag marblegame sha256 $(sha256sum "$X86/marblegame" | cut -d' ' -f1)"
echo "aarch64-product marblegame sha256 $(sha256sum "$ARM/marblegame" | cut -d' ' -f1)"
rc=0
setpriv --reuid="$HUSER" --regid="$HUSER" --init-groups \
	env HOME="$(getent passwd "$HUSER" | cut -d: -f6)" CC="${CC:-gcc-12}" "$HERE/run.sh" --out "$OUT" --timeout "${PF_HARNESS_TIMEOUT:-1200}" \
	--arm64-game "$ARM" --arm64-sysroot "$ARM_SYSROOT" "$X86" "$DATA_ROOT/data" | tee "$WORK/harness-result.txt" || rc=$?

# ---- 5. evidence in the job log ------------------------------------------------------------------
for f in "$OUT"/pngcheck-*.txt; do
	if [ -f "$f" ]; then sed "s|^|$(basename "$f" .txt): |" "$f"; fi
done
for f in "$OUT"/shots/*.png; do
	if [ -f "$f" ]; then echo "screenshot $(basename "$f") sha256 $(sha256sum "$f" | cut -d' ' -f1)"; fi
done
LOG=$OUT/game-all.log
if [ -f "$LOG" ]; then
	grep -E '^(GL_|\[diag\] (loaded|autoplay|exit)|\[es3strict\] (loaded|violations|exit))' "$LOG" | head -n 20 || true
fi
if grep -q 'no-diag-exit-line' "$WORK/harness-result.txt"; then
	echo "early_exit=yes (tsp-0qwbh.3 finding 4 signature: no '[diag] exit at frame' line)"
	grep -E '^info (exit\(\)|no exit)' "$WORK/harness-result.txt" || true
	if [ -f "$LOG" ]; then sed -n '/^\[es3strict\] exit(/,/^\[es3strict\] violations/p' "$LOG" | head -n 40 || true; fi
else
	echo "early_exit=no"
fi
if [ "$rc" != 0 ]; then
	for f in game.out console.log weston.log qemu-arm64.out es3strict-build.log; do
		[ -f "$OUT/$f" ] || continue
		group "tail $f"
		tail -n 60 "$OUT/$f"
		endgroup
	done
fi
echo "harness_rc=$rc"
exit "$rc"
