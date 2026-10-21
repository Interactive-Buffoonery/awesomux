#!/usr/bin/env python3
"""Source-only checks for the generated OSC 133 status fidelity extension."""

import argparse
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("prepare", ROOT / "script/prepare_ghostty_source.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def verify(vendor):
    handler_path = "src/termio/stream_handler.zig"
    action_path = "src/apprt/action.zig"
    original_handler = (vendor / handler_path).read_text()
    original_action = (vendor / action_path).read_text()
    helper = ROOT / "native/ghostty/command-status.zig"
    cases = ROOT / "native/ghostty/command-status-tests.zig.inc"
    assert helper in prepare.INPUTS and cases in prepare.INPUTS
    assert original_handler.count(prepare.COMMAND_STATUS_ANCHOR) == 1
    with tempfile.TemporaryDirectory() as directory:
        staging = Path(directory)
        for relative in (handler_path, action_path):
            target = staging / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((vendor / relative).read_text())
        (staging / "src/terminal").mkdir()
        prepare.inject_command_status(staging)
        generated_helper = staging / "src/terminal/awesomux_command_status.zig"
        assert generated_helper.read_text() == helper.read_text()
        assert (staging / handler_path).read_text() == original_handler.replace(
            prepare.COMMAND_STATUS_ANCHOR, prepare.COMMAND_STATUS_REPLACEMENT, 1)
        assert (staging / action_path).read_text() == original_action + cases.read_text()
        for changed in (
            original_handler.replace(prepare.COMMAND_STATUS_ANCHOR, ""),
            original_handler + prepare.COMMAND_STATUS_ANCHOR,
        ):
            (staging / handler_path).write_text(changed)
            before = {path: path.read_bytes() for path in staging.rglob("*") if path.is_file()}
            try:
                prepare.inject_command_status(staging)
            except RuntimeError:
                pass
            else:
                raise AssertionError("missing or duplicated conversion anchor must fail")
            assert all(path.read_bytes() == data for path, data in before.items())
    assert (vendor / handler_path).read_text() == original_handler
    assert (vendor / action_path).read_text() == original_action
    build = (ROOT / "script/build_ghostty_xcframework.sh").read_text()
    assert "-Dtest-filter=awesomux-command-status --summary all" in build
    return {"result": "PASS", "fingerprint": prepare.fingerprint(), "nativeTestsRun": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=ROOT / "vendor/ghostty")
    args = parser.parse_args()
    print(json.dumps(verify(args.vendor), indent=2))
