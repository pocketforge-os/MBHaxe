#!/bin/bash
# Stage the MBHaxe PocketForge app into a root-filesystem-shaped directory on a build host
# (tsp-0qwbh.5, tsp-0qwbh.9): the dev install's laptop half (DEV-INSTALL.md). Nothing here touches
# a device.
#
# usage: pocketforge/app/stage-app.sh --app-artifact APP.app.tar.zst --root STAGING
#            [--data-archive PATH] [--data-layout dev|release]
#            [--policy-render BIN --platform-contract FILE --resource-inventory FILE]
#   --app-artifact        app-root.sh output; its .sha256 file (next to it) must match
#   --root STAGING        new or empty directory; receives the device paths below
#   --data-archive PATH   local copy of the [fetch] archive (verified by pf-fetch.py); without it
#                         pf-fetch.py downloads the pinned URL
#   --data-layout         dev (default): data/ inside the app directory (pf-fetch.py --root), what
#                         the current image's pf-app@ sandbox can read; release: data/ where
#                         [fetch].destination = "var" puts it, var/lib/pocketforge/apps/<id>/data,
#                         and nothing inside the app directory (the release path, DEV-INSTALL.md)
#   --policy-render ...   runtime pf-app-policy-render, the device's platform contract
#                         (/usr/share/pocketforge/platform-capabilities.toml) and the image's
#                         resource inventory (build/app-policy-a133-open-g1-v1.json): installs the
#                         inventory and renders the pf-app@ systemd drop-in
#
# Result (paths are the device's, under STAGING):
#   opt/pocketforge/apps/org.pocketforge.mbhaxe/            app root (+ fetched data/ in the dev layout)
#   var/lib/pocketforge/apps/org.pocketforge.mbhaxe/data/   fetched data/ (release layout)
#   usr/share/pocketforge/app-policy/org.pocketforge.mbhaxe.resources.json      (with --policy-*)
#   etc/systemd/system/pf-app@org.pocketforge.mbhaxe.service.d/10-policy.conf   (with --policy-*)
#   PF-STAGE.files    the paths above (what to install and, later, remove)
#   PF-STAGE.sha256   sha256 of every staged file
# The game data under data/ is upstream's: stage it only on hosts and devices you control and
# never upload or re-host the staging tree.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
APP_ID=org.pocketforge.mbhaxe
ART='' ROOT='' DATA='' LAYOUT=dev RENDER='' CONTRACT='' INVENTORY=''
die() { echo "stage-app: $*" >&2; exit 1; }
while [ $# -gt 0 ]; do
	case $1 in
	--app-artifact) ART=$2; shift 2 ;;
	--root) ROOT=$2; shift 2 ;;
	--data-archive) DATA=$2; shift 2 ;;
	--data-layout) LAYOUT=$2; shift 2 ;;
	--policy-render) RENDER=$2; shift 2 ;;
	--platform-contract) CONTRACT=$2; shift 2 ;;
	--resource-inventory) INVENTORY=$2; shift 2 ;;
	-h | --help) sed -n '2,31p' "$0"; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[ -f "$ART" ] || die "--app-artifact is required"
[ -f "$ART.sha256" ] || die "missing $ART.sha256"
[ "$(sha256sum "$ART" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$ART.sha256")" ] || die "app artifact sha256 mismatch"
[ -n "$ROOT" ] || die "--root is required"
case $LAYOUT in dev | release) ;; *) die "--data-layout must be dev or release" ;; esac
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd -P)
[ -z "$(ls -A "$ROOT")" ] || die "$ROOT is not empty"
if [ -n "$RENDER$CONTRACT$INVENTORY" ]; then
	if [ ! -x "$RENDER" ] || [ ! -f "$CONTRACT" ] || [ ! -f "$INVENTORY" ]; then
		die "--policy-render, --platform-contract and --resource-inventory go together"
	fi
fi

APPS=$ROOT/opt/pocketforge/apps
APP=$APPS/$APP_ID
mkdir -p "$APPS"
zstd -dc "$ART" | tar -xf - -C "$APPS" --no-same-owner
[ "$(ls -A "$APPS")" = "$APP_ID" ] || die "app artifact does not hold exactly $APP_ID/"
(cd "$APP" && sha256sum --quiet --strict -c SHA256SUMS) || die "app root SHA256SUMS does not verify"

VAR=$ROOT/var/lib/pocketforge/apps/$APP_ID
if [ "$LAYOUT" = dev ]; then
	fetch_args=(--app-toml "$APP/app.toml" --root "$APP")
else
	mkdir -p "$VAR"
	fetch_args=(--app-toml "$APP/app.toml" --var-root "$VAR")
fi
[ -z "$DATA" ] || fetch_args+=(--from-file "$DATA")
python3 -I "$HERE/pf-fetch.py" "${fetch_args[@]}"

if [ -n "$RENDER" ]; then
	install -D -m 0644 "$INVENTORY" "$ROOT/usr/share/pocketforge/app-policy/$APP_ID.resources.json"
	dropin=$ROOT/etc/systemd/system/pf-app@$APP_ID.service.d/10-policy.conf
	mkdir -p "$(dirname "$dropin")"
	"$RENDER" --manifest "$APP/app.toml" --platform-contract "$CONTRACT" \
		--resource-inventory "$ROOT/usr/share/pocketforge/app-policy/$APP_ID.resources.json" \
		--app-dir "/opt/pocketforge/apps/$APP_ID" --platform-runtime /usr \
		--xdg-config "/var/lib/pocketforge/apps/$APP_ID/config" \
		--xdg-state "/var/lib/pocketforge/apps/$APP_ID/state" \
		--xdg-cache "/var/cache/pocketforge/apps/$APP_ID" \
		--format systemd-dropin > "$dropin.tmp"
	mv "$dropin.tmp" "$dropin"
	chmod 0644 "$dropin"
fi

{
	echo "opt/pocketforge/apps/$APP_ID"
	[ "$LAYOUT" = dev ] || echo "var/lib/pocketforge/apps/$APP_ID/data"
	[ -z "$RENDER" ] || echo "usr/share/pocketforge/app-policy/$APP_ID.resources.json"
	[ -z "$RENDER" ] || echo "etc/systemd/system/pf-app@$APP_ID.service.d"
} > "$ROOT/PF-STAGE.files"
(cd "$ROOT" && find opt usr etc var -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum) > "$ROOT/PF-STAGE.sha256"
echo "stage=PASS root=$ROOT layout=$LAYOUT app=$APP files=$(wc -l < "$ROOT/PF-STAGE.sha256") bytes=$(du -sbc "$ROOT/opt" "$ROOT/var" 2>/dev/null | tail -1 | cut -f1)"
