#!/bin/bash
# Red/green tests for gates.sh: tiny probe ELFs that must pass or fail specific gates.
#
# usage: pocketforge/build/tests/gates-test.sh --arch <aarch64|x86_64> --work DIR
#
#   green-sysroot      probe built with the sysroot-confined wrapper (as build.sh does)  -> PASS
#   red-glibc-stub     probe needing fmod@GLIBC_2.38 from a stub libc.so.6               -> FAIL symbol-versions
#   red-libgl          probe needing libGL.so.1                                          -> FAIL no-libgl
#   red-needed         probe needing an unlisted libfoo.so.1                             -> FAIL needed-allowlist
#   red-rpath          probe with an absolute RUNPATH                                    -> FAIL rpath
#   red-machine        probe for the other architecture                                  -> FAIL machine
#   host-glibc         probe linked by the UNWRAPPED compiler with only --sysroot (the spike's
#                      first, broken recipe). Expected FAIL symbol-versions when that compiler's own
#                      glibc is newer than the ceiling (Ubuntu 24.04: 2.39, fmod@GLIBC_2.38);
#                      expected PASS in the bookworm builder, whose cross glibc is 2.36.
# Prints "test=<name> result=ok|FAILED ..." per case and "gates-test=PASS|FAIL"; exit 1 on failure.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"

ARCH='' WORK=''
while [ $# -gt 0 ]; do
	case $1 in
	--arch) ARCH=$2; shift 2 ;;
	--work) WORK=$2; shift 2 ;;
	*) pf_die "unknown argument: $1" ;;
	esac
done
[ -n "$WORK" ] || pf_die "--work DIR is required"
pf_arch_info "$ARCH" > /dev/null
read -r DEBARCH TRIPLE _ <<< "$(pf_arch_info "$ARCH")"
case $ARCH in aarch64) OTHER=x86_64-linux-gnu ;; x86_64) OTHER=aarch64-linux-gnu ;; esac
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
T=$WORK/gates-test/$ARCH
rm -rf "$T"
mkdir -p "$T/src"

"$PF_BUILD_DIR/sysroot.sh" "$DEBARCH" "$WORK/sysroot-$DEBARCH"
SR=$WORK/sysroot-$DEBARCH/root
pf_write_toolchain "$TRIPLE" "$SR" "$T/tc"
BASE_CC=$(cat "$T/tc/base-cc")

cat > "$T/src/probe.c" <<'EOF'
#include <math.h>
#include <stdio.h>
int main(int argc, char **argv) {
	volatile double a = argc, b = 2.0;
	int v = 0;
	if (argc > 1) sscanf(argv[1], "%d", &v);
	return (int)fmod(a, b) + v;
}
EOF
# Freestanding probe + stubs: no headers or libc needed, so any compiler for the arch can build them.
cat > "$T/src/bare.c" <<'EOF'
double fmod(double, double);
volatile double a = 3.0, b = 2.0;
int main(void) { return (int)fmod(a, b); }
EOF
echo 'double fmod(double a, double b) { return a - b; }' > "$T/src/stub.c"
echo 'GLIBC_2.38 { global: fmod; local: *; };' > "$T/src/glibc238.map"

stub() { # cc soname out [extra]
	"$1" -shared -fPIC -nostdlib -Wl,-soname,"$2" "${@:4}" -o "$3" "$T/src/stub.c"
}
bare() { # cc out libs...
	local cc=$1 out=$2; shift 2
	"$cc" -fno-builtin -nostdlib -Wl,--no-as-needed -Wl,-e,main -o "$out" "$T/src/bare.c" "$@"
}

fail=0
run() { # name expect(PASS|FAIL) gate-that-must-fail
	local name=$1 expect=$2 gate=${3:-} out rc=0
	out=$("$PF_BUILD_DIR/gates.sh" --arch "$ARCH" "$T/$name") || rc=$?
	echo "$out" | sed "s/^/  [$name] /"
	if [ "$expect" = PASS ] && [ "$rc" = 0 ]; then
		echo "test=$name result=ok expected=PASS"
	elif [ "$expect" = FAIL ] && [ "$rc" != 0 ] && echo "$out" | grep -q "^gate=$gate status=FAIL"; then
		echo "test=$name result=ok expected=FAIL gate=$gate"
	else
		echo "test=$name result=FAILED expected=$expect${gate:+ gate=$gate} rc=$rc"
		fail=1
	fi
}

mkdir -p "$T/green-sysroot"
"$T/tc/cc" -O2 -D_GNU_SOURCE -o "$T/green-sysroot/probe" "$T/src/probe.c" -lm
run green-sysroot PASS

mkdir -p "$T/red-glibc-stub/stub"
stub "$BASE_CC" libc.so.6 "$T/red-glibc-stub/stub/libc.so.6" -Wl,--version-script="$T/src/glibc238.map"
bare "$BASE_CC" "$T/red-glibc-stub/probe" "$T/red-glibc-stub/stub/libc.so.6"
rm -rf "$T/red-glibc-stub/stub"
run red-glibc-stub FAIL symbol-versions

mkdir -p "$T/red-libgl/stub"
stub "$BASE_CC" libGL.so.1 "$T/red-libgl/stub/libGL.so.1"
bare "$BASE_CC" "$T/red-libgl/probe" "$T/red-libgl/stub/libGL.so.1"
rm -rf "$T/red-libgl/stub"
run red-libgl FAIL no-libgl

mkdir -p "$T/red-needed/stub"
stub "$BASE_CC" libfoo.so.1 "$T/red-needed/stub/libfoo.so.1"
bare "$BASE_CC" "$T/red-needed/probe" "$T/red-needed/stub/libfoo.so.1"
rm -rf "$T/red-needed/stub"
run red-needed FAIL needed-allowlist

mkdir -p "$T/red-rpath"
"$T/tc/cc" -O2 -o "$T/red-rpath/probe" "$T/src/probe.c" -lm -Wl,-rpath,/usr/local/lib
run red-rpath FAIL rpath

if OTHER_CC=$(PF_BASE_CC='' pf_base_cc "$OTHER" 2> /dev/null); then
	mkdir -p "$T/red-machine/stub"
	stub "$OTHER_CC" libc.so.6 "$T/red-machine/stub/libc.so.6"
	bare "$OTHER_CC" "$T/red-machine/probe" "$T/red-machine/stub/libc.so.6"
	rm -rf "$T/red-machine/stub"
	run red-machine FAIL machine
else
	echo "test=red-machine result=skipped reason=no_compiler_for_$OTHER"
fi

# The host-glibc case: what the gate exists for.
host_libc=$("$BASE_CC" -print-file-name=libc.so.6)
host_glibc=$(grep -aoE 'GNU C Library [^)]*\) [a-z ]*version [0-9]+\.[0-9]+' "$(readlink -f "$host_libc")" | grep -oE '[0-9]+\.[0-9]+$' | head -1 || true)
mkdir -p "$T/host-glibc"
"$BASE_CC" --sysroot="$SR" -O2 -D_GNU_SOURCE -o "$T/host-glibc/probe" "$T/src/probe.c" -lm
echo "  [host-glibc] compiler=$BASE_CC libc=$host_libc glibc=${host_glibc:-unknown}"
if [ -n "$host_glibc" ] && [ "$(printf '%s\n%s\n' "$host_glibc" "$PF_MAX_GLIBC" | sort -V | tail -1)" != "$PF_MAX_GLIBC" ]; then
	run host-glibc FAIL symbol-versions
else
	run host-glibc PASS
fi

if [ "$fail" = 0 ]; then echo "gates-test=PASS arch=$ARCH"; else echo "gates-test=FAIL arch=$ARCH"; fi
exit "$fail"
