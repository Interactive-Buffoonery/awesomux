#!/usr/bin/env python3
"""Focused production-method proof, not app/UI E2E.

Run from a Mac with an authorized SSH alias. Compiles the
production lexical path methods, profile/socket seam, and snapshot SSH command
methods into a temporary Swift harness. Explicit zsh coverage runs when zsh
is available; its absence is recorded as a skip. Fixture cleanup removes only
the generated README and empty directory. No keys or SSH configuration change.
"""
import argparse
import json
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import shlex
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=45, **kwargs)


def method(source, name):
    match = re.search(r"    (?:private )?static func " + name + r"\b.*?\n    }", source, re.S)
    if not match:
        raise RuntimeError("Missing production method: " + name)
    return match.group().replace("private static func", "static func")


def cleanup_fixture(host, path, multiplexing=()):
    candidate = PurePosixPath(path)
    if not candidate.is_absolute() or not re.fullmatch(r"\.?amx-markdown-proof-[A-Za-z0-9]+", candidate.name):
        raise RuntimeError("refusing cleanup of an unexpected fixture path")
    script = (
        "import os, pathlib; p = pathlib.Path(" + repr(path) + "); "
        "assert not p.is_symlink() and p.stat().st_uid == os.getuid(); "
        "(p / 'README.md').unlink(missing_ok=True); p.rmdir()"
    )
    result = run(["ssh"] + list(multiplexing) + ["-o", "BatchMode=yes", "--", host,
        "python3 -c " + shlex.quote(script)])
    if result.returncode:
        raise RuntimeError("fixture cleanup failed: " + result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--remote-temp-directory", help="override TMPDIR for this proof only")
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
    report["sourceRevision"] = run(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).stdout.strip()
    report["sourceSHA256"] = {
        name: hashlib.sha256((services / name).read_bytes()).hexdigest()
        for name in ["AmxBackend.swift", "RemoteMarkdownSnapshotFetcher.swift", "RemoteMarkdownPath.swift", "AppRuntimeProfile.swift"]
    }
    remote_fixture = None
    with tempfile.TemporaryDirectory(prefix="amx-markdown-proof-") as directory:
        source = Path(directory) / "main.swift"
        executable = Path(directory) / "proof"
        source.write_text(code)
        compiled = run(["swiftc", str(source), "-o", str(executable)])
        if compiled.returncode:
            raise RuntimeError(compiled.stderr)
        temp_override = ""
        if args.remote_temp_directory:
            if not PurePosixPath(args.remote_temp_directory).is_absolute():
                parser.error("remote temp directory must be absolute")
            temp_override = "TMPDIR=" + shlex.quote(args.remote_temp_directory) + "; "
        setup = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "--", args.host,
                     temp_override + "d=$(mktemp -d \"${TMPDIR:-/tmp}/amx-markdown-proof-XXXXXX\") || exit; printf '# managed snapshot proof\\n' > \"$d/README.md\"; printf '%s' \"$d\""])
        if setup.returncode:
            raise RuntimeError("fixture setup failed: " + setup.stderr)
        remote_fixture = setup.stdout.strip()
        try:
            candidate = PurePosixPath(remote_fixture)
            if not candidate.is_absolute() or not re.fullmatch(r"amx-markdown-proof-[A-Za-z0-9]+", candidate.name):
                raise RuntimeError("unexpected fixture path from remote setup")
            report["remoteFixtureParent"] = str(candidate.parent)
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
            # The default-shell read and explicit zsh read use the same
            # production-generated command, so shell coverage is unambiguous.
            home_setup = run(["ssh"] + values["multiplexing"] + ["--", args.host,
                "d=$(mktemp -d \"$HOME/.amx-markdown-proof-XXXXXX\") || exit; printf '# home proof\\n' > \"$d/README.md\"; printf '%s' \"$d\""])
            if home_setup.returncode:
                raise RuntimeError(home_setup.stderr)
            home_directory = home_setup.stdout.strip()
            try:
                home_path = PurePosixPath(home_directory)
                if not home_path.is_absolute() or not re.fullmatch(r"\.amx-markdown-proof-[A-Za-z0-9]+", home_path.name):
                    raise RuntimeError("unexpected home fixture name from remote setup")
                home_run = run([str(executable), args.host, "~/" + home_path.name + "/README.md"])
                if home_run.returncode:
                    raise RuntimeError(home_run.stderr)
                home_values = json.loads(home_run.stdout)
                home_read = run(["ssh"] + no_auth + home_values["managed"])
                report["tildeReadExit"] = home_read.returncode
                report["tildeContentMatches"] = home_read.stdout == "# home proof\n"
                probe = run(["ssh"] + values["multiplexing"] + ["--", args.host,
                    "command -v zsh"])
                if probe.returncode == 0:
                    zsh_arguments = home_values["managed"][:-1] + [
                        "zsh -c " + shlex.quote(home_values["managed"][-1])
                    ]
                    zsh_read = run(["ssh"] + no_auth + zsh_arguments)
                    report["zshCoverage"] = "executed production read command with zsh -c"
                    report["zshReadExit"] = zsh_read.returncode
                    report["zshContentMatches"] = zsh_read.stdout == "# home proof\n"
                    version = run(["ssh"] + values["multiplexing"] + ["--", args.host, "zsh --version"])
                    if version.returncode:
                        raise RuntimeError(version.stderr)
                    report["zshVersion"] = version.stdout.strip()
                    legacy_command = home_values["managed"][-1].replace("${p#\\~/}", "${p#~/}")
                    if legacy_command == home_values["managed"][-1]:
                        raise RuntimeError("production tilde-removal pattern changed; update regression control")
                    legacy_read = run(["ssh"] + no_auth + home_values["managed"][:-1] + [
                        "zsh -c " + shlex.quote(legacy_command)
                    ])
                    report["zshLegacyReadExit"] = legacy_read.returncode
                elif probe.returncode == 1:
                    report["zshCoverage"] = "skipped: zsh is unavailable on this host"
                else:
                    raise RuntimeError("zsh availability probe failed: " + probe.stderr)
                shell = run(["ssh"] + values["multiplexing"] + ["--", args.host, 'printf "%s" "$SHELL"'])
                report["defaultShell"] = shell.stdout.strip() if shell.returncode == 0 else "unknown"
            finally:
                cleanup_fixture(args.host, home_directory, values["multiplexing"])
            report["passed"] = (
                fresh.returncode != 0 and reused.returncode == 0
                and report["managedContentMatches"] and report["tildeContentMatches"]
                and report.get("zshReadExit", 0) == 0
                and report.get("zshContentMatches", True)
                and report.get("zshLegacyReadExit", 20) == 20
            )
        finally:
            cleanup_fixture(args.host, remote_fixture)
    report["fixtureCleanupCompleted"] = True
    path = ROOT / args.report
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")
    print(path)
    if not report["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
