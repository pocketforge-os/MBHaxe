#!/bin/bash
# ABI gates for a staged MBHaxe build: every ELF file directly in DIR must
#   - be built for ARCH (ELF machine; executables use the bookworm dynamic loader),
#   - need no GLIBC symbol version above PF_MAX_GLIBC (and no GLIBC_PRIVATE), no GLIBCXX/CXXABI/GCC
#     version above the gcc 12 ceilings in pins.lock,
#   - have every DT_NEEDED in needed.allow (or the --allow FILE, same format), and never
#     libGL/libGLX/libOpenGL/libGLU,
#   - carry no RPATH/RUNPATH other than $ORIGIN.
#
# usage: gates.sh --arch <aarch64|x86_64> [--allow FILE] DIR
# Prints one "gate=<name> status=PASS|FAIL ..." line per gate and a final "gates=PASS|FAIL ..." line;
# exits 1 if any gate fails. Needs readelf (binutils) only.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"

ARCH='' ALLOW=$PF_BUILD_DIR/needed.allow
while [ $# -gt 1 ]; do
	case $1 in
	--arch) ARCH=$2; shift 2 ;;
	--allow) ALLOW=$2; shift 2 ;;
	*) break ;;
	esac
done
DIR=${1:?usage: gates.sh --arch <aarch64|x86_64> [--allow FILE] DIR}
[ -d "$DIR" ] || pf_die "not a directory: $DIR"
pf_arch_info "$ARCH" >/dev/null
case $ARCH in
aarch64) MACHINE=AArch64 INTERP=/lib/ld-linux-aarch64.so.1 ;;
x86_64) MACHINE="Advanced Micro Devices X86-64" INTERP=/lib64/ld-linux-x86-64.so.2 ;;
esac

ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }

allowed=" $(awk -v a="$ARCH" '!/^#/ && NF==2 && ($1=="*" || $1==a) {print $2}' "$ALLOW" | tr '\n' ' ')"

fail=0 files=0 max_glibc=GLIBC_0
needed_all="" bad_machine="" bad_ver="" bad_needed="" bad_gl="" bad_path=""
for f in "$DIR"/*; do
	[ -f "$f" ] && [ ! -L "$f" ] || continue
	[ "$(od -An -tx1 -N4 "$f" | tr -d ' ')" = 7f454c46 ] || continue
	files=$((files + 1))
	b=$(basename "$f")
	hdr=$(readelf -h -W "$f")
	echo "$hdr" | grep -q "Machine:[[:space:]]*$MACHINE\$" || bad_machine="$bad_machine $b"
	if echo "$hdr" | grep -q 'Type:[[:space:]]*\(EXEC\|DYN\)' && readelf -l -W "$f" | grep -q 'Requesting program interpreter'; then
		readelf -l -W "$f" | grep -q "Requesting program interpreter: $INTERP\]" || bad_machine="$bad_machine $b(interp)"
	fi
	# Version needs: "File: libc.so.6" lines followed by "Name: GLIBC_2.34" lines.
	while read -r lib ver; do
		case $ver in
		GLIBC_PRIVATE) bad_ver="$bad_ver $b:$lib:$ver" ;;
		GLIBC_[0-9]*)
			ver_le "${ver#GLIBC_}" "$PF_MAX_GLIBC" || bad_ver="$bad_ver $b:$lib:$ver"
			ver_le "${max_glibc#GLIBC_}" "${ver#GLIBC_}" && max_glibc=$ver ;;
		GLIBCXX_[0-9]*) ver_le "${ver#GLIBCXX_}" "$PF_MAX_GLIBCXX" || bad_ver="$bad_ver $b:$lib:$ver" ;;
		CXXABI_[0-9]*) ver_le "${ver#CXXABI_}" "$PF_MAX_CXXABI" || bad_ver="$bad_ver $b:$lib:$ver" ;;
		GCC_[0-9]*) ver_le "${ver#GCC_}" "$PF_MAX_GCC" || bad_ver="$bad_ver $b:$lib:$ver" ;;
		esac
	done < <(readelf -V -W "$f" | awk '/^Version needs section/{s=1;next} /^Version (symbols|definition) section/{s=0}
		s && /File:/ {for(i=1;i<=NF;i++) if($i=="File:") lib=$(i+1)}
		s && /Name:/ {for(i=1;i<=NF;i++) if($i=="Name:") print lib, $(i+1)}')
	dyn=$(readelf -d -W "$f" 2>/dev/null || true)
	for n in $(echo "$dyn" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
		needed_all="$needed_all $n"
		case $n in libGL.so* | libGLX* | libOpenGL.so* | libGLU.so*) bad_gl="$bad_gl $b:$n" ;; esac
		case $allowed in *" $n "*) ;; *) bad_needed="$bad_needed $b:$n" ;; esac
	done
	for p in $(echo "$dyn" | sed -n 's/.*(\(RPATH\|RUNPATH\)).*\[\(.*\)\]/\2/p' | tr ':' ' '); do
		[ "$p" = '$ORIGIN' ] || bad_path="$bad_path $b:$p"
	done
done

gate() { # name failures detail
	if [ -n "$2" ]; then echo "gate=$1 status=FAIL offenders=$(echo $2 | tr ' ' ',')"; fail=1
	else echo "gate=$1 status=PASS $3"; fi
}
[ "$files" -gt 0 ] || { echo "gate=elf-present status=FAIL no ELF files in $DIR"; fail=1; }
gate machine "$bad_machine" "machine=$ARCH interp=$INTERP"
gate symbol-versions "$bad_ver" "max_glibc=$max_glibc ceiling=GLIBC_$PF_MAX_GLIBC glibcxx<=$PF_MAX_GLIBCXX"
gate no-libgl "$bad_gl" ""
gate needed-allowlist "$bad_needed" ""
gate rpath "$bad_path" "only=\$ORIGIN"
needed_sorted=$(echo $needed_all | tr ' ' '\n' | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//')
if [ "$fail" = 0 ]; then st=PASS; else st=FAIL; fi
echo "gates=$st arch=$ARCH files=$files max_glibc=$max_glibc needed=$needed_sorted"
exit "$fail"
