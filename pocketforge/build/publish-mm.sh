#!/bin/bash
# Publish a build's tarball and manifest to the PocketForge content-addressed artifact store
# (the interim "mm store"; never GitHub). Runs on a trusted host with ssh access to the store
# host, which provides pf-artifact-publish (pocketforge-automation). Each file lands at
# <base>/artifacts/sha256/<sha256>/<name>; the store is write-once per digest.
#
# usage: pocketforge/build/publish-mm.sh OUT/<arch>-<variant>.env
#   PF_ARTIFACT_SSH_HOST  ssh destination of the store host (default: mm)
# Prints "published name=... sha256=... url=..." per file after re-downloading and verifying it.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
ENV=${1:?usage: publish-mm.sh OUT/<arch>-<variant>.env}
HOST=${PF_ARTIFACT_SSH_HOST:-mm}
OUT=$(cd "$(dirname "$ENV")" && pwd -P)
name=$(sed -n 's/^name=//p' "$ENV")
dirty=$(sed -n 's/^dirty=//p' "$ENV")
[ -n "$name" ] || pf_die "no name= in $ENV"
[ "$dirty" = false ] || pf_die "refusing to publish a build of a dirty tree ($name)"
(cd "$OUT" && sha256sum -c --quiet "$name.tar.zst.sha256") || pf_die "tarball does not match its .sha256"

stage=$(ssh "$HOST" 'mktemp -d /tmp/pf-mbhaxe-publish.XXXXXX')
trap 'ssh "$HOST" "rm -rf -- $stage" || true' EXIT
for f in "$name.tar.zst" "$name.manifest.json"; do
	sum=$(pf_sha256 "$OUT/$f")
	scp -q "$OUT/$f" "$HOST:$stage/$f"
	url=$(ssh "$HOST" "PATH=\$HOME/pocketforge-automation/scripts:\$PATH pf-artifact-publish '$stage/$f' '$f'")
	case $url in */sha256/"$sum"/*) ;; *) pf_die "unexpected publish URL for $f: $url" ;; esac
	got=$(curl -fsS "$url" | sha256sum | cut -d' ' -f1)
	[ "$got" = "$sum" ] || pf_die "verification failed for $url (got $got)"
	echo "published name=$f sha256=$sum url=$url"
done
