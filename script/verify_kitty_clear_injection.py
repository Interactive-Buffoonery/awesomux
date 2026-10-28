#!/usr/bin/env python3
"""Check history image cleanup injection without compiling or changing vendor source."""

import argparse
import importlib.util
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("prepare", ROOT / "script/prepare_ghostty_source.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def verify(vendor):
    """Verify exact cleanup injection and reject anchor drift without vendor writes."""
    paths = ("src/terminal/Screen.zig", "src/terminal/kitty/graphics_storage.zig", "src/renderer/image.zig")
    originals = {name: (vendor / name).read_text() for name in paths}
    tests = ROOT / "native/ghostty/kitty-clear-tests.zig.inc"
    assert tests in prepare.INPUTS
    with tempfile.TemporaryDirectory() as directory:
        staging = Path(directory)
        for name, source in originals.items():
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
        prepare.inject_kitty_clear(staging)
        assert (staging / paths[0]).read_text() == originals[paths[0]].replace(
            prepare.KITTY_RESIZE_ANCHOR, prepare.KITTY_RESIZE_REPLACEMENT, 1)
        assert (staging / paths[1]).read_text() == originals[paths[1]]
        assert (staging / paths[2]).read_text() == originals[paths[2]] + tests.read_text()
        for name, anchor in ((paths[0], prepare.KITTY_CLEAR_ANCHOR),
                             (paths[0], prepare.KITTY_RESIZE_ANCHOR),
                             (paths[1], prepare.KITTY_STORAGE_ANCHOR)):
            for broken in (originals[name].replace(anchor, ""), originals[name] + anchor):
                for relative, source in originals.items():
                    (staging / relative).write_text(source)
                (staging / name).write_text(broken)
                before = {relative: (staging / relative).read_bytes() for relative in paths}
                try:
                    prepare.inject_kitty_clear(staging)
                except RuntimeError:
                    pass
                else:
                    raise AssertionError("missing or duplicated anchor must fail")
                assert all((staging / relative).read_bytes() == data for relative, data in before.items())
    assert all((vendor / name).read_text() == source for name, source in originals.items())
    assert "-Dtest-filter=awesomux-kitty-clear --summary all" in (ROOT / "script/build_ghostty_xcframework.sh").read_text()
    print("PASS: exact injection, fingerprint inputs, fail-closed anchors, unchanged vendor source")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=ROOT / "vendor/ghostty")
    verify(parser.parse_args().vendor)
