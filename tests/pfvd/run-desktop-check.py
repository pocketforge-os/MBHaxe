#!/usr/bin/env python3
"""Verify exact-build provenance, then run the pfvd desktop scenario."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_build(repo, commit):
    elf = repo / ".pf-build/stage/x86_64-diag/mbhaxe-pf/marblegame"
    matches = []
    for path in (repo / ".pf-build/out").glob("*-x86_64-diag.manifest.json"):
        manifest = json.loads(path.read_text())
        source = manifest.get("sources", {}).get("MBHaxe", {})
        files = {item.get("path"): item for item in manifest.get("files", [])}
        if source.get("commit") == commit and source.get("dirty") is False:
            matches.append((path, manifest, files.get("marblegame")))
    if len(matches) != 1:
        raise RuntimeError(f"expected one clean x86_64 diag manifest for HEAD, found {len(matches)}")
    manifest_path, _, entry = matches[0]
    if not entry or not isinstance(entry.get("sha256"), str):
        raise RuntimeError("manifest has no marblegame SHA256")
    elf_sha = sha256(elf)
    if elf_sha != entry["sha256"]:
        raise RuntimeError("marblegame SHA256 does not match the exact-HEAD manifest")
    return {
        "schema": "mbhaxe.pfvd.provenance/1",
        "source_commit": commit,
        "manifest": str(manifest_path.relative_to(repo)),
        "manifest_sha256": sha256(manifest_path),
        "elf": str(elf.relative_to(repo)),
        "elf_sha256": elf_sha,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pfvd-cli", required=True, type=Path)
    parser.add_argument("--report-dir", required=True, type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    commit = subprocess.check_output(
        ["git", "-C", repo, "rev-parse", "HEAD"], text=True
    ).strip()
    provenance = verify_build(repo, commit)
    cli = args.pfvd_cli.resolve(strict=True)
    provenance["pfvd_cli_sha256"] = sha256(cli)
    report = args.report_dir.resolve()
    report.mkdir(mode=0o700, parents=True, exist_ok=False)
    (report / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if args.verify_only:
        return
    app_state = report / "app-state"
    config = report / "pfvd-config"
    for path in (app_state, config):
        path.mkdir(mode=0o700)
    with tempfile.TemporaryDirectory(prefix="pfvd-", dir=repo / ".pf-build") as runtime:
        env = os.environ.copy()
        env.update(PFVD_RUNTIME_DIR=runtime, XDG_CONFIG_HOME=str(config))
        subprocess.run(
            [cli, "check", "--scenario", repo / "tests/pfvd/mbhaxe-desktop.toml",
             "--report-dir", report],
            cwd=app_state, env=env, check=True,
        )


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"run-desktop-check: {error}", file=sys.stderr)
        sys.exit(1)
