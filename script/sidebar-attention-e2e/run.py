#!/usr/bin/env python3
"""Run the public-store sidebar journey; retain report.json and journey.log."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)


def source_receipt():
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=root)

    inputs = [root / "Package.swift", root / "Package.resolved", Path(__file__), Path(__file__).with_name("main.swift")]
    inputs += sorted((root / "Sources").rglob("*.swift"))
    return {
        "head": git("rev-parse", "HEAD").decode().strip(),
        "dirtyDiffSHA256": hashlib.sha256(git("diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD")).hexdigest(),
        "inputsSHA256": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in inputs if path.is_file()},
    }


source_before = source_receipt()
source_path = out / "source.json"
source_path.write_text(json.dumps({"before": source_before}, indent=2) + "\n")
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
    source_after = source_receipt()
    unchanged = source_before == source_after
    source_path.write_text(json.dumps({"before": source_before, "after": source_after,
                                      "unchanged": unchanged, "exitCode": result.returncode}, indent=2) + "\n")
    print((out / "journey.log").read_text())
    if not unchanged:
        print("FAIL: source changed during the journey; rerun in a stable checkout.")
    print(f"Artifacts: {out}")
    raise SystemExit(result.returncode if unchanged else 1)
