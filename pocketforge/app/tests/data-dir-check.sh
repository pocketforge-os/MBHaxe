#!/bin/bash
# Red tests for the game-data location (tsp-0qwbh.9): the staged app, run through `launch` with no
# display, must refuse a bad data directory at start with a clear message on stderr and exit status
# 2, before it opens a window. Needs no game data: every case fails before anything is loaded.
#
# usage: pocketforge/app/tests/data-dir-check.sh --root STAGING [--work DIR]
#   STAGING  stage-app.sh output (either layout); only its app root is used
#
# Cases:
#   var-symlink        pf-app@ layout, /var/lib/pocketforge/apps/<id>/data is a symlink (launch
#                      passes it as MBHAXE_DATA_DIR)
#   env-symlink        MBHAXE_DATA_DIR names a symlink called data
#   env-missing        MBHAXE_DATA_DIR names a directory that does not exist
#   env-wrong-name     MBHAXE_DATA_DIR names a real directory not called data
#   app-symlink        no MBHAXE_DATA_DIR, data/ beside marblegame is a symlink (upstream layout)
#   app-missing        no MBHAXE_DATA_DIR, no data/ beside marblegame
# Prints "test=<name> result=ok|FAILED" per case and "data-dir-check=PASS|FAIL"; exit 1 on failure.
set -uo pipefail
APP_ID=org.pocketforge.mbhaxe
ROOT='' WORK=''
while [ $# -gt 0 ]; do
	case $1 in
	--root) ROOT=$2; shift 2 ;;
	--work) WORK=$2; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
APP=$ROOT/opt/pocketforge/apps/$APP_ID
if [ ! -x "$APP/launch" ] || [ ! -x "$APP/marblegame" ]; then echo "data-dir-check=FAIL reason=no-staged-app $APP"; exit 1; fi
if [ -z "$WORK" ]; then WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
rm -rf "$WORK/dd"
mkdir -p "$WORK/dd"
W=$WORK/dd
fail=0

# A copy of the app root without data/ (hard links where possible), for the app-relative cases.
mkdir -p "$W/app"
for f in "$APP"/*; do
	[ "$(basename "$f")" = data ] && continue
	cp -al "$f" "$W/app/" 2>/dev/null || cp -a "$f" "$W/app/"
done
mkdir -p "$W/real/data" "$W/real/notdata" "$W/link" "$W/home"
ln -s "$W/real/data" "$W/link/data"
VAR=$W/var/lib/pocketforge/apps/$APP_ID
mkdir -p "$VAR/state" "$W/var/cache/pocketforge/apps/$APP_ID"
ln -s "$W/real/data" "$VAR/data"

# case NAME LAUNCH EXPECT-REGEX [VAR=VALUE...]
case_() {
	local name=$1 launch=$2 want=$3
	shift 3
	local out=$W/$name.out rc
	env -i PATH=/usr/bin:/bin HOME="$W/home" \
		XDG_STATE_HOME="$VAR/state" XDG_CACHE_HOME="$W/var/cache/pocketforge/apps/$APP_ID" \
		XDG_RUNTIME_DIR="$W/no-runtime" SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null "$@" \
		timeout -s TERM -k 5 60 "$launch" > "$out" 2>&1
	rc=$?
	if [ $rc = 2 ] && grep -Eq "^MBHaxe: $want" "$out"; then
		echo "test=$name result=ok ($(grep -m1 '^MBHaxe: ' "$out"))"
	else
		echo "test=$name result=FAILED rc=$rc ($(head -c 300 "$out" | tr '\n' ' '))"
		fail=1
	fi
}

# pf-app@ layout: no data/ in the app copy, the var data is a symlink.
case_ var-symlink "$W/app/launch" "$VAR/data is a symlink to $W/real/data; it must be a real directory \\(MBHAXE_DATA_DIR\\)"
rm "$VAR/data"
case_ env-symlink "$W/app/launch" "$W/link/data is a symlink to $W/real/data; it must be a real directory" MBHAXE_DATA_DIR="$W/link/data"
case_ env-missing "$W/app/launch" "game data not found: $W/missing/data must be a directory .*\\(MBHAXE_DATA_DIR\\)" MBHAXE_DATA_DIR="$W/missing/data"
case_ env-wrong-name "$W/app/launch" "MBHAXE_DATA_DIR=$W/real/notdata: the directory must be called \"data\"" MBHAXE_DATA_DIR="$W/real/notdata"
case_ app-missing "$W/app/launch" "game data not found: $W/app/data must be a directory holding the Marble Blast Ultra data\\.$"
ln -s "$W/real/data" "$W/app/data"
case_ app-symlink "$W/app/launch" "$W/app/data is a symlink to $W/real/data; it must be a real directory next to the executable\\."

if [ $fail = 0 ]; then echo "data-dir-check=PASS"; exit 0; else echo "data-dir-check=FAIL"; exit 1; fi
