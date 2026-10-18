#!/usr/bin/env python3
"""Run the public-store sidebar journey; retain report.json and journey.log."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="sidebar-attention-e2e-") as temp:
    package = Path(temp)
    (package / "Sources" / "Journey").mkdir(parents=True)
    (package / "Sources" / "Journey" / "main.swift").write_bytes(Path(__file__).with_name("main.swift").read_bytes())
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SidebarAttentionJourney", platforms: [.macOS(.v15)], dependencies: [.package(path: %s)], targets: [.executableTarget(name: "Journey", dependencies: [.product(name: "AwesoMuxCore", package: %s)])])
''' % (json.dumps(str(root), ensure_ascii=False), json.dumps(root.name, ensure_ascii=False)))
    with (out / "journey.log").open("w") as log:
        result = subprocess.run(["swift", "run", "--package-path", str(package), "--scratch-path", str(root / ".build" / "sidebar-attention-e2e"), "Journey", str(out / "report.json")], stdout=log, stderr=subprocess.STDOUT)
    print((out / "journey.log").read_text())
    print(f"Artifacts: {out}")
    raise SystemExit(result.returncode)
