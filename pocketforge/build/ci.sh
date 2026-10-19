#!/bin/bash
# CI entry point (forge-neutral): run as root in a job container whose image is PF_BASE_IMAGE.
# Turns the base into the builder (toolchain.sh, same script as the Containerfile), checks the
# pins, runs the gate red/green tests, then a --require-clean build plus the app root.
#
# usage: pocketforge/build/ci.sh <aarch64|x86_64> <product|diag> WORK
# Writes the build's key=value results to stdout and, when the forge provides one, to
# $GITHUB_OUTPUT (GitHub and Forgejo Actions both honour it). No artifact is uploaded here:
# public CI runners cannot reach the artifact store; publish-mm.sh publishes from a trusted host.
set -euo pipefail
PF_BUILD_DIR=$(cd "$(dirname "$0")" && pwd)
ARCH=${1:?usage: ci.sh ARCH VARIANT WORK} VARIANT=${2:?} WORK=${3:?}
export PF_IN_BUILDER_CONTAINER=1

if [ ! -f /etc/pf-builder-packages.txt ]; then
	"$PF_BUILD_DIR/toolchain.sh"
fi
"$PF_BUILD_DIR/check-pins.sh"
"$PF_BUILD_DIR/tests/gates-test.sh" --arch "$ARCH" --work "$WORK"
"$PF_BUILD_DIR/build.sh" --arch "$ARCH" --variant "$VARIANT" --work "$WORK" --out "$WORK/out" --require-clean --app-root
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	cat "$WORK/out/$ARCH-$VARIANT.env" "$WORK/out/$ARCH-$VARIANT.app.env" >> "$GITHUB_OUTPUT"
fi
