#!/bin/bash
# PocketForge regression harness for the MBHaxe GLES port (tsp-0qwbh.3).
#
# usage: tests/pf-harness/run.sh [options] <game-dir> <data-dir>
#
#   <game-dir>  an already-built x86_64 `-D pf_diag` GLES game: marblegame, libhl.so*, *.hdll
#               (haxe compile-linux-gles.hxml -D pf_diag, hashlink built with -DWITH_SDL_GLES=ON)
#   <data-dir>  the game's data/ directory (copied, never modified)
#
# options:
#   --out DIR                 work/evidence directory (default: a new mktemp dir); must not exist or be empty
#   --arm64-game DIR          aarch64 build of the game (marblegame, libhl.so*, *.hdll) for the qemu smoke
#   --arm64-sysroot DIR       arm64 sysroot holding the runtime libraries (libSDL2, libGLESv2, libc, ...)
#   --skip-qemu               skip the qemu-aarch64 smoke (reported as SKIP; default is to require it)
#   --timeout SECONDS         wall-clock limit for the x86_64 run (default 600)
#
# What it does:
#   1. stages <game-dir> and a real copy of <data-dir> under --out (canonical path, no symlinks:
#      heaps resolves data paths with realpath);
#   2. starts a private headless weston (pixman, kiosk shell, 1280x720) with its own XDG_RUNTIME_DIR;
#   3. runs the game under strace (network syscalls) with SDL_VIDEODRIVER=wayland and Zink over
#      lavapipe, forced to OpenGL ES 3.0 / GLSL ES 3.00 like the device; pf_diag autoplays the
#      first beginner mission, dumps the menu and level frames and exits at a fixed frame;
#   4. asserts: GL_VERSION has "OpenGL ES 3.0" and GL_RENDERER has "zink"; the mission started;
#      "[diag] exit at frame N, GL errors seen: 0"; the es3strict LD_PRELOAD checker (es3strict.c)
#      saw no pixel format or glEnable cap outside OpenGL ES 3.0 core (Mesa silently accepts
#      GL_BGRA_EXT, so glGetError alone misses a BGRA regression); both screenshots are non-blank and match
#      known-colour probes (a red/blue swap or empty textures fail); strace shows AF_UNIX traffic
#      and no AF_INET/AF_INET6 socket;
#   5. qemu-aarch64 smoke: the arm64 build with SDL_VIDEODRIVER=dummy runs through the loader,
#      libhl, the hdlls, SDL_Init and Haxe main up to window creation ("Failed to create window"
#      is the expected terminal line; the dummy driver has no GL).
#   Weston and the game are stopped by exact PID. Prints one "PASS"/"FAIL reason=..." line per
#   check and a final "RESULT PASS|FAIL"; exits 0 only if every check passed.
#
# Host requirements: weston (with kiosk-shell), Mesa with zink + lavapipe (lvp_icd.json),
# strace (ptrace allowed), python3 (stdlib only), a host C compiler ($CC, default cc) for the
# es3strict shim, qemu-aarch64[-static] for the smoke.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
OUT="" ARM_GAME="" ARM_SYSROOT="" SKIP_QEMU=0 TIMEOUT=600
# Frame plan (render frames counted after load; "[diag] loaded at frame 0"): the menu is dumped
# at 420, the first beginner mission ("Learning to Roll") is started at 450, its start-pad view
# is dumped at 1000 (camera static from ~900 on), exit at 1100.
MENU_FRAME=420 AUTOPLAY_AT=450 LEVEL_FRAME=1000 EXIT_FRAME=1100
# Channel-order probes at 1280x720: NAME:X,Y,W,H:R,G,B:TOL (box mean, per-channel tolerance).
# Picked from the tsp-0qwbh.3 runs; every box mean was identical across 11 runs (frames 400-450
# for the menu, 900-1200 for the level, spike and fork builds), so they do not depend on timing.
#   menu  marble: the blue marble in the logo, right of "MARBLE" (2D UI texture), B >> R
#   menu  logo:   the orange "ULTRA" logo lettering (2D UI texture), R >> B
#   (-D handheld hides the cyan "Buy Me a Coffee" button the menu probe used before tsp-0qwbh.4;
#   the logo marble box mean is 70,131,255 in every tsp-0qwbh.3 run and in the handheld build.)
#   level floor:  the green floor tile left of the start pad (3D textured mesh), R >> B
#   level marble: the blue marble resting on the start pad (3D mesh, env-mapped), B >> R
# Each frame has one red-dominant and one blue-dominant probe whose R and B differ by more
# than 2*TOL, so a red/blue swap (BGRA data read as RGBA) or an empty texture fails a probe.
# (The blast meter HUD fills with game time and is deliberately not probed.)
MENU_PROBES=("marble:597,192,10,6:70,131,255:24" "logo:400,330,30,10:137,108,47:24")
LEVEL_PROBES=("floor:300,300,40,20:139,183,72:24" "marble:650,470,20,20:76,134,240:24")

die_usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
	case $1 in
		--out) OUT=$2; shift 2 ;;
		--arm64-game) ARM_GAME=$2; shift 2 ;;
		--arm64-sysroot) ARM_SYSROOT=$2; shift 2 ;;
		--skip-qemu) SKIP_QEMU=1; shift ;;
		--timeout) TIMEOUT=$2; shift 2 ;;
		-h|--help) die_usage ;;
		--*) echo "FAIL reason=bad-option $1" >&2; exit 2 ;;
		*) break ;;
	esac
done
[ $# -eq 2 ] || die_usage
GAME_SRC=$1 DATA_SRC=$2

FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL reason=$*"; FAILS=$((FAILS + 1)); }
fatal() { echo "FAIL reason=$*"; echo "RESULT FAIL (setup)"; exit 1; }

# ---- preflight -------------------------------------------------------------------------------
[ -x "$GAME_SRC/marblegame" ] || fatal "no-game-binary $GAME_SRC/marblegame"
[ -d "$DATA_SRC" ] || fatal "no-data-dir $DATA_SRC"
CC=${CC:-cc}
for t in weston strace python3 timeout "$CC"; do command -v "$t" >/dev/null || fatal "missing-tool $t"; done
LVP_ICD=${PF_HARNESS_LVP_ICD:-}
if [ -z "$LVP_ICD" ]; then
	for f in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
		[ -f "$f" ] && { LVP_ICD=$f; break; }
	done
fi
[ -n "$LVP_ICD" ] && [ -f "$LVP_ICD" ] || fatal "no-lavapipe-icd (install mesa-vulkan-drivers or set PF_HARNESS_LVP_ICD)"
QEMU=""
if [ $SKIP_QEMU = 0 ]; then
	[ -n "$ARM_GAME" ] && [ -n "$ARM_SYSROOT" ] || fatal "qemu-smoke-needs --arm64-game and --arm64-sysroot (or --skip-qemu)"
	[ -x "$ARM_GAME/marblegame" ] || fatal "no-arm64-game-binary $ARM_GAME/marblegame"
	[ -d "$ARM_SYSROOT/usr/lib" ] || fatal "bad-arm64-sysroot $ARM_SYSROOT"
	QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64) || fatal "missing-tool qemu-aarch64"
fi

if [ -z "$OUT" ]; then
	OUT=$(mktemp -d "${TMPDIR:-/tmp}/pf-harness.XXXXXX")
else
	mkdir -p "$OUT" && [ -z "$(ls -A "$OUT")" ] || fatal "out-dir-not-empty $OUT"
fi
OUT=$(cd "$OUT" && pwd -P)
case $OUT in *[[:space:]:]*) fatal "out-dir-path-has-space-or-colon $OUT (breaks LD_PRELOAD)" ;; esac
echo "harness out=$OUT game=$GAME_SRC data=$DATA_SRC"
echo "game sha256 $(sha256sum "$GAME_SRC/marblegame" | cut -d' ' -f1)"

# ---- stage -----------------------------------------------------------------------------------
WPID="" GPID="" XDG=""
cleanup() {
	[ -n "$GPID" ] && kill -0 "$GPID" 2>/dev/null && kill -TERM "$GPID" 2>/dev/null
	[ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null && { kill -TERM "$WPID"; wait "$WPID" 2>/dev/null; }
	[ -n "${XDG:-}" ] && rm -rf "$XDG"
}
trap cleanup EXIT
trap 'echo "FAIL reason=interrupted"; exit 1' INT TERM

G=$OUT/game
mkdir -p "$G" "$OUT/shots"
# Private XDG_RUNTIME_DIR: short path under /tmp (a Wayland socket path must fit in 108 bytes).
XDG=$(mktemp -d /tmp/pfh.XXXXXX) || fatal "mktemp-xdg"
chmod 700 "$XDG"
cp -a "$GAME_SRC"/marblegame "$GAME_SRC"/libhl.so* "$GAME_SRC"/*.hdll "$G"/ || fatal "stage-game"
cp -rL "$DATA_SRC" "$G/data" || fatal "stage-data"
rm -f "$G/settings.json" "$G/console.log"
"$CC" -shared -fPIC -O2 -o "$OUT/es3strict.so" "$HERE/es3strict.c" -ldl >"$OUT/es3strict-build.log" 2>&1 \
	|| fatal "es3strict-build see $OUT/es3strict-build.log"

# ---- private headless weston -----------------------------------------------------------------
SOCK=pf-harness-$$
XDG_RUNTIME_DIR=$XDG weston --backend=headless --renderer=pixman --width=1280 --height=720 \
	--shell=kiosk --socket=$SOCK --no-config --log="$OUT/weston.log" >"$OUT/weston.stderr" 2>&1 &
WPID=$!
for _ in $(seq 100); do
	[ -S "$XDG/$SOCK" ] && break
	kill -0 $WPID 2>/dev/null || break
	sleep 0.1
done
[ -S "$XDG/$SOCK" ] && kill -0 $WPID 2>/dev/null || fatal "weston-did-not-start see $OUT/weston.log"
pass "weston pid=$WPID socket=$SOCK"

# ---- x86_64 run: Zink over lavapipe, ES 3.0, under strace --------------------------------------
STRACE_OPTS=(-f -qq -e trace=network -o "$OUT/strace.log")
strace --seccomp-bpf -e trace=network -o /dev/null true 2>/dev/null && STRACE_OPTS=(--seccomp-bpf "${STRACE_OPTS[@]}")
(
	cd "$G" || exit 1
	exec env XDG_RUNTIME_DIR="$XDG" WAYLAND_DISPLAY=$SOCK SDL_VIDEODRIVER=wayland \
		GALLIUM_DRIVER=zink LIBGL_ALWAYS_SOFTWARE=1 VK_ICD_FILENAMES="$LVP_ICD" \
		MESA_GLES_VERSION_OVERRIDE=3.0 MESA_GLSL_VERSION_OVERRIDE=300 \
		SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null \
		MBHAXE_GLCHECK=1 MBHAXE_AUTOPLAY=beginner:0 MBHAXE_AUTOPLAY_DELAY=$AUTOPLAY_AT \
		MBHAXE_SHOT_DIR="$OUT/shots" MBHAXE_SHOT_FRAMES=$MENU_FRAME,$LEVEL_FRAME MBHAXE_EXIT_FRAME=$EXIT_FRAME \
		timeout -s TERM -k 10 "$TIMEOUT" strace "${STRACE_OPTS[@]}" -E LD_PRELOAD="$OUT/es3strict.so" ./marblegame
) >"$OUT/game.out" 2>&1 &
GPID=$!
wait $GPID
GRC=$?
GPID=""
cp -f "$G/console.log" "$OUT/console.log" 2>/dev/null
LOG=$OUT/game-all.log
cat "$OUT/game.out" "$OUT/console.log" 2>/dev/null >"$LOG"

if [ $GRC = 0 ]; then pass "game-exit rc=0"
elif [ $GRC = 124 ]; then fail "game-timeout no exit within ${TIMEOUT}s (see $OUT/game.out)"
else fail "game-exit rc=$GRC (see $OUT/game.out)"; fi

GLV=$(grep -m1 -o 'GL_VERSION: .*' "$LOG")
if [ -z "$GLV" ]; then fail "no-gl-version-line"
else
	echo "info ${GLV}"
	echo "$GLV" | grep -q 'GL_VERSION: OpenGL ES 3\.0 ' && pass "gl-version OpenGL ES 3.0" || fail "gl-version-not-es30"
	echo "$GLV" | grep -q 'GL_RENDERER: zink' && pass "gl-renderer zink" || fail "gl-renderer-not-zink"
fi
grep -q '\[diag\] autoplay ' "$LOG" && pass "mission-started $(grep -m1 -o '\[diag\] autoplay [^(]*' "$LOG" | sed 's/.*autoplay //')" \
	|| fail "mission-not-started"
EXITLINE=$(grep -m1 -o '\[diag\] exit at frame [0-9]*, GL errors seen: [0-9]*' "$LOG")
if [ -z "$EXITLINE" ]; then
	fail "no-diag-exit-line (last diag line: $(grep -o '\[diag\] .*' "$LOG" | tail -n1))"
	# who called exit(): es3strict logs the backtrace; symbolise the marblegame frames if possible
	BT=$(sed -n '/^\[es3strict\] exit(/,/^\[es3strict\] violations/p' "$LOG" | grep -o 'marblegame(+0x[0-9a-f]*)' | grep -o '0x[0-9a-f]*')
	if [ -n "$BT" ] && command -v addr2line >/dev/null; then
		echo "info exit() called from: $(addr2line -f -e "$G/marblegame" $BT | sed -n 'p;n' | tr '\n' '<' | sed 's/<$//; s/</ <- /g')"
	elif [ -n "$BT" ]; then echo "info exit() called from marblegame offsets: $(echo $BT)"
	else echo "info no exit() backtrace (crash, signal or _exit)"; fi
else
	NERR=${EXITLINE##*: }
	if [ "$NERR" = 0 ]; then pass "gl-errors 0 ($EXITLINE)"
	else fail "gl-errors-$NERR first: $(grep -m1 -o '\[diag\] GL error .*' "$LOG")"; fi
fi
if ! grep -q '^\[es3strict\] loaded' "$LOG"; then fail "es3strict-not-loaded"
else
	ES3=$(grep -m1 -o '^\[es3strict\] violations: [0-9]*.*' "$LOG")
	if [ -z "$ES3" ]; then fail "es3strict-no-summary (game did not exit cleanly)"
	else
		if [ "$(echo "$ES3" | sed 's/.*violations: \([0-9]*\).*/\1/')" = 0 ]; then pass "es3-core-only ($ES3)"
		else fail "es3-non-core-usage $(grep '^\[es3strict\] VIOLATION' "$LOG" | sed 's/^\[es3strict\] VIOLATION //' | tr '\n' ';') ($ES3)"; fi
		if [ "${ES3##*GL errors returned: }" = 0 ]; then pass "gl-errors-whole-run 0 (every glGetError since process start)"
		else fail "gl-errors-whole-run-${ES3##*GL errors returned: } first: $(grep -m1 '^\[es3strict\] glGetError' "$LOG")"; fi
	fi
fi

shot() { # label frame probes...
	local label=$1 frame=$2 f="$OUT/shots/frame$2.png"; shift 2
	if [ ! -f "$f" ]; then fail "$label-screenshot-missing frame$frame"; return; fi
	local args=() p
	for p in "$@"; do args+=(--probe "$p"); done
	if python3 "$HERE/pngcheck.py" "$f" "$label" "${args[@]}" >"$OUT/pngcheck-$label.txt" 2>&1; then
		pass "$label-screenshot $(grep -v '^FAIL' "$OUT/pngcheck-$label.txt" | tr '\n' ';')"
	else
		sed -n 's/^FAIL reason=//p' "$OUT/pngcheck-$label.txt" | while read -r r; do echo "FAIL reason=$r"; done
		grep -v '^FAIL' "$OUT/pngcheck-$label.txt" | sed 's/^/info /'
		FAILS=$((FAILS + 1))
	fi
}
shot menu $MENU_FRAME "${MENU_PROBES[@]}"
shot level $LEVEL_FRAME "${LEVEL_PROBES[@]}"

if [ ! -s "$OUT/strace.log" ] || ! grep -q 'AF_UNIX' "$OUT/strace.log"; then
	fail "strace-no-data (no AF_UNIX socket traced; ptrace blocked?)"
elif grep -q 'AF_INET' "$OUT/strace.log"; then
	fail "network-socket $(grep -m1 'AF_INET' "$OUT/strace.log")"
else
	pass "no-network families: $(grep -o 'AF_[A-Z0-9]*' "$OUT/strace.log" | sort -u | tr '\n' ' ')"
fi

# ---- qemu-aarch64 smoke ------------------------------------------------------------------------
if [ $SKIP_QEMU = 1 ]; then
	echo "SKIP qemu-aarch64-smoke (--skip-qemu)"
else
	Q=$OUT/game-arm64
	mkdir -p "$Q"
	cp -a "$ARM_GAME"/marblegame "$ARM_GAME"/libhl.so* "$ARM_GAME"/*.hdll "$Q"/ || fatal "stage-arm64-game"
	# -D handheld refuses to start without a real data/ directory next to the executable.
	cp -al "$G/data" "$Q/data" 2>/dev/null || cp -r "$G/data" "$Q/data" || fatal "stage-arm64-data"
	echo "arm64 game sha256 $(sha256sum "$Q/marblegame" | cut -d' ' -f1)"
	(
		cd "$Q" || exit 1
		exec env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null \
			timeout -s TERM -k 10 300 "$QEMU" -L "$ARM_SYSROOT" ./marblegame
	) >"$OUT/qemu-arm64.out" 2>&1 &
	GPID=$!
	wait $GPID
	QRC=$?
	GPID=""
	QL=$OUT/qemu-arm64-all.log
	cat "$OUT/qemu-arm64.out" "$Q/console.log" 2>/dev/null >"$QL"
	if grep -q 'Failed to create window' "$QL"; then
		pass "qemu-aarch64-smoke reached window creation (rc=$QRC, expected 'Failed to create window' under SDL dummy)"
	elif [ $QRC = 124 ]; then
		fail "qemu-aarch64-timeout (see $OUT/qemu-arm64.out)"
	else
		fail "qemu-aarch64-no-game-init rc=$QRC last: $(tail -n1 "$QL")"
	fi
fi

if [ $FAILS = 0 ]; then echo "RESULT PASS out=$OUT"; exit 0; fi
echo "RESULT FAIL ($FAILS failed check(s)) out=$OUT"
exit 1
