#!/bin/bash
# Build the MBHaxe builder image (Containerfile) if needed and run build.sh inside it.
#
# usage: pocketforge/build/container.sh --work DIR [--out DIR] <build.sh arguments...>
#   e.g. pocketforge/build/container.sh --work ~/mbhaxe-work --arch aarch64
#
# The repository is mounted at /src, WORK at /work, OUT (default WORK/out) at /out. A linked git
# worktree's common git dir is mounted read-only at its own path so build.sh can identify the
# source commit. Engine: $PF_OCI_ENGINE (default podman; nerdctl works the same way). The image
# tag is derived from the content of the build context, so editing it rebuilds the image.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
. "$PF_BUILD_DIR/lib.sh"
REPO=$(cd "$PF_BUILD_DIR/../.." && pwd -P)
ENGINE=${PF_OCI_ENGINE:-podman}
case $(basename "$ENGINE") in docker*) pf_die "Docker-branded tooling is not used here; set PF_OCI_ENGINE to podman or nerdctl" ;; esac
command -v "$ENGINE" > /dev/null || pf_die "$ENGINE not found (install podman, or set PF_OCI_ENGINE)"

WORK='' OUT='' ARGS=()
while [ $# -gt 0 ]; do
	case $1 in
	--work) WORK=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	*) ARGS+=("$1"); shift ;;
	esac
done
[ -n "$WORK" ] || pf_die "--work DIR is required"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
OUT=${OUT:-$WORK/out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)

ctx_sha=$(cd "$PF_BUILD_DIR" && cat Containerfile pins.lock lib.sh toolchain.sh keys/*.asc | sha256sum | cut -c1-16)
IMAGE=localhost/mbhaxe-pf-builder:$ctx_sha
if ! "$ENGINE" image inspect "$IMAGE" > /dev/null 2>&1; then
	pf_log "building builder image $IMAGE"
	"$ENGINE" build -t "$IMAGE" -f "$PF_BUILD_DIR/Containerfile" "$PF_BUILD_DIR" >&2
fi

MOUNTS=(-v "$REPO:/src" -v "$WORK:/work" -v "$OUT:/out")
common=$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
case $common in "$REPO"/*) ;; *) MOUNTS+=(-v "$common:$common:ro") ;; esac

pf_log "running build.sh in $IMAGE (engine $ENGINE)"
exec "$ENGINE" run --rm --network=host "${MOUNTS[@]}" -e GIT_OPTIONAL_LOCKS=0 -w /src "$IMAGE" \
	/src/pocketforge/build/build.sh --work /work --out /out "${ARGS[@]}"
