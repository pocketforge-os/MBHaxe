#!/bin/bash
# Regression test for stage-app modes and the DEV-INSTALL section 3 tar command.
# The fixture is synthetic: no game data is downloaded, stored, or uploaded.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
DOC=$REPO/pocketforge/app/DEV-INSTALL.md
STAGE_APP=$REPO/pocketforge/app/stage-app.sh
APP_ID=org.pocketforge.mbhaxe
WORK=${1:-}
if [ -z "$WORK" ]; then
	WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/mbhaxe-stage-test.XXXXXX")
	# shellcheck disable=SC2317 # invoked by the EXIT trap
	cleanup() { find "$WORK" -mindepth 1 -delete; rmdir "$WORK"; }
	trap cleanup EXIT
else
	mkdir -p "$WORK"
	WORK=$(cd "$WORK" && pwd -P)
	find "$WORK" -mindepth 1 -delete
fi
chmod 0755 "$WORK"

fail=0
check() {
	local name=$1
	shift
	if "$@"; then
		echo "test=$name result=ok"
	else
		echo "test=$name result=FAILED" >&2
		fail=1
	fi
}

# Build a minimal app artifact and a local [fetch] archive. Explicit fixture modes
# ensure the staging umask, rather than fixture creation, is what the test observes.
mkdir -p "$WORK/app/$APP_ID" "$WORK/data/top/data/sub"
printf '#!/bin/sh\nprintf "fixture-launch=PASS\\n"\n' > "$WORK/app/$APP_ID/launch"
printf 'fixture-data\n' > "$WORK/data/top/data/sub/asset.txt"
chmod 0755 "$WORK/app/$APP_ID/launch"
chmod 0644 "$WORK/data/top/data/sub/asset.txt"
tar -C "$WORK/data" -czf "$WORK/data.tar.gz" top
data_sha=$(sha256sum "$WORK/data.tar.gz" | cut -d' ' -f1)
data_size=$(stat -c %s "$WORK/data.tar.gz")
printf '%s\n' \
	'schema_version = 2' \
	'[app]' \
	'id = "org.pocketforge.mbhaxe"' \
	'[fetch]' \
	'enabled = true' \
	'[[fetch.files]]' \
	'url = "https://example.invalid/data.tar.gz"' \
	"sha256 = \"$data_sha\"" \
	"size = $data_size" \
	'format = "tar.gz"' \
	'strip_components = 2' \
	'dest = "data"' > "$WORK/app/$APP_ID/app.toml"
(cd "$WORK/app/$APP_ID" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$WORK/SHA256SUMS"
mv "$WORK/SHA256SUMS" "$WORK/app/$APP_ID/SHA256SUMS"
tar -C "$WORK/app" -cf - "$APP_ID" | zstd -q -o "$WORK/app.tar.zst"
sha256sum "$WORK/app.tar.zst" > "$WORK/app.tar.zst.sha256"
printf 'contract fixture\n' > "$WORK/contract.toml"
printf '{"fixture":true}\n' > "$WORK/inventory.json"
printf '#!/bin/sh\nprintf "[Service]\\nReadOnlyPaths=/opt/pocketforge/apps/org.pocketforge.mbhaxe\\n"\n' > "$WORK/policy-render"
chmod 0755 "$WORK/policy-render"

mkdir "$WORK/stage"
(umask 077; "$STAGE_APP" \
	--app-artifact "$WORK/app.tar.zst" \
	--root "$WORK/stage" \
	--data-archive "$WORK/data.tar.gz" \
	--policy-render "$WORK/policy-render" \
	--platform-contract "$WORK/contract.toml" \
	--resource-inventory "$WORK/inventory.json")

bad_dirs=$(find "$WORK/stage" -type d ! -perm 0755 -printf '%m %P\n')
bad_exec=$(find "$WORK/stage" -type f -perm /111 ! -perm 0755 -printf '%m %P\n')
bad_files=$(find "$WORK/stage" -type f ! -perm /111 ! -perm 0644 -printf '%m %P\n')
check stage-directories-mode test -z "$bad_dirs"
check stage-executables-mode test -z "$bad_exec"
check stage-files-mode test -z "$bad_files"
if [ -n "$bad_dirs$bad_exec$bad_files" ]; then
	printf 'unexpected_modes:\n%s%s%s' "$bad_dirs" "$bad_exec" "$bad_files" >&2
fi

launch=$WORK/stage/opt/pocketforge/apps/$APP_ID/launch
if [ "$(id -u)" = 0 ]; then
	check unprivileged-traverse-and-exec setpriv --reuid=65534 --regid=65534 --clear-groups "$launch"
else
	check unprivileged-traverse-and-exec "$launch"
fi

# Extract, rather than copy, section 3's preflight targets and tar command. The
# only command transformation redirects installation from / into the fixture root.
python3 -I - "$DOC" "$WORK/doc-command.sh" "$WORK/preflight-targets" <<'PY'
import pathlib, re, shlex, sys

text = pathlib.Path(sys.argv[1]).read_text()
section = text.split("## 3. Install", 1)[1].split("## 4.", 1)[0]
block = re.search(r"```sh\n(.*?)```", section, re.S).group(1)
lines = block.splitlines()
preflights = []
command = []
collect = False
for line in lines:
    if line.startswith("sudo -n test ! -e "):
        words = shlex.split(line.split("#", 1)[0])
        preflights.append(words[-1])
    if line.startswith("sudo -n tar "):
        collect = True
    if collect:
        command.append(line)
        if not line.rstrip().endswith("\\"):
            break
if not command:
    raise SystemExit("section 3 has no sudo -n tar command")
cmd = "\n".join(command).replace("sudo -n tar ", "tar ", 1)
cmd = cmd.replace(" -C / ", ' -C "$INSTALL_ROOT" ', 1)
pathlib.Path(sys.argv[2]).write_text(cmd + "\n")
pathlib.Path(sys.argv[3]).write_text("\n".join(preflights) + "\n")
PY

mapfile -t targets < "$WORK/preflight-targets"
check documented-three-target-preflights test "${#targets[@]}" -eq 3
preflight_ok=1
for target in "${targets[@]}"; do [ ! -e "$WORK/install$target" ] || preflight_ok=0; done
check documented-preflight-positive test "$preflight_ok" -eq 1
negative_ok=1
for target in "${targets[@]}"; do
	case $target in
	*.json) mkdir -p "$WORK/install-negative$(dirname "$target")"; : > "$WORK/install-negative$target" ;;
	*) mkdir -p "$WORK/install-negative$target" ;;
	esac
	if [ ! -e "$WORK/install-negative$target" ]; then negative_ok=0; fi
	find "$WORK/install-negative" -mindepth 1 -delete
done
check documented-preflight-negative test "$negative_ok" -eq 1

tar -C "$WORK/stage" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
	-cf "$WORK/mbhaxe-stage.tar" opt usr etc PF-STAGE.files PF-STAGE.sha256
mkdir -p "$WORK/install/opt" "$WORK/install/usr" "$WORK/install/etc"
if (cd "$WORK" && INSTALL_ROOT=$WORK/install R=$WORK eval "$(cat "$WORK/doc-command.sh")"); then
	doc_rc=0
else
	doc_rc=$?
fi
check documented-install-tar-runs test "$doc_rc" -eq 0

if [ "$fail" = 0 ]; then echo 'stage-app-install=PASS'; else echo 'stage-app-install=FAIL'; fi
exit "$fail"
