# shellcheck shell=bash
# Shared helpers for the PocketForge MBHaxe build scripts (sourced, not executed).
# Needs only bash, awk, base64 and coreutils so it works in the bare bookworm base image.

PF_BUILD_DIR=${PF_BUILD_DIR:-$(cd "$(dirname "$0")" && pwd)}

pf_die() { echo "error: $*" >&2; exit 1; }
pf_log() { echo "[pf-build] $*" >&2; }

# Write the binary OpenPGP keyring for the pinned Debian keys (keys/*.asc, ASCII-armoured) to $1.
# Concatenated binary transferable public keys form a valid keyring; no gpg needed.
pf_debian_keyring() {
	awk '/^-----BEGIN PGP PUBLIC KEY BLOCK-----/{b=1;h=1;next}
	     /^-----END PGP/{b=0;next}
	     b&&h{ if($0=="") h=0; next }
	     b&&/^=/{next}
	     b{print}' "$PF_BUILD_DIR"/keys/*.asc | base64 -d > "$1.tmp"
	[ -s "$1.tmp" ] || pf_die "empty Debian keyring"
	mv "$1.tmp" "$1"
}

# Print the three snapshot sources lines for arch $1 signed by keyring $2.
# Plain http, as Debian's own defaults: integrity comes from the InRelease signatures (checked
# against keys/*.asc) and the per-file hashes they sign, and the bare base image has no CA bundle
# to bootstrap https with.
pf_debian_sources() {
	for s in "debian $PF_DEBIAN_SNAPSHOT bookworm" "debian $PF_DEBIAN_SNAPSHOT bookworm-updates" \
	         "debian-security $PF_DEBIAN_SNAPSHOT bookworm-security"; do
		set -- "$1" "$2" $s
		echo "deb [arch=$1 signed-by=$2] http://snapshot.debian.org/archive/$3/$4 $5 main"
		set -- "$1" "$2"
	done
}

# sha256 of a file (first field only).
pf_sha256() { sha256sum "$1" | cut -d' ' -f1; }

# Map a PocketForge arch name to "<debian arch> <gnu triple> <dynamic loader>".
pf_arch_info() {
	case $1 in
	aarch64) echo "arm64 aarch64-linux-gnu ld-linux-aarch64.so.1" ;;
	x86_64) echo "amd64 x86_64-linux-gnu ld-linux-x86-64.so.2" ;;
	*) pf_die "unsupported arch: $1 (aarch64 or x86_64)" ;;
	esac
}

# The unwrapped C compiler for triple $1: $PF_BASE_CC if set, else the bookworm gcc 12 driver
# (the builder container), else the host's default cross/native driver.
pf_base_cc() {
	if [ -n "${PF_BASE_CC:-}" ]; then echo "$PF_BASE_CC"
	elif command -v "$1-gcc-12" >/dev/null; then command -v "$1-gcc-12"
	elif command -v "$1-gcc" >/dev/null; then command -v "$1-gcc"
	else pf_die "no C compiler for $1"; fi
}

# Write DIR/cc (a compiler wrapper confined to SYSROOT) and DIR/toolchain.cmake for triple.
# usage: pf_write_toolchain <triple> <sysroot> <dir>
# The wrapper is what makes the result independent of the build host: Ubuntu's cross gcc
# searches its own /usr/<triple>/{include,lib} (glibc 2.39) before --sysroot, and a native gcc
# links the host's start files and libc. -nostdinc/-B/-L force headers, start files and
# libraries to come from the bookworm sysroot only (verified with -Wl,-t in the tsp-0qwbh spike).
pf_write_toolchain() {
	local t=$1 sr=$2 d=$3 cc inc proc
	cc=$(pf_base_cc "$t")
	inc=$("$cc" -print-file-name=include)
	mkdir -p "$d"
	cat > "$d/cc" <<EOW
#!/bin/sh
exec $cc --sysroot=$sr -nostdinc -isystem $inc -isystem $sr/usr/include/$t -isystem $sr/usr/include \\
  -B$sr/usr/lib/$t/ -L$sr/lib/$t -L$sr/usr/lib/$t -Wl,-rpath-link,$sr/lib/$t:$sr/usr/lib/$t "\$@"
EOW
	chmod +x "$d/cc"
	proc=${t%%-*}
	cat > "$d/toolchain.cmake" <<EOT
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR $proc)
set(CMAKE_SYSROOT $sr)
set(CMAKE_C_COMPILER $d/cc)
set(CMAKE_AR $(command -v "$t-ar"))
set(CMAKE_RANLIB $(command -v "$t-ranlib"))
set(CMAKE_STRIP $(command -v "$t-strip"))
set(CMAKE_LIBRARY_ARCHITECTURE $t)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(ENV{PKG_CONFIG_SYSROOT_DIR} $sr)
set(ENV{PKG_CONFIG_LIBDIR} $sr/usr/lib/$t/pkgconfig:$sr/usr/share/pkgconfig)
EOT
	echo "$cc" > "$d/base-cc"
}
