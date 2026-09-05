#!/usr/bin/env python3
"""Build the awesoMux extension in a generated clone, preserving vendor/ghostty."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
INPUTS = (
    Path(__file__),
    ROOT / "native/ghostty/scrollback.zig",
    ROOT / "native/ghostty/embedded-scrollback.zig.inc",
    ROOT / "Sources/GhosttyKit/AwesoMuxGhostty.h",
)


def fingerprint():
    digest = hashlib.sha256()
    for path in INPUTS:
        digest.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def prepare(vendor, destination):
    sha = subprocess.check_output(["git", "-C", str(vendor), "rev-parse", "HEAD"], text=True).strip()
    identity = sha + "-" + fingerprint()
    target = destination / identity
    if (target / ".awesomux-extension").is_file():
        return target
    destination.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=destination))
    try:
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(vendor), str(staging)], check=True)
        subprocess.run(["git", "-C", str(staging), "checkout", "--quiet", "--detach", sha], check=True)
        embedded = staging / "src/apprt/embedded.zig"
        source = embedded.read_text()
        marker = "pub const CAPI = struct {\n"
        if source.count(marker) != 1:
            raise RuntimeError("Ghostty CAPI changed; review the scrollback extension before building")
        source = source.replace(marker, marker + INPUTS[2].read_text(), 1)
        embedded.write_text(source)
        shutil.copyfile(INPUTS[1], staging / "src/terminal/awesomux_scrollback.zig")
        terminal = staging / "src/terminal/main.zig"
        with terminal.open("a") as file:
            file.write('\n// awesoMux native safety regression tests.\ntest { _ = @import("awesomux_scrollback.zig"); }\n')
        (staging / ".awesomux-extension").write_text(fingerprint() + "\n")
        staging.rename(target)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fingerprint", action="store_true")
    parser.add_argument("--vendor", type=Path, default=ROOT / "vendor/ghostty")
    parser.add_argument("--destination", type=Path, default=ROOT / ".build/ghostty-sources")
    args = parser.parse_args()
    print(fingerprint() if args.fingerprint else prepare(args.vendor, args.destination))
