#!/usr/bin/env python3
"""Install an app's [fetch] files exactly as app.toml pins them (tsp-0qwbh.5).

usage: python3 -I pf-fetch.py --app-toml APP.TOML --root APPDIR [--from-file ARCHIVE]
                              [--cache DIR] [--replace]

For every [[fetch.files]] entry:
  1. obtain the archive: --from-file (a local copy), else download the pinned https URL into
     --cache (default: a temporary directory), reading at most `size` bytes;
  2. refuse unless the archive's size and SHA256 equal the pinned values;
  3. extract it into a new temporary directory beside the destination, applying
     strip_components with GNU tar semantics (a member with N or fewer path components is
     skipped, the first N components of the others are removed), and refuse unsafe members:
     absolute paths, "..", links, devices and FIFOs; file and directory modes are reduced to
     0755/0644, modification times are preserved (the game's converter cache compares them);
  4. install atomically: rename the temporary directory to ROOT/<dest>. An existing
     destination is refused unless --replace, which swaps it out first and deletes the old copy
     only after the rename succeeded.

On any refusal the destination is left as it was and the exit status is 1. The last line printed
is machine-readable: "fetch=PASS ..." or "fetch=FAIL reason=...".

This is the PocketForge reference for the manifest's [fetch] semantics, used to stage the app on a
build host (pocketforge/app/DEV-INSTALL.md). It needs only the Python standard library (3.11+ for
tomllib). The device itself has no Python; on the device the platform's fetch executor owns this
step. It never uploads or re-hosts what it downloads.
"""

import argparse
import hashlib
import os
import shutil
import sys
import tarfile
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request

FILE_KEYS = {"url", "sha256", "size", "format", "strip_components", "dest"}
REQUIRED_KEYS = {"url", "sha256", "size", "format", "dest"}
FORMATS = {"tar.gz": "r:gz"}
CHUNK = 1 << 20


class Refused(Exception):
    pass


def load_fetch(path):
    with open(path, "rb") as f:
        manifest = tomllib.load(f)
    fetch = manifest.get("fetch")
    if not isinstance(fetch, dict) or not fetch.get("enabled", False):
        raise Refused("app.toml has no enabled [fetch]")
    files = fetch.get("files")
    if not isinstance(files, list) or not files:
        raise Refused("[fetch] has no [[fetch.files]]")
    out = []
    for i, entry in enumerate(files):
        unknown = set(entry) - FILE_KEYS
        missing = REQUIRED_KEYS - set(entry)
        if unknown or missing:
            raise Refused(f"fetch.files[{i}]: unknown keys {sorted(unknown)} missing keys {sorted(missing)}")
        url = entry["url"]
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.netloc:
            raise Refused(f"fetch.files[{i}]: url is not https: {url}")
        if "/latest/" in parsed.path or parsed.path.endswith("/latest"):
            raise Refused(f"fetch.files[{i}]: url is not pinned (latest): {url}")
        sha = entry["sha256"]
        if not (isinstance(sha, str) and len(sha) == 64 and all(c in "0123456789abcdef" for c in sha)):
            raise Refused(f"fetch.files[{i}]: sha256 is not 64 lowercase hex digits")
        size = entry["size"]
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            raise Refused(f"fetch.files[{i}]: size is not a positive integer")
        if entry["format"] not in FORMATS:
            raise Refused(f"fetch.files[{i}]: unsupported format {entry['format']!r}")
        strip = entry.get("strip_components", 0)
        if not isinstance(strip, int) or isinstance(strip, bool) or strip < 0:
            raise Refused(f"fetch.files[{i}]: strip_components is not a non-negative integer")
        dest = entry["dest"]
        parts = dest.split("/") if isinstance(dest, str) else []
        if not parts or dest.startswith("/") or any(p in ("", ".", "..") for p in parts):
            raise Refused(f"fetch.files[{i}]: dest must be a relative path without . or ..: {dest!r}")
        out.append(dict(url=url, sha256=sha, size=size, format=entry["format"], strip=strip, dest=dest))
    return out


def hash_file(path, size_cap):
    h = hashlib.sha256()
    n = 0
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            n += len(b)
            if n > size_cap:
                raise Refused(f"archive is larger than the pinned size {size_cap}")
            h.update(b)
    return h.hexdigest(), n


def download(url, size, cache):
    os.makedirs(cache, exist_ok=True)
    final = os.path.join(cache, os.path.basename(urllib.parse.urlsplit(url).path) or "fetch.bin")
    fd, tmp = tempfile.mkstemp(dir=cache, prefix=".part-")
    n = 0
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "pocketforge-pf-fetch/1"})
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(req, timeout=60) as resp:
            if urllib.parse.urlsplit(resp.geturl()).scheme != "https":
                raise Refused(f"redirected off https: {resp.geturl()}")
            while True:
                b = resp.read(CHUNK)
                if not b:
                    break
                n += len(b)
                if n > size:
                    raise Refused(f"download exceeds the pinned size {size}")
                out.write(b)
        os.replace(tmp, final)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return final


def member_path(name, strip):
    """Return the stripped relative path, or None if GNU tar --strip-components would skip it."""
    if name.startswith("/"):
        raise Refused(f"absolute member path: {name}")
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if ".." in parts:
        raise Refused(f"member path with '..': {name}")
    if len(parts) <= strip:
        return None
    return "/".join(parts[strip:])


def extract(archive, mode, strip, target):
    """Extract into the (new, empty) directory target. Returns (files, bytes)."""
    files = nbytes = 0
    dirs = []
    with tarfile.open(archive, mode) as tar:
        for m in tar:
            rel = member_path(m.name, strip)
            if rel is None:
                continue
            if m.issym() or m.islnk():
                raise Refused(f"link member: {m.name}")
            if not (m.isreg() or m.isdir()):
                raise Refused(f"special member (device/FIFO/other): {m.name}")
            path = os.path.join(target, rel)
            parent = os.path.dirname(path)
            os.makedirs(parent, mode=0o755, exist_ok=True)
            if m.isdir():
                os.makedirs(path, mode=0o755, exist_ok=True)
                dirs.append((path, m.mtime))
                continue
            if os.path.lexists(path):
                raise Refused(f"duplicate member: {m.name}")
            src = tar.extractfile(m)
            with open(path, "xb") as out:
                shutil.copyfileobj(src, out, CHUNK)
            os.chmod(path, 0o755 if m.mode & 0o111 else 0o644)
            os.utime(path, (m.mtime, m.mtime))
            files += 1
            nbytes += m.size
    for path, mtime in sorted(dirs, key=lambda d: d[0].count("/"), reverse=True):
        os.chmod(path, 0o755)
        os.utime(path, (mtime, mtime))
    if files == 0:
        raise Refused("strip_components leaves no files")
    return files, nbytes


def install(entry, root, archive, replace):
    root = os.path.realpath(root)
    if not os.path.isdir(root):
        raise Refused(f"root is not a directory: {root}")
    dest = os.path.join(root, entry["dest"])
    parent = os.path.dirname(dest)
    if os.path.realpath(parent) != os.path.normpath(parent):
        raise Refused(f"a component of dest is a symlink: {entry['dest']}")
    if os.path.lexists(dest) and not replace:
        raise Refused(f"{dest} exists (use --replace)")
    if os.path.islink(dest) or (os.path.lexists(dest) and not os.path.isdir(dest)):
        raise Refused(f"{dest} exists and is not a directory")
    os.makedirs(parent, exist_ok=True)
    tmp = tempfile.mkdtemp(dir=parent, prefix=f".{os.path.basename(dest)}.fetch-")
    old = None
    try:
        files, nbytes = extract(archive, FORMATS[entry["format"]], entry["strip"], tmp)
        os.chmod(tmp, 0o755)
        if os.path.lexists(dest):
            old = tempfile.mkdtemp(dir=parent, prefix=f".{os.path.basename(dest)}.old-")
            os.rename(dest, os.path.join(old, "d"))
        os.rename(tmp, dest)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        if old is not None and not os.path.lexists(dest) and os.path.lexists(os.path.join(old, "d")):
            os.rename(os.path.join(old, "d"), dest)
        if old is not None:
            shutil.rmtree(old, ignore_errors=True)
        raise
    if old is not None:
        shutil.rmtree(old)
    return dest, files, nbytes


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--app-toml", required=True)
    ap.add_argument("--root", required=True, help="the app directory; dest is relative to it")
    ap.add_argument("--from-file", help="use this local copy of the archive (still verified)")
    ap.add_argument("--cache", help="download directory (default: a temporary directory)")
    ap.add_argument("--replace", action="store_true", help="replace an existing destination")
    args = ap.parse_args(argv)
    try:
        entries = load_fetch(args.app_toml)
        if args.from_file and len(entries) != 1:
            raise Refused("--from-file needs exactly one [[fetch.files]] entry")
        for entry in entries:
            with tempfile.TemporaryDirectory() as scratch:
                archive = args.from_file or download(entry["url"], entry["size"], args.cache or scratch)
                sha, size = hash_file(archive, entry["size"])
                if size != entry["size"]:
                    raise Refused(f"size mismatch: got {size}, pinned {entry['size']}")
                if sha != entry["sha256"]:
                    raise Refused(f"sha256 mismatch: got {sha}, pinned {entry['sha256']}")
                dest, files, nbytes = install(entry, args.root, archive, args.replace)
                print(f"fetch=PASS url={entry['url']} sha256={sha} size={size} dest={dest} files={files} bytes={nbytes}")
    except Refused as e:
        print(f"fetch=FAIL reason={str(e).replace(' ', '_')[:400]}", flush=True)
        print(f"pf-fetch: refused: {e}", file=sys.stderr)
        return 1
    except (OSError, tarfile.TarError, tomllib.TOMLDecodeError, urllib.error.URLError) as e:
        print(f"fetch=FAIL reason={type(e).__name__}", flush=True)
        print(f"pf-fetch: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
