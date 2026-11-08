#!/bin/bash
# Consistency of the build pins: the Containerfile and the CI workflow use PF_BASE_IMAGE from
# pins.lock, and LOCK.md mirrors pins.lock and deps.lock. Prints "check-pins=PASS|FAIL".
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
. "$PF_BUILD_DIR/pins.lock"
REPO=$(cd "$PF_BUILD_DIR/../.." && pwd)
. "$REPO/pocketforge/deps.lock"
fail=0
check() { if eval "$2"; then echo "check=$1 status=PASS"; else echo "check=$1 status=FAIL"; fail=1; fi; }

check containerfile-from "grep -qxF 'FROM $PF_BASE_IMAGE' '$PF_BUILD_DIR/Containerfile'"
# Every container image in the CI workflow is the pinned base.
WF=$REPO/.github/workflows/pocketforge-build.yml
check workflow-present "[ -f '$WF' ]"
# shellcheck disable=SC2034 # used by eval in check()
wf_images=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$WF" | sort -u)
# shellcheck disable=SC2016 # expanded by eval in check()
check workflow-image '[ "$wf_images" = "$PF_BASE_IMAGE" ]'
for v in "${PF_BASE_IMAGE#*@}" "$PF_DEBIAN_SNAPSHOT" "$HEAPS_SHA" "$HASHLINK_SHA" "$HAXE_SHA256" "$NEKO_SHA256" \
	"$FORMAT_ZIP_SHA256" "$COLYSEUS_WEBSOCKET_ZIP_SHA256"; do
	check "LOCK.md-has-${v:0:19}" "grep -qF '$v' '$REPO/LOCK.md'"
done
for k in "$PF_BUILD_DIR"/keys/*.asc; do
	check "LOCK.md-has-key-$(basename "$k")" "grep -qF '$(pf_sha256 "$k")' '$REPO/LOCK.md'"
done
if [ "$fail" = 0 ]; then echo check-pins=PASS; else echo check-pins=FAIL; fi
exit "$fail"
