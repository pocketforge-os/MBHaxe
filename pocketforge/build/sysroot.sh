#!/bin/bash
# Build a Debian bookworm target sysroot from the pinned snapshot with a rootless, isolated apt
# (no host apt configuration, no dpkg database, no root): download PF_SYSROOT_PACKAGES and their
# dependencies for one Debian arch, verify the snapshot's InRelease signatures against keys/*.asc,
# unpack every .deb and make absolute symlinks relative.
#
# usage: sysroot.sh <arm64|amd64> <DIR>     -> DIR/root (the sysroot), DIR/debs.sha256
# Re-running with unchanged inputs (pins, keys, this script) is a no-op.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"

ARCH=${1:?usage: sysroot.sh <arm64|amd64> DIR}
case $ARCH in arm64 | amd64) ;; *) pf_die "unsupported Debian arch: $ARCH" ;; esac
mkdir -p "${2:?usage: sysroot.sh <arm64|amd64> DIR}"
D=$(cd "$2" && pwd -P)

key=$(cat "$PF_BUILD_DIR/pins.lock" "$PF_BUILD_DIR/lib.sh" "$PF_BUILD_DIR"/keys/*.asc "$0" | sha256sum | cut -d' ' -f1)
if [ -f "$D/.complete" ] && [ "$(cat "$D/.complete")" = "$key" ]; then
	pf_log "sysroot $ARCH up to date: $D/root"
	exit 0
fi
rm -rf "$D/apt" "$D/root" "$D/debs.sha256" "$D/.complete"

A=$D/apt
mkdir -p "$A/etc/apt/apt.conf.d" "$A/etc/apt/preferences.d" "$A/etc/apt/sources.list.d" \
	"$A/var/lib/apt/lists/partial" "$A/var/cache/apt/archives/partial" "$A/var/lib/dpkg"
: > "$A/var/lib/dpkg/status"
pf_debian_keyring "$A/debian-snapshot.gpg"
pf_debian_sources "$ARCH" "$A/debian-snapshot.gpg" > "$A/etc/apt/sources.list"
# APT_CONFIG is read first; with Dir set here, no host apt.conf.d snippet is ever consulted.
cat > "$A/apt.conf" <<EOF
Dir "$A/";
Dir::State::status "$A/var/lib/dpkg/status";
APT::Architecture "$ARCH";
APT::Architectures { "$ARCH"; };
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Check-Valid-Until "false";
Acquire::Languages "none";
Acquire::Retries "5";
Debug::NoLocking "true";
EOF
[ "$(id -u)" != 0 ] || echo 'APT::Sandbox::User "root";' >> "$A/apt.conf"
export APT_CONFIG=$A/apt.conf

pf_log "sysroot $ARCH: apt update against snapshot $PF_DEBIAN_SNAPSHOT"
apt-get -q update
# shellcheck disable=SC2086
apt-get -q -y install --download-only $PF_SYSROOT_PACKAGES >/dev/null

mkdir -p "$D/root"
n=0
for deb in $(find "$A/var/cache/apt/archives" -maxdepth 1 -name '*.deb' | LC_ALL=C sort); do
	dpkg-deb -x "$deb" "$D/root"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || pf_die "no packages downloaded"
(cd "$A/var/cache/apt/archives" && sha256sum -- *.deb | LC_ALL=C sort -k2) > "$D/debs.sha256"

# Absolute symlinks (e.g. usr/lib/<triple>/libm.so -> /lib/<triple>/libm.so.6) must resolve
# inside the sysroot, not on the build host.
find "$D/root" -type l -lname '/*' | while read -r l; do
	ln -sfn "$(realpath -m --relative-to="$(dirname "$l")" "$D/root$(readlink "$l")")" "$l"
done
rm -rf "$A/var/cache/apt/archives"
echo "$key" > "$D/.complete"
pf_log "sysroot $ARCH ready: $n packages -> $D/root"
