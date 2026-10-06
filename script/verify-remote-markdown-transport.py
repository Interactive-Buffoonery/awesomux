#!/usr/bin/env python3
"""Focused production-method proof, not app/UI E2E.

Run from a Mac with an authorized SSH alias. Compiles the
production lexical path methods, profile/socket seam, and snapshot SSH command
methods into a temporary Swift harness. No keys or SSH configuration are changed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=45, **kwargs)


def method(source, name):
    match = re.search(r"    (?:private )?static func " + name + r"\b.*?\n    }", source, re.S)
    if not match:
        raise RuntimeError("Missing production method: " + name)
    return match.group().replace("private static func", "static func")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--report", default=".build/remote-markdown/transport-proof.json")
    args = parser.parse_args()
    if args.host.startswith("-"):
        parser.error("host must be an SSH alias")
    if run(["hostname", "-s"]).stdout.strip().lower() == args.host.lower():
        parser.error("already on the target host")
    services = ROOT / "Sources/awesoMux/Services"
    backend = (services / "AmxBackend.swift").read_text()
    fetcher = (services / "RemoteMarkdownSnapshotFetcher.swift").read_text()
    control = re.search(r"    private static let cachedSSHControlDirectory: String = \{.*?\n    }\(\)", backend, re.S).group()
    constants = re.search(r"    enum RemoteReadExit \{.*?\n    }", fetcher, re.S).group()
    cap = re.search(r"static let maxFileSizeBytes[^\n]*", (ROOT / "Sources/AwesoMuxCore/Markdown/DocumentURLValidator.swift").read_text()).group()
    transport = re.search(r"enum RemoteMarkdownTransport.*?\n}", fetcher, re.S).group()
    code = "import Foundation\nimport OSLog\nimport Darwin\n"
    code += (services / "AppRuntimeProfile.swift").read_text()
    code += (ROOT / "Sources/AwesoMuxConfig/FileManager+OwnerOnly.swift").read_text()
    code += (services / "RemoteMarkdownPath.swift").read_text() + transport
    code += "\nenum AmxBackend {\n" + control
    code += '\nstatic let sshControlPathHashWidth = 40\nstatic let sshControlPathTempSuffixWidth = 17\nstatic let sockaddrUnPathLimit = 104\nstatic let logger = Logger(subsystem: "transport-proof", category: "ssh")\n'
    for name in ["sshControlDirectory", "sshControlPath", "sshMultiplexingOptions"]:
        code += "\n" + method(backend, name)
    code += "\n}\nenum DocumentURLValidator { " + cap + " }\nenum RemoteMarkdownSnapshotFetcher {\n" + constants
    for name in ["sshArguments", "remoteReadCommand", "shellSingleQuoted"]:
        code += "\n" + method(fetcher, name)
    code += "\n}\n"
    code += r'''
let cases: [(String, String?)] = [
    (NSHomeDirectory() + "/docs/../README.md", NSHomeDirectory() + "/README.md"),
    ("/a//b/./../README.md/", "/a/README.md"),
    ("/../../README.md", "/README.md"), ("/", "/"),
    ("~/a/../README.md", "~/README.md"), ("~/a/..", "~"),
    ("~/../README.md", nil), ("~other/README.md", nil),
    ("/a/README.md\n", nil), ("/a/README.md\0", nil)
]
for (input, expected) in cases { precondition(RemoteMarkdownPath.normalize(input) == expected) }
precondition(RemoteMarkdownPath.joinDocumentPath("../secret.md", toDirectory: "/repo/docs") == nil)
precondition(RemoteMarkdownPath.joinDocumentPath("nested/../guide.md", toDirectory: "~/repo/docs") == "~/repo/docs/guide.md")
precondition(RemoteMarkdownPath.resolve("../guide.md", relativeTo: "~/repo/docs") == "~/repo/guide.md")
let host = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let value: [String: Any] = [
    "lexicalChecks": cases.count + 3,
    "controlPath": AmxBackend.sshControlPath(),
    "multiplexing": AmxBackend.sshMultiplexingOptions(),
    "managed": RemoteMarkdownSnapshotFetcher.sshArguments(target: host, path: path),
    "unmanaged": RemoteMarkdownSnapshotFetcher.sshArguments(target: host, path: path, transport: .unmanaged)
]
print(String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
'''
    report = {"scope": "focused production-method proof; no app/UI E2E", "host": args.host}
    remote_fixture = None
    with tempfile.TemporaryDirectory(prefix="amx-markdown-proof-") as directory:
        source = Path(directory) / "main.swift"
        executable = Path(directory) / "proof"
        source.write_text(code)
        compiled = run(["swiftc", str(source), "-o", str(executable)])
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)
        setup = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", args.host,
                     "d=$(mktemp -d); printf '# managed snapshot proof\\n' > \"$d/README.md\"; printf '%s' \"$d\""])
        if setup.returncode:
            raise RuntimeError("fixture setup failed: " + setup.stderr)
        remote_fixture = setup.stdout.strip()
        if not re.fullmatch(r"/tmp/tmp\.[A-Za-z0-9]+", remote_fixture):
            raise RuntimeError("unexpected fixture path from remote setup")
        try:
            generated = run([str(executable), args.host, remote_fixture + "/README.md"])
            if generated.returncode:
                raise RuntimeError(generated.stderr)
            values = json.loads(generated.stdout)
            report["lexicalChecks"] = values["lexicalChecks"]
            report["profileControlPath"] = values["controlPath"]
            report["managedArguments"] = values["managed"][:-1]
            report["unmanagedArguments"] = values["unmanaged"][:-1]
            # Do not take down an existing user/app master. A master started by
            # this proof expires by its existing production ControlPersist=60.
            master = run(["ssh"] + values["multiplexing"] + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", args.host, "true"])
            if master.returncode:
                raise RuntimeError("managed master setup failed: " + master.stderr)
            no_auth = ["-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes", "-o", "IdentityFile=none", "-o", "PreferredAuthentications=none"]
            fresh = run(["ssh"] + no_auth + ["-o", "ControlPath=none", "-o", "ControlMaster=no"] + values["unmanaged"])
            reused = run(["ssh"] + no_auth + values["managed"])
            report["withoutSocketExit"] = fresh.returncode
            report["withManagedSocketExit"] = reused.returncode
            report["managedContentMatches"] = reused.stdout == "# managed snapshot proof\n"
            # Read current remote home via the already authenticated managed
            # transport; its fixture exercises production ~/ expansion in zsh.
            home_setup = run(["ssh"] + values["multiplexing"] + ["--", args.host,
                "d=$(mktemp -d \"$HOME/.amx-markdown-proof-XXXXXX\"); printf '# home proof\\n' > \"$d/README.md\"; printf '%s' \"${d##*/}\""])
            if home_setup.returncode:
                raise RuntimeError(home_setup.stderr)
            home_directory = home_setup.stdout.strip()
            if not re.fullmatch(r"\.amx-markdown-proof-[A-Za-z0-9]+", home_directory):
                raise RuntimeError("unexpected home fixture name from remote setup")
            try:
                home_values = json.loads(run([str(executable), args.host, "~/" + home_directory + "/README.md"]).stdout)
                home_read = run(["ssh"] + no_auth + home_values["managed"])
                report["tildeReadExit"] = home_read.returncode
                report["tildeContentMatches"] = home_read.stdout == "# home proof\n"
            finally:
                run(["ssh"] + values["multiplexing"] + ["--", args.host,
                    "python3 -c 'import pathlib, shutil; shutil.rmtree(pathlib.Path.home() / " + repr(home_directory).replace("'", '"') + ")'"])
            report["passed"] = fresh.returncode != 0 and reused.returncode == 0 and report["managedContentMatches"] and report["tildeContentMatches"]
        finally:
            # Delete only this proof's fixture, using Python on the remote host.
            run(["ssh", "-o", "BatchMode=yes", "--", args.host,
                 "python3 -c 'import shutil; shutil.rmtree(" + json.dumps(remote_fixture) + ")'"])
    path = ROOT / args.report
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(path)
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
