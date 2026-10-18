#!/usr/bin/env python3
"""Source-only verification; never builds Ghostty or edits its vendor checkout."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("prepare", ROOT / "script/prepare_ghostty_source.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
parser = argparse.ArgumentParser()
parser.add_argument("--vendor", type=Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory() as tmp:
    scratch = Path(tmp)
    for relative, marker, fragment in prepare.REMOTE_PWD_INSERTIONS:
        original = (args.vendor / relative).read_text()
        assert original.count(marker) == 1, relative
        target = scratch / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(original)
    prepare.inject_remote_pwd(scratch)
    for relative, marker, fragment in prepare.REMOTE_PWD_INSERTIONS:
        original = (args.vendor / relative).read_text()
        added = fragment.read_text()
        generated = (scratch / relative).read_text()
        assert generated == original.replace(marker, marker + added, 1), relative
        assert fragment in prepare.INPUTS
        for changed in (original.replace(marker, ""), original + marker):
            (scratch / relative).write_text(changed)
            try:
                prepare.inject_remote_pwd(scratch)
            except RuntimeError:
                pass
            else:
                raise AssertionError("drift must fail: " + relative)
        for path, _, _ in prepare.REMOTE_PWD_INSERTIONS:
            (scratch / path).write_text((args.vendor / path).read_text())
        prepare.inject_remote_pwd(scratch)
    handler = (scratch / "src/termio/stream_handler.zig").read_text()
    assert handler.index(".awesomux_remote_pwd =") < handler.index("const host_valid =")
    callback = (ROOT / "Sources/awesoMux/Services/GhosttyRuntimeCallbacks.swift").read_text()
    assert "view.consumeRemotePwdEnvelope(workingDirectory" in callback
    assert callback.index("view.consumeRemotePwdEnvelope(workingDirectory") < callback.index("view.updateWorkingDirectory(workingDirectory)")
    assert ROOT / "native/ghostty/remote-pwd.zig" in prepare.INPUTS
    assert ROOT / "native/ghostty/remote-pwd-tests.zig.inc" in prepare.INPUTS
print(json.dumps({"result": "PASS", "fingerprint": prepare.fingerprint(), "fragments": {
    str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
    for p in prepare.INPUTS if "remote-pwd" in p.name
}}, indent=2))
