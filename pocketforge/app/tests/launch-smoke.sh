#!/bin/bash
# Laptop smoke of the staged app through its launch wrapper, the way pf-app@ starts it
# (tsp-0qwbh.5, tsp-0qwbh.9): read-only app directory, pf-app@-shaped XDG_STATE_HOME/XDG_CACHE_HOME,
# a private headless weston, Zink over lavapipe forced to OpenGL ES 3.0, and the pf_diag autoplay.
#
# usage: pocketforge/app/tests/launch-smoke.sh --root STAGING --out DIR [--timeout SECONDS]
#                                              [--readonly-data]
#   STAGING  stage-app.sh output of an x86_64 diag app root, either layout:
#            dev      opt/pocketforge/apps/<id>/ with data/ inside it;
#            release  opt/pocketforge/apps/<id>/ without data/, plus
#                     var/lib/pocketforge/apps/<id>/data/ (the [fetch] destination "var"). The data
#                     is hard-linked (else copied) into OUT's /var/lib/pocketforge/apps/<id>/data,
#                     beside the state directory, as pf-app@ would find it.
#   DIR      evidence directory (new or empty)
#   --readonly-data  release layout: also make the data directories read-only
#
# Checks: launch exits 0; GL_VERSION is OpenGL ES 3.0 on zink; the diag exit line reports 0 GL
# errors; every bundled library and libhl/the hdlls are mapped from the app directory (not the
# host); settings.json and console.log land in the state directory and nothing is written to the
# app directory (SHA256SUMS still verify, no new files); the game data is the layout's (launch sets
# MBHAXE_DATA_DIR only for the release layout), nothing is written to it, and the converter cache is
# MBHAXE_CACHE_DIR under the cache directory. Reports peak RSS (VmHWM) and the app size.
# Weston and the game are stopped by exact PID. Prints "PASS"/"FAIL reason=..." lines and
# "RESULT PASS|FAIL"; exits 0 only if every check passed.
# shellcheck disable=SC2015,SC2317,SC2012  # pass||fail one-liners, trap-only cleanup, ls for a report line
set -uo pipefail
APP_ID=org.pocketforge.mbhaxe
ROOT='' OUT='' TIMEOUT=600 RO_DATA=0
while [ $# -gt 0 ]; do
	case $1 in
	--root) ROOT=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--timeout) TIMEOUT=$2; shift 2 ;;
	--readonly-data) RO_DATA=1; shift ;;
	*) echo "FAIL reason=bad-argument $1"; exit 2 ;;
	esac
done
FAILS=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL reason=$*"; FAILS=$((FAILS + 1)); }
fatal() { echo "FAIL reason=$*"; echo "RESULT FAIL (setup)"; exit 1; }
APP=$ROOT/opt/pocketforge/apps/$APP_ID
[ -x "$APP/launch" ] && [ -x "$APP/marblegame" ] || fatal "no-staged-app $APP"
SRC_VAR_DATA=$ROOT/var/lib/pocketforge/apps/$APP_ID/data
if [ -d "$SRC_VAR_DATA" ]; then
	LAYOUT=release
	[ ! -e "$APP/data" ] || fatal "release-layout-with-app-data $APP/data"
else
	LAYOUT=dev
	[ -d "$APP/data" ] || fatal "no-data $APP/data"
	[ $RO_DATA = 0 ] || fatal "--readonly-data-needs-release-layout"
fi
for t in weston timeout sha256sum; do command -v "$t" >/dev/null || fatal "missing-tool $t"; done
LVP_ICD=${PF_HARNESS_LVP_ICD:-}
for f in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
	[ -n "$LVP_ICD" ] || { [ -f "$f" ] && LVP_ICD=$f; }
done
[ -f "$LVP_ICD" ] || fatal "no-lavapipe-icd"
[ -n "$OUT" ] || fatal "--out is required"
mkdir -p "$OUT" && [ -z "$(ls -A "$OUT")" ] || fatal "out-dir-not-empty $OUT"
OUT=$(cd "$OUT" && pwd -P)
APP=$(cd "$APP" && pwd -P)

# pf-app@ layout under OUT: /var/lib/pocketforge/apps/<id>/{config,state}, /var/cache/...
STATE=$OUT/var/lib/pocketforge/apps/$APP_ID/state
CONFIG=$OUT/var/lib/pocketforge/apps/$APP_ID/config
CACHE=$OUT/var/cache/pocketforge/apps/$APP_ID
mkdir -p "$STATE" "$CONFIG" "$CACHE" "$OUT/home" "$OUT/shots"
chmod 0700 "$STATE" "$CONFIG" "$CACHE"
if [ $LAYOUT = release ]; then
	DATA=$OUT/var/lib/pocketforge/apps/$APP_ID/data
	cp -al "$SRC_VAR_DATA" "$DATA" 2>/dev/null || { rm -rf "$DATA"; cp -a "$SRC_VAR_DATA" "$DATA"; } || fatal "stage-var-data"
	[ $RO_DATA = 0 ] || find "$DATA" -type d -exec chmod a-w {} +
else
	DATA=$APP/data
fi
pass "layout $LAYOUT data=$DATA readonly_data=$RO_DATA"
(cd "$APP" && find . -mindepth 1 | LC_ALL=C sort) > "$OUT/app-before.list"
(cd "$DATA" && find . -mindepth 1 -printf '%p %s %T@\n' | LC_ALL=C sort) > "$OUT/data-before.list"
# The app directory is read-only to the app (ReadOnlyPaths=, Landlock read+execute).
find "$APP" -type d -exec chmod a-w {} +

WPID='' GPID='' XDG=''
cleanup() {
	[ -n "$GPID" ] && kill -0 "$GPID" 2>/dev/null && kill -TERM "$GPID" 2>/dev/null
	[ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null && { kill -TERM "$WPID"; wait "$WPID" 2>/dev/null; }
	[ -n "$XDG" ] && rm -rf "$XDG"
	find "$APP" -type d -exec chmod u+w {} + 2>/dev/null
	[ "$RO_DATA" = 0 ] || find "$DATA" -type d -exec chmod u+w {} + 2>/dev/null
}
trap cleanup EXIT
XDG=$(mktemp -d /tmp/pfs.XXXXXX) || fatal mktemp-xdg
chmod 700 "$XDG"
SOCK=pf-smoke-$$
XDG_RUNTIME_DIR=$XDG weston --backend=headless --renderer=pixman --width=1280 --height=720 \
	--shell=kiosk --socket=$SOCK --no-config --log="$OUT/weston.log" >"$OUT/weston.stderr" 2>&1 &
WPID=$!
for _ in $(seq 100); do [ -S "$XDG/$SOCK" ] && break; kill -0 $WPID 2>/dev/null || break; sleep 0.1; done
[ -S "$XDG/$SOCK" ] || fatal "weston-did-not-start"
pass "weston pid=$WPID"

# A clean environment like the unit's: no inherited LD_LIBRARY_PATH or ALSOFT_CONF. The audio
# driver overrides only keep the laptop's sound devices out of the test.
(
	cd "$APP" || exit 1
	exec env -i PATH=/usr/bin:/bin HOME="$OUT/home" USER="$(id -un)" \
		XDG_CONFIG_HOME="$CONFIG" XDG_STATE_HOME="$STATE" XDG_CACHE_HOME="$CACHE" \
		XDG_RUNTIME_DIR="$XDG" WAYLAND_DISPLAY=$SOCK \
		GALLIUM_DRIVER=zink LIBGL_ALWAYS_SOFTWARE=1 VK_ICD_FILENAMES="$LVP_ICD" \
		MESA_GLES_VERSION_OVERRIDE=3.0 MESA_GLSL_VERSION_OVERRIDE=300 \
		SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null \
		MBHAXE_GLCHECK=1 MBHAXE_AUTOPLAY=beginner:0 MBHAXE_AUTOPLAY_DELAY=450 \
		MBHAXE_SHOT_DIR="$OUT/shots" MBHAXE_SHOT_FRAMES=1000 MBHAXE_EXIT_FRAME=1100 \
		timeout -s TERM -k 10 "$TIMEOUT" "$APP/launch"
) >"$OUT/game.out" 2>&1 &
GPID=$!
# timeout forks the game: find the child and sample its maps and peak RSS until it exits.
CPID='' HWM=0
while kill -0 $GPID 2>/dev/null; do
	[ -n "$CPID" ] || CPID=$(pgrep -P $GPID -x marblegame | head -1)
	if [ -n "$CPID" ] && [ -r "/proc/$CPID/maps" ]; then
		grep -q 'libopenal' "/proc/$CPID/maps" 2>/dev/null && cp "/proc/$CPID/maps" "$OUT/maps.txt" 2>/dev/null
		h=$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB/\1/p' "/proc/$CPID/status" 2>/dev/null)
		[ -n "$h" ] && [ "$h" -gt "$HWM" ] && HWM=$h
		tr '\0' '\n' < "/proc/$CPID/environ" > "$OUT/game.environ" 2>/dev/null
		readlink "/proc/$CPID/cwd" > "$OUT/game.cwd" 2>/dev/null
	fi
	sleep 0.5
done
wait $GPID
GRC=$?
GPID=''
LOG=$OUT/game-all.log
cat "$OUT/game.out" "$STATE/mbhaxe/console.log" > "$LOG" 2>/dev/null

[ $GRC = 0 ] && pass "launch-exit rc=0" || fail "launch-exit rc=$GRC"
GLV=$(grep -m1 -o 'GL_VERSION: .*' "$LOG")
echo "$GLV" | grep -q 'GL_VERSION: OpenGL ES 3\.0 .*GL_RENDERER: zink' && pass "gl ${GLV}" || fail "gl-not-es30-zink ${GLV:-none}"
EXITLINE=$(grep -m1 -o '\[diag\] exit at frame [0-9]*, GL errors seen: [0-9]*' "$LOG")
[ -n "$EXITLINE" ] && [ "${EXITLINE##*: }" = 0 ] && pass "gl-errors 0 ($EXITLINE)" || fail "gl-errors ${EXITLINE:-no-diag-exit-line}"
grep -q '\[diag\] autoplay ' "$LOG" && pass "mission-started" || fail "mission-not-started"

[ "$(cat "$OUT/game.cwd" 2>/dev/null)" = "$STATE/mbhaxe" ] && pass "cwd $STATE/mbhaxe" || fail "cwd $(cat "$OUT/game.cwd" 2>/dev/null)"
if [ -s "$OUT/maps.txt" ]; then
	for lib in lib/libopenal.so.1 lib/libsndio.so.7.0 lib/libvorbisfile.so.3 lib/libturbojpeg.so.0 lib/libuv.so.1 \
		libhl.so.1 openal.hdll sdl.hdll fmt.hdll ui.hdll uv.hdll ssl.hdll; do
		grep -q " $APP/$lib\$" "$OUT/maps.txt" && pass "mapped $lib from app dir" || fail "not-mapped-from-app $lib"
	done
	grep -E '/(libopenal|libsndio|libvorbisfile|libturbojpeg|libuv)\.so' "$OUT/maps.txt" | grep -v " $APP/" \
		| awk '{print $6}' | sort -u > "$OUT/host-copies.txt"
	[ -s "$OUT/host-copies.txt" ] && fail "host-copy-mapped $(tr '\n' ' ' < "$OUT/host-copies.txt")" || pass "no host copy of a bundled library"
else
	fail "no-maps-sample"
fi
grep -qx "ALSOFT_CONF=$APP/alsoft.conf" "$OUT/game.environ" && grep -qx "LD_LIBRARY_PATH=$APP/lib" "$OUT/game.environ" \
	&& grep -qx "TMPDIR=$CACHE/mbhaxe/tmp" "$OUT/game.environ" && pass "launch environment (ALSOFT_CONF, LD_LIBRARY_PATH, TMPDIR)" \
	|| fail "launch-environment $(grep -E '^(ALSOFT_CONF|LD_LIBRARY_PATH|TMPDIR|SDL_VIDEODRIVER)=' "$OUT/game.environ" | tr '\n' ' ')"
if [ $LAYOUT = release ]; then
	grep -qx "MBHAXE_DATA_DIR=$DATA" "$OUT/game.environ" && pass "MBHAXE_DATA_DIR=$DATA" \
		|| fail "data-dir-env $(grep '^MBHAXE_DATA_DIR=' "$OUT/game.environ" || echo unset)"
else
	grep -q '^MBHAXE_DATA_DIR=' "$OUT/game.environ" && fail "data-dir-env-set-in-dev-layout $(grep '^MBHAXE_DATA_DIR=' "$OUT/game.environ")" \
		|| pass "MBHAXE_DATA_DIR unset (data/ in the app dir)"
fi
grep -qx "MBHAXE_CACHE_DIR=$CACHE/mbhaxe/converted" "$OUT/game.environ" && [ -f "$CACHE/mbhaxe/converted/cache.dat" ] \
	&& grep -q "Converter cache: .*/mbhaxe/converted/$" "$LOG" \
	&& pass "converter cache in $CACHE/mbhaxe/converted ($(find "$CACHE/mbhaxe/converted" -type f | wc -l) files)" \
	|| fail "converter-cache $(grep -o 'Converter cache: .*' "$LOG" | head -1)"
(cd "$DATA" && find . -mindepth 1 -printf '%p %s %T@\n' | LC_ALL=C sort) > "$OUT/data-after.list"
cmp -s "$OUT/data-before.list" "$OUT/data-after.list" && pass "data dir unchanged ($(wc -l < "$OUT/data-before.list") entries)" \
	|| fail "data-dir-changed $(diff "$OUT/data-before.list" "$OUT/data-after.list" | head -3 | tr '\n' ' ')"
[ -f "$STATE/mbhaxe/settings.json" ] && [ -f "$STATE/mbhaxe/console.log" ] && pass "settings.json and console.log in state dir" \
	|| fail "state-files-missing $(ls -A "$STATE/mbhaxe" | tr '\n' ' ')"
(cd "$APP" && find . -mindepth 1 | LC_ALL=C sort) > "$OUT/app-after.list"
cmp -s "$OUT/app-before.list" "$OUT/app-after.list" && (cd "$APP" && sha256sum --quiet --strict -c SHA256SUMS) \
	&& pass "app dir unchanged (same entries, SHA256SUMS verify)" || fail "app-dir-changed"
echo "info peak_rss_kib=$HWM app_dir_bytes=$(du -sb "$APP" | cut -f1) data_bytes=$(du -sb "$DATA" | cut -f1) state_bytes=$(du -sb "$STATE" | cut -f1) cache_bytes=$(du -sb "$CACHE" | cut -f1)"

if [ $FAILS = 0 ]; then echo "RESULT PASS"; exit 0; else echo "RESULT FAIL ($FAILS)"; exit 1; fi
