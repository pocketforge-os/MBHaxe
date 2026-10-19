#!/bin/bash
# CI entry point for the window step-1 device probe (forge-neutral, tsp-0qwbh.10). Runs as root in
# the builder job container AFTER `pocketforge/build/ci.sh x86_64 diag WORK` (which builds the
# x86_64 app root, pf-probe included) and normally after tests/pf-harness/ci.sh (which builds the
# aarch64 product stage; built here if it is missing).
#
# usage: tests/pf-probe/ci.sh WORK
#
#   1. installs the probe runtime from the pinned Debian snapshot (the same bookworm packages as
#      the regression harness: cage + Xwayland, Mesa 22.3 zink + lavapipe, SDL 2.26.5,
#      qemu-user-static);
#   2. runs tests/pf-probe/run.sh as an unprivileged user (cage refuses root) on the x86_64 app
#      root, with the aarch64 pf-probe and the arm64 build sysroot for the qemu-aarch64 smoke;
#   3. prints the probe hashes and every PROBE line to the job log. Nothing is uploaded and no
#      game data is involved.
# Exit status: run.sh's (0 only on RESULT PASS).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
WORK=${1:?usage: tests/pf-probe/ci.sh WORK}
WORK=$(cd "$WORK" && pwd -P)
export PF_IN_BUILDER_CONTAINER=1
[ "$(id -u)" = 0 ] || { echo "error: run as root in the builder job container" >&2; exit 1; }
[ -f /etc/pf-builder-packages.txt ] || { echo "error: not a builder container (run pocketforge/build/toolchain.sh)" >&2; exit 1; }

APP=$WORK/app-root/x86_64-diag/stage/org.pocketforge.mbhaxe
[ -x "$APP/pf-probe" ] || { echo "error: no x86_64 app root with pf-probe in $WORK (run pocketforge/build/ci.sh x86_64 diag WORK first)" >&2; exit 1; }
ARM=$WORK/stage/aarch64-product/mbhaxe-pf
if [ ! -x "$ARM/pf-probe" ]; then
	echo "::group::aarch64 product build (pf-probe for the qemu smoke)"
	"$REPO/pocketforge/build/build.sh" --arch aarch64 --variant product --work "$WORK" --out "$WORK/out" --require-clean
	echo "::endgroup::"
fi
ARM_SYSROOT=$WORK/sysroot-arm64/root

PROBE_PACKAGES="cage xwayland mesa-vulkan-drivers libgl1-mesa-dri libegl1 libegl-mesa0 libgles2
  libsdl2-2.0-0 qemu-user-static"
echo "::group::probe runtime packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# shellcheck disable=SC2086
apt-get -y install $PROBE_PACKAGES
apt-get clean
rm -rf /var/lib/apt/lists/*
echo "::endgroup::"
for p in cage libgl1-mesa-dri mesa-vulkan-drivers libsdl2-2.0-0 qemu-user-static; do
	echo "probe_package $(dpkg-query -W -f='${Package} ${Version}' "$p")"
done

HUSER=pfharness
id -u "$HUSER" >/dev/null 2>&1 || useradd --system --create-home --user-group "$HUSER"
for d in "$WORK" "$REPO"; do
	while [ "$d" != / ]; do chmod o+x "$d"; d=$(dirname "$d"); done
done
chmod -R o+rX "$WORK/app-root/x86_64-diag/stage" "$ARM" "$ARM_SYSROOT" "$HERE"
OUT=$WORK/probe-out
rm -rf "$OUT"
install -d -o "$HUSER" -g "$HUSER" "$OUT"

echo "x86_64 pf-probe sha256 $(sha256sum "$APP/pf-probe" | cut -d' ' -f1)"
echo "aarch64 pf-probe sha256 $(sha256sum "$ARM/pf-probe" | cut -d' ' -f1)"
rc=0
setpriv --reuid="$HUSER" --regid="$HUSER" --init-groups \
	env HOME="$(getent passwd "$HUSER" | cut -d: -f6)" "$HERE/run.sh" --out "$OUT" \
	--arm64-probe "$ARM/pf-probe" --arm64-sysroot "$ARM_SYSROOT" "$APP" || rc=$?
echo "probe_rc=$rc"
exit "$rc"
