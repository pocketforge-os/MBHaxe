#!/bin/bash
# Turn the pinned bookworm base image into the MBHaxe builder: point apt at the pinned
# Debian snapshot (signature-checked against keys/*.asc), align the base to it and install
# PF_HOST_PACKAGES. Runs as root inside the base image: from the Containerfile, or as the
# first step of a CI job whose container is PF_BASE_IMAGE. Never run it on a host.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"

[ "$(id -u)" = 0 ] || pf_die "toolchain.sh must run as root inside the builder container"
grep -q '^VERSION_CODENAME=bookworm$' /etc/os-release || pf_die "not a Debian bookworm base"
[ -n "${PF_IN_BUILDER_CONTAINER:-}" ] || pf_die "refusing to modify a non-container system (set PF_IN_BUILDER_CONTAINER=1 in the container)"

install -d -m 0755 /etc/apt/keyrings
pf_debian_keyring /etc/apt/keyrings/pf-debian-snapshot.gpg
rm -f /etc/apt/sources.list.d/debian.sources
pf_debian_sources amd64 /etc/apt/keyrings/pf-debian-snapshot.gpg > /etc/apt/sources.list
cat > /etc/apt/apt.conf.d/90pf-snapshot <<'EOF'
Acquire::Check-Valid-Until "false";
Acquire::Retries "5";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y dist-upgrade
# shellcheck disable=SC2086
apt-get -y install $PF_HOST_PACKAGES
apt-get clean
rm -rf /var/lib/apt/lists/*

# Record the exact builder package set; build.sh hashes it into every manifest.
dpkg-query -W -f='${Package}:${Architecture} ${Version}\n' | LC_ALL=C sort > /etc/pf-builder-packages.txt
echo "$PF_BASE_IMAGE" > /etc/pf-builder-base-image
echo "$PF_DEBIAN_SNAPSHOT" > /etc/pf-builder-snapshot
echo "builder ready: $(wc -l < /etc/pf-builder-packages.txt) packages, $(aarch64-linux-gnu-gcc-12 --version | head -1)"
