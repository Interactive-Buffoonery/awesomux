#!/usr/bin/env python3
"""Compile the production transcript reader and check an isolated OpenCode database."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-home", type=Path, required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--expect-text", required=True, help="Known fixture text; do not use private transcript content")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    output = (args.output or Path(tempfile.mkdtemp(prefix="awesomux-opencode-transcript-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources = [
        repo / "Sources/SecureFileIO/SecureFileReader.swift",
        repo / "Sources/AwesoMuxCore/Services/OpenCodeTranscriptDatabase.swift",
        repo / "Sources/AwesoMuxCore/Models/OpenCodeTranscriptSnapshot.swift",
        Path(__file__).with_name("TranscriptDriver.swift"),
    ]
    report = {"sources": {str(path.relative_to(repo)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}}
    log = output / "build.log"
    try:
        with log.open("w") as handle:
            subprocess.run(["swiftc", "-package-name", "awesomux_opencode_e2e", "-emit-library", "-emit-module", "-module-name", "SecureFileIO",
                            "-emit-module-path", str(output / "SecureFileIO.swiftmodule"),
                            "-o", str(output / "libSecureFileIO.dylib"), str(sources[0])], check=True, stdout=handle, stderr=handle)
            executable = output / "transcript-driver"
            subprocess.run(["swiftc", "-package-name", "awesomux_opencode_e2e", "-parse-as-library", "-I", str(output), "-L", str(output), "-lSecureFileIO",
                            "-Xlinker", "-rpath", "-Xlinker", str(output),
                            *map(str, sources[1:]), "-o", str(executable)], check=True, stdout=handle, stderr=handle)
        result = subprocess.run([str(executable), str(args.data_home.resolve()), args.session, args.expect_text],
                                text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(f"Production transcript driver exited {result.returncode}; expected fixture text was not verified")
        report.update(status="passed", result=json.loads(result.stdout))
    except Exception as error:
        report.update(status="failed", error=str(error))
    report["output"] = str(output)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
