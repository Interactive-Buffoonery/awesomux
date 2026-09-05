#!/usr/bin/env python3
"""Exercise native source preparation using a tiny local Git fixture."""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location("prepare", Path(__file__).with_name("prepare_ghostty_source.py"))
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


class SourcePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="awesomux-ghostty-source-test-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.vendor = root / "vendor"
        self.output = root / "output"
        (self.vendor / "src/apprt").mkdir(parents=True)
        (self.vendor / "src/terminal").mkdir(parents=True)
        (self.vendor / "src/apprt/embedded.zig").write_text("pub const CAPI = struct {\n};\n")
        (self.vendor / "src/terminal/main.zig").write_text("// fixture\n")
        self.git("init", "--quiet")
        self.commit()
        originals = prepare.INPUTS
        self.addCleanup(setattr, prepare, "INPUTS", originals)
        copied = []
        for index, path in enumerate(originals):
            destination = root / f"input-{index}"
            shutil.copyfile(path, destination)
            copied.append(destination)
        prepare.INPUTS = tuple(copied)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.vendor), *args], text=True).strip()

    def commit(self):
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "fixture")

    def test_preserves_vendor_and_reuses_matching_source(self):
        generated = prepare.prepare(self.vendor, self.output)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("awesomux_surface_read_scrollback", (generated / "src/apprt/embedded.zig").read_text())
        self.assertNotIn("awesomux_surface_read_scrollback", (self.vendor / "src/apprt/embedded.zig").read_text())
        self.assertEqual(generated, prepare.prepare(self.vendor, self.output))

    def test_extension_change_selects_fresh_source(self):
        before = prepare.prepare(self.vendor, self.output)
        with prepare.INPUTS[3].open("a") as file:
            file.write("\n// changed ABI\n")
        after = prepare.prepare(self.vendor, self.output)
        self.assertNotEqual(before, after)
        self.assertNotEqual((before / ".awesomux-extension").read_text(), (after / ".awesomux-extension").read_text())

    def test_incompatible_upstream_fails_without_publishing_source(self):
        (self.vendor / "src/apprt/embedded.zig").write_text("// incompatible upstream\n")
        self.commit()
        with self.assertRaisesRegex(RuntimeError, "Ghostty CAPI changed"):
            prepare.prepare(self.vendor, self.output)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(self.git("status", "--porcelain"), "")


class BuildCleanupTests(unittest.TestCase):
    def test_publish_cleanup_removes_owned_sources_and_preserves_exit_status(self):
        script = Path(__file__).with_name("build_ghostty_xcframework.sh").read_text()
        functions = []
        for name in ("cleanup_ghostty_source", "cleanup_staging"):
            match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", script, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match)
            functions.append(match.group())
        for status in (0, 7):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, staging, unrelated = (root / name for name in ("source", "staging", "unrelated"))
                for path in (source, staging, unrelated):
                    path.mkdir()
                result = subprocess.run(
                    ["bash", "-c", "\n".join(functions) + f"\ntrap cleanup_staging EXIT\nexit {status}\n"],
                    env=dict(os.environ, GHOSTTY_SOURCE_SCRATCH=str(source), STAGING_DIR=str(staging), ARTIFACT_DIR=str(root)),
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, status)
                self.assertFalse(staging.exists())
                self.assertFalse(source.exists())
                self.assertTrue(unrelated.exists())


if __name__ == "__main__":
    unittest.main()
