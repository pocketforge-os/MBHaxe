#!/bin/bash
# Red/green tests for pf-fetch.py (tsp-0qwbh.5, tsp-0qwbh.9) on synthetic archives. No network.
#
# usage: pocketforge/app/tests/test-fetch.sh [--work DIR] [--real-archive PATH]
#   --real-archive PATH  also run the pinned app.toml against a local copy of the upstream
#                        archive with its sha256 altered (must be refused, nothing installed)
#
# Prints "test=<name> result=ok|FAILED" per case and "test-fetch=PASS|FAIL"; exit 1 on failure.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FETCH=$HERE/../pf-fetch.py
APP_TOML=$HERE/../app.toml
WORK='' REAL=''
while [ $# -gt 0 ]; do
	case $1 in
	--work) WORK=$2; shift 2 ;;
	--real-archive) REAL=$2; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "$WORK" ]; then WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT; fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)
rm -rf "$WORK/fx" "$WORK/cases"
mkdir -p "$WORK/fx" "$WORK/cases"
fail=0

# Fixtures: good.tar.gz mirrors the upstream layout (top/, top/<binaries>, top/data/...).
python3 -I - "$WORK/fx" <<'EOF'
import io, os, sys, tarfile
d = sys.argv[1]
def add(t, name, data=None, kind="file", mtime=1700000000, mode=0o644, link=""):
    ti = tarfile.TarInfo(name); ti.mtime = mtime; ti.mode = mode
    if kind == "dir": ti.type = tarfile.DIRTYPE; t.addfile(ti); return
    if kind == "sym": ti.type = tarfile.SYMTYPE; ti.linkname = link; t.addfile(ti); return
    if kind == "fifo": ti.type = tarfile.FIFOTYPE; t.addfile(ti); return
    ti.size = len(data); t.addfile(ti, io.BytesIO(data))
def make(name, extra):
    with tarfile.open(os.path.join(d, name), "w:gz") as t:
        add(t, "top/", kind="dir"); add(t, "top/marblegame", b"\x7fELF", mode=0o755)
        add(t, "top/data/", kind="dir"); add(t, "top/data/a.txt", b"alpha\n", mtime=1600000000)
        add(t, "top/data/sub/", kind="dir"); add(t, "top/data/sub/b.bin", b"\0" * 4096, mode=0o4755)
        extra(t)
make("good.tar.gz", lambda t: None)
make("traversal.tar.gz", lambda t: add(t, "top/data/../../../evil.txt", b"x"))
make("absolute.tar.gz", lambda t: add(t, "/tmp/evil.txt", b"x"))
make("symlink.tar.gz", lambda t: add(t, "top/data/link", kind="sym", link="../../../etc/passwd"))
make("fifo.tar.gz", lambda t: add(t, "top/data/fifo", kind="fifo"))
EOF

toml() { # file archive [sha] [size] [url] [destination] -> app.toml with one [[fetch.files]] entry
	local sha=${3:-$(sha256sum "$2" | cut -d' ' -f1)} size=${4:-$(stat -c %s "$2")}
	cat > "$1" <<EOF
schema_version = 2
[app]
id = "org.example.fixture"
[fetch]
enabled = true
${6:+destination = \"$6\"}
[[fetch.files]]
url = "${5:-https://example.invalid/fixture.tar.gz}"
sha256 = "$sha"
size = $size
format = "tar.gz"
strip_components = 2
dest = "data"
EOF
}
run() { python3 -I "$FETCH" "$@" > "$C/out" 2> "$C/err"; }
check() { # name condition-result
	if [ "$2" = 0 ]; then echo "test=$1 result=ok"; else echo "test=$1 result=FAILED ($(tail -1 "$C/out" 2>/dev/null))"; fail=1; fi
}
newcase() { C=$WORK/cases/$1; mkdir -p "$C/root"; }
GOOD=$WORK/fx/good.tar.gz
ZERO=0000000000000000000000000000000000000000000000000000000000000000

newcase good; toml "$C/app.toml" "$GOOD"
r=0; run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" || r=1
[ $r = 0 ] && grep -q '^fetch=PASS .* files=2 ' "$C/out" && [ "$(cat "$C/root/data/a.txt")" = alpha ] \
	&& [ "$(stat -c %Y "$C/root/data/a.txt")" = 1600000000 ] && [ "$(stat -c %a "$C/root/data/sub/b.bin")" = 755 ] \
	&& [ ! -e "$C/root/data/marblegame" ] && [ ! -e "$C/root/marblegame" ] \
	&& [ -z "$(find "$C/root" -name '.data.*')" ]; check good-installs-data-only $?

newcase wrong-sha; toml "$C/app.toml" "$GOOD" "$ZERO"
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q '^fetch=FAIL reason=sha256_mismatch' "$C/out" && [ -z "$(ls -A "$C/root")" ]; check wrong-sha256-refused $?

newcase wrong-size; toml "$C/app.toml" "$GOOD" "" 100
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q '^fetch=FAIL reason=archive_is_larger' "$C/out" && [ -z "$(ls -A "$C/root")" ]; check wrong-size-refused $?

for bad in traversal absolute symlink fifo; do
	newcase $bad; toml "$C/app.toml" "$WORK/fx/$bad.tar.gz"
	run --app-toml "$C/app.toml" --root "$C/root" --from-file "$WORK/fx/$bad.tar.gz" && r=0 || r=$?
	[ $r = 1 ] && grep -q '^fetch=FAIL' "$C/out" && [ -z "$(ls -A "$C/root")" ] && [ ! -e "$WORK/cases/evil.txt" ] \
		&& [ ! -e "$WORK/evil.txt" ]; check "$bad-member-refused" $?
done

newcase http-url; toml "$C/app.toml" "$GOOD" "" "" "http://example.invalid/fixture.tar.gz"
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q 'url_is_not_https' "$C/out"; check http-url-refused $?

newcase latest-url; toml "$C/app.toml" "$GOOD" "" "" "https://example.invalid/releases/latest/download/x.tar.gz"
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q 'not_pinned' "$C/out"; check latest-url-refused $?

# An existing destination: refused without --replace; with --replace a bad archive leaves it intact.
newcase replace; toml "$C/app.toml" "$GOOD"; mkdir -p "$C/root/data"; echo old > "$C/root/data/old.txt"
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && [ "$(cat "$C/root/data/old.txt")" = old ]; check existing-dest-refused $?
toml "$C/app.toml" "$GOOD" "$ZERO"
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" --replace && r=0 || r=$?
[ $r = 1 ] && [ "$(cat "$C/root/data/old.txt")" = old ] && [ ! -e "$C/root/data/a.txt" ]; check replace-wrong-sha-keeps-old $?
toml "$C/app.toml" "$GOOD"
r=0; run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" --replace || r=1
[ $r = 0 ] && [ ! -e "$C/root/data/old.txt" ] && [ -f "$C/root/data/a.txt" ] \
	&& [ "$(ls -A "$C/root")" = data ]; check replace-good-swaps $?

# Destination roots: --root wins; else [fetch].destination ("var" -> --var-root, "home" ->
# XDG_DATA_HOME or --data-home); no destination and no --root is refused, as is an unknown one.
newcase dest-var; toml "$C/app.toml" "$GOOD" "" "" "" var; mkdir -p "$C/var"
r=0; run --app-toml "$C/app.toml" --var-root "$C/var" --from-file "$GOOD" || r=1
[ $r = 0 ] && grep -q "^fetch=PASS .* dest=$C/var/data " "$C/out" && [ "$(cat "$C/var/data/a.txt")" = alpha ] \
	&& [ -z "$(ls -A "$C/root")" ]; check destination-var-installs-in-var-root $?
newcase dest-root-wins; toml "$C/app.toml" "$GOOD" "" "" "" var; mkdir -p "$C/var"
r=0; run --app-toml "$C/app.toml" --root "$C/root" --var-root "$C/var" --from-file "$GOOD" || r=1
[ $r = 0 ] && [ -f "$C/root/data/a.txt" ] && [ -z "$(ls -A "$C/var")" ]; check root-overrides-destination $?
newcase dest-home; toml "$C/app.toml" "$GOOD" "" "" "" home; mkdir -p "$C/xdg"
r=0; XDG_DATA_HOME=$C/xdg run --app-toml "$C/app.toml" --from-file "$GOOD" || r=1
[ $r = 0 ] && [ -f "$C/xdg/data/a.txt" ]; check destination-home-installs-in-xdg-data-home $?
newcase dest-none; toml "$C/app.toml" "$GOOD"
run --app-toml "$C/app.toml" --var-root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q 'has_no_destination' "$C/out" && [ -z "$(ls -A "$C/root")" ]; check no-destination-refused $?
newcase dest-bad; toml "$C/app.toml" "$GOOD" "" "" "" opt
run --app-toml "$C/app.toml" --root "$C/root" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q 'destination_must_be' "$C/out" && [ -z "$(ls -A "$C/root")" ]; check unknown-destination-refused $?
newcase dest-var-missing-root; toml "$C/app.toml" "$GOOD" "" "" "" var
run --app-toml "$C/app.toml" --var-root "$C/nonexistent" --from-file "$GOOD" && r=0 || r=$?
[ $r = 1 ] && grep -q 'root_is_not_a_directory' "$C/out" && [ ! -e "$C/nonexistent" ]; check missing-destination-root-refused $?

if [ -n "$REAL" ]; then
	newcase real-wrong-sha
	sed 's/^sha256 = "[0-9a-f]*"$/sha256 = "'"$ZERO"'"/' "$APP_TOML" > "$C/app.toml"
	mkdir -p "$C/var"
	run --app-toml "$C/app.toml" --var-root "$C/var" --from-file "$REAL" && r=0 || r=$?
	[ $r = 1 ] && grep -q '^fetch=FAIL reason=sha256_mismatch' "$C/out" && [ -z "$(ls -A "$C/root")" ] \
		&& [ -z "$(ls -A "$C/var")" ]; check real-archive-wrong-sha256-refused $?
fi

if [ "$fail" = 0 ]; then echo "test-fetch=PASS"; else echo "test-fetch=FAIL"; fi
exit "$fail"
