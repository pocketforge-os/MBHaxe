#!/bin/bash
# Laptop/CI harness for the window step-1 device probe (pf-probe, tsp-0qwbh.10).
#
# usage: tests/pf-probe/run.sh [--out DIR] [--arm64-probe FILE --arm64-sysroot DIR | --skip-qemu] <app-root>
#
#   <app-root>  an x86_64 app root from pocketforge/build/app-root.sh (org.pocketforge.mbhaxe/:
#               launch, probe-launch, pf-probe, lib/ with the bundled OpenAL Soft); the probe runs
#               through probe-launch -> launch, so it gets the game's environment and libraries
#   --arm64-probe FILE    the aarch64 pf-probe for the qemu-aarch64 smoke
#   --arm64-sysroot DIR   the arm64 build sysroot (pocketforge/build/sysroot.sh) as the library root
#   --skip-qemu           skip the smoke (reported as SKIP; default is to require it)
#   --out DIR             evidence directory (default: a new mktemp dir); must not exist or be empty
#
# Runs, each under a private headless compositor like tests/pf-harness/run.sh (weston >= 12 with
# kiosk-shell, else cage + Xwayland as an unprivileged user; 1280x720, pixman), with Zink over
# lavapipe forced to OpenGL ES 3.0 / GLSL ES 3.00 like the device and OpenAL Soft on its null
# backend:
#   positive   probe-launch --expect-renderer zink: PROBE RESULT PASS, rc 0, every GL check and the
#              audio check PASS, OpenAL loaded from the app root's lib/;
#   negative   probe-launch --negative (SDL_VIDEODRIVER=x11, no X server): rc 1 and
#              "PROBE RESULT FAIL reason=sdl-init-video" (a named failure, no crash, no hang);
#   no-socket  WAYLAND_DISPLAY naming a missing socket (the device without --expose-wayland):
#              rc 1 and "PROBE RESULT FAIL reason=sdl-init-video";
#   renderer   --expect-renderer PowerVR on lavapipe: rc 1 and "PROBE RESULT FAIL reason=gl-renderer";
#   qemu       the aarch64 probe under qemu-aarch64 with SDL's dummy video and audio drivers, as
#              the game's smoke in tests/pf-harness/run.sh: SDL_Init and the OpenAL tone PASS,
#              then "PROBE RESULT FAIL reason=window" (dummy has no GL), the same depth as the
#              game's smoke reaches.
# Prints one "PASS ..." / "FAIL reason=..." line per assertion and a final "RESULT PASS|FAIL";
# exits 0 only if every assertion passed. The compositor is stopped by exact PID.
set -uo pipefail

OUT="" ARM_PROBE="" ARM_SYSROOT="" SKIP_QEMU=0
die_usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
		--out) OUT=$2; shift 2 ;;
		--arm64-probe) ARM_PROBE=$2; shift 2 ;;
		--arm64-sysroot) ARM_SYSROOT=$2; shift 2 ;;
		--skip-qemu) SKIP_QEMU=1; shift ;;
		-h|--help) die_usage ;;
		--*) echo "FAIL reason=bad-option $1" >&2; exit 2 ;;
		*) break ;;
	esac
done
[ $# -eq 1 ] || die_usage
APP=$(cd "$1" 2>/dev/null && pwd -P) || { echo "FAIL reason=no-app-root $1"; echo "RESULT FAIL (setup)"; exit 1; }

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL reason=$*"; FAILS=$((FAILS + 1)); }
fatal() { echo "FAIL reason=$*"; echo "RESULT FAIL (setup)"; exit 1; }

# ---- preflight -------------------------------------------------------------------------------
for f in launch probe-launch pf-probe; do [ -x "$APP/$f" ] || fatal "app-root-missing $APP/$f"; done
[ -e "$APP/lib/libopenal.so.1" ] || fatal "app-root-missing $APP/lib/libopenal.so.1"
command -v timeout >/dev/null || fatal "missing-tool timeout"
LVP_ICD=${PF_HARNESS_LVP_ICD:-}
if [ -z "$LVP_ICD" ]; then
	for f in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
		[ -f "$f" ] && { LVP_ICD=$f; break; }
	done
fi
[ -n "$LVP_ICD" ] && [ -f "$LVP_ICD" ] || fatal "no-lavapipe-icd (install mesa-vulkan-drivers or set PF_HARNESS_LVP_ICD)"
COMPOSITOR=${PF_HARNESS_COMPOSITOR:-auto}
if [ "$COMPOSITOR" = auto ]; then
	if command -v weston >/dev/null && weston --help 2>&1 | grep -q -- '--renderer'; then COMPOSITOR=weston
	elif command -v cage >/dev/null; then COMPOSITOR=cage
	else fatal "missing-tool weston>=12 or cage"; fi
fi
case $COMPOSITOR in
	weston) command -v weston >/dev/null || fatal "missing-tool weston" ;;
	cage) command -v cage >/dev/null || fatal "missing-tool cage"
		[ "$(id -u)" != 0 ] || fatal "cage-refuses-root (run the harness as an unprivileged user)" ;;
	*) fatal "bad-compositor $COMPOSITOR (auto, weston or cage)" ;;
esac
QEMU=""
if [ $SKIP_QEMU = 0 ]; then
	[ -n "$ARM_PROBE" ] && [ -n "$ARM_SYSROOT" ] || fatal "qemu-smoke-needs --arm64-probe and --arm64-sysroot (or --skip-qemu)"
	[ -x "$ARM_PROBE" ] || fatal "no-arm64-probe $ARM_PROBE"
	[ -d "$ARM_SYSROOT/usr/lib" ] || fatal "bad-arm64-sysroot $ARM_SYSROOT"
	QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64) || fatal "missing-tool qemu-aarch64"
fi
if [ -z "$OUT" ]; then
	OUT=$(mktemp -d "${TMPDIR:-/tmp}/pf-probe.XXXXXX")
else
	mkdir -p "$OUT" && [ -z "$(ls -A "$OUT")" ] || fatal "out-dir-not-empty $OUT"
fi
OUT=$(cd "$OUT" && pwd -P)
echo "probe-harness out=$OUT app=$APP"
echo "x86_64 pf-probe sha256 $(sha256sum "$APP/pf-probe" | cut -d' ' -f1)"

# ---- private headless compositor (as tests/pf-harness/run.sh) ----------------------------------
WPID="" CPID="" XDG=""
cleanup() {
	[ -n "$CPID" ] && kill -0 "$CPID" 2>/dev/null && { kill -TERM "$CPID"; sleep 1; }
	[ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null && { kill -TERM "$WPID"; wait "$WPID" 2>/dev/null; }
	[ -n "$XDG" ] && rm -rf "$XDG"
}
trap cleanup EXIT
trap 'echo "FAIL reason=interrupted"; exit 1' INT TERM
XDG=$(mktemp -d /tmp/pfp.XXXXXX) || fatal "mktemp-xdg"
chmod 700 "$XDG"
if [ "$COMPOSITOR" = weston ]; then
	SOCK=pf-probe-$$
	echo "info compositor $(weston --version 2>&1 | head -n1)"
	XDG_RUNTIME_DIR=$XDG weston --backend=headless --renderer=pixman --width=1280 --height=720 \
		--shell=kiosk --socket=$SOCK --no-config --log="$OUT/compositor.log" >"$OUT/compositor.stderr" 2>&1 &
	WPID=$!
else
	SOCK=wayland-0
	echo "info compositor cage $(dpkg-query -W -f='${Version}' cage 2>/dev/null) wlroots headless, pixman"
	XDG_RUNTIME_DIR=$XDG WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 \
		WLR_LIBINPUT_NO_DEVICES=1 cage -- sh -c 'echo $$ >"$XDG_RUNTIME_DIR/placeholder.pid"; exec sleep 100000' \
		>"$OUT/compositor.log" 2>&1 &
	WPID=$!
fi
for _ in $(seq 100); do
	[ -S "$XDG/$SOCK" ] && { [ "$COMPOSITOR" = weston ] || [ -s "$XDG/placeholder.pid" ]; } && break
	kill -0 $WPID 2>/dev/null || break
	sleep 0.1
done
[ -s "$XDG/placeholder.pid" ] && CPID=$(cat "$XDG/placeholder.pid")
[ -S "$XDG/$SOCK" ] && kill -0 $WPID 2>/dev/null || fatal "compositor-did-not-start ($COMPOSITOR) see $OUT/compositor.log"
pass "compositor $COMPOSITOR pid=$WPID socket=$SOCK"

# ---- probe runs ------------------------------------------------------------------------------
mkdir -p "$OUT/state" "$OUT/cache"
# run NAME WAYLAND_DISPLAY [probe-launch options...]: output in $OUT/NAME.out, rc in RC.
run() {
	local name=$1 wl=$2
	shift 2
	env -u DISPLAY XDG_RUNTIME_DIR="$XDG" WAYLAND_DISPLAY="$wl" \
		XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" \
		GALLIUM_DRIVER=zink LIBGL_ALWAYS_SOFTWARE=1 VK_ICD_FILENAMES="$LVP_ICD" \
		MESA_GLES_VERSION_OVERRIDE=3.0 MESA_GLSL_VERSION_OVERRIDE=300 ALSOFT_DRIVERS=null \
		timeout -s KILL 180 "$APP/probe-launch" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
	RC=$?
	echo "info run=$name rc=$RC: probe-launch $*"
	grep '^PROBE ' "$OUT/$name.out" | sed "s/^/  $name: /"
}
has() { grep -q -- "$2" "$OUT/$1.out"; }
expect_check() { # run check-name
	if grep -q "^PROBE CHECK $2 PASS" "$OUT/$1.out"; then pass "$1 $2"
	else fail "$1-$2-not-pass $(grep -m1 "^PROBE CHECK $2 " "$OUT/$1.out" || echo missing)"; fi
}
expect_named_fail() { # run reason
	local last
	last=$(grep '^PROBE RESULT' "$OUT/$1.out" | tail -n1)
	if [ "$RC" = 1 ] && [ "$last" = "PROBE RESULT FAIL reason=$2" ]; then pass "$1 named failure rc=1 ($last)"
	else fail "$1-not-named-fail rc=$RC result=${last:-none} want=reason=$2"; fi
}

run positive "$SOCK" --expect-renderer zink --timeout 60
if [ "$RC" = 0 ] && has positive '^PROBE RESULT PASS'; then pass "positive rc=0 $(grep '^PROBE RESULT' "$OUT/positive.out")"
else fail "positive-rc=$RC $(grep '^PROBE RESULT' "$OUT/positive.out" || echo 'no PROBE RESULT line')"; fi
for c in sdl-init video-driver window gl-context gl-version glsl-version gl-renderer gl-program gl-framebuffer \
	gl-draw gl-draw-after-swap gl-present gl-errors audio; do
	expect_check positive "$c"
done
GLV=$(grep -m1 '^PROBE INFO gl GL_VERSION' "$OUT/positive.out")
echo "$GLV" | grep -q 'GL_VERSION="OpenGL ES 3\.0 ' && pass "positive es-3.0 context" || fail "positive-not-es30 $GLV"
LIBS=$(grep -m1 '^PROBE INFO libs ' "$OUT/positive.out")
case $LIBS in
	*"openal=\"$APP/lib/libopenal.so.1\""*) pass "positive openal-from-app-root ($APP/lib/libopenal.so.1)" ;;
	*) fail "positive-openal-not-bundled ${LIBS:-no libs line}" ;;
esac

run negative "$SOCK" --negative
expect_named_fail negative sdl-init-video
run no-socket wayland-pf-missing
expect_named_fail no-socket sdl-init-video
run renderer "$SOCK" --expect-renderer PowerVR --no-audio
expect_named_fail renderer gl-renderer

# ---- qemu-aarch64 smoke ------------------------------------------------------------------------
if [ $SKIP_QEMU = 1 ]; then
	echo "SKIP qemu-aarch64-smoke (--skip-qemu)"
else
	echo "aarch64 pf-probe sha256 $(sha256sum "$ARM_PROBE" | cut -d' ' -f1)"
	env -u DISPLAY -u WAYLAND_DISPLAY -u XDG_RUNTIME_DIR SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null \
		timeout -s KILL 300 "$QEMU" -L "$ARM_SYSROOT" "$ARM_PROBE" --expect-driver dummy --timeout 240 \
		>"$OUT/qemu.out" 2>"$OUT/qemu.err"
	RC=$?
	echo "info run=qemu rc=$RC: qemu-aarch64 pf-probe --expect-driver dummy"
	grep '^PROBE ' "$OUT/qemu.out" | sed 's/^/  qemu: /'
	expect_check qemu sdl-init
	expect_check qemu audio
	expect_named_fail qemu window
fi

if [ $FAILS = 0 ]; then echo "RESULT PASS out=$OUT"; exit 0; fi
for f in "$OUT"/*.err; do [ -s "$f" ] && { echo "--- tail $(basename "$f")"; tail -n 20 "$f"; }; done
echo "RESULT FAIL ($FAILS failed check(s)) out=$OUT"
exit 1
