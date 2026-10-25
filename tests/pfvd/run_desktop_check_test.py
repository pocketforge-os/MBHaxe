#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("run-desktop-check.py")
SPEC = importlib.util.spec_from_file_location("run_desktop_check", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        self.elf = self.repo / ".pf-build/stage/x86_64-diag/mbhaxe-pf/marblegame"
        self.elf.parent.mkdir(parents=True)
        self.elf.write_bytes(b"exact elf")
        self.out = self.repo / ".pf-build/out"
        self.out.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self, commit="a" * 40, elf_sha=None):
        if elf_sha is None:
            elf_sha = hashlib.sha256(self.elf.read_bytes()).hexdigest()
        body = {"sources": {"MBHaxe": {"commit": commit, "dirty": False}},
                "files": [{"path": "marblegame", "sha256": elf_sha}]}
        (self.out / "fixture-x86_64-diag.manifest.json").write_text(json.dumps(body))

    def git_repo(self):
        repo = self.repo / "source"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", repo], check=True)
        tracked = repo / "tracked"
        tracked.write_text("clean\n")
        subprocess.run(["git", "-C", repo, "add", "tracked"], check=True)
        subprocess.run(
            ["git", "-C", repo, "-c", "user.name=test", "-c", "user.email=test@example.invalid",
             "commit", "-qm", "fixture"], check=True,
        )
        return repo, tracked

    def test_accepts_exact_commit_and_elf(self):
        self.manifest()
        result = MODULE.verify_build(self.repo, "a" * 40)
        self.assertEqual(result["elf_sha256"], hashlib.sha256(b"exact elf").hexdigest())

    def test_rejects_stale_commit(self):
        self.manifest(commit="b" * 40)
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            MODULE.verify_build(self.repo, "a" * 40)

    def test_rejects_wrong_elf(self):
        self.manifest(elf_sha="0" * 64)
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            MODULE.verify_build(self.repo, "a" * 40)

    def test_checkout_requires_clean_tracked_files(self):
        repo, tracked = self.git_repo()
        self.assertEqual(len(MODULE.clean_checkout_commit(repo)), 40)
        tracked.write_text("modified\n")
        with self.assertRaisesRegex(RuntimeError, "not clean"):
            MODULE.clean_checkout_commit(repo)

    def test_checkout_rejects_untracked_files(self):
        repo, _ = self.git_repo()
        (repo / "untracked").write_text("unexpected\n")
        with self.assertRaisesRegex(RuntimeError, "not clean"):
            MODULE.clean_checkout_commit(repo)


if __name__ == "__main__":
    unittest.main()
