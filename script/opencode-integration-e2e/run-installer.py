#!/usr/bin/env python3
"""Exercise the production OpenCode/Pi installer in a disposable config home."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="amx-opencode-installer-evidence-"))
out.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix="amx-opencode-installer-build-"))
fixture = Path(tempfile.mkdtemp(prefix="amx-opencode-installer-fixture-"))
commands = [
    ["swiftc", "-swift-version", "6", "-package-name", "awesomux", "-parse-as-library", "-emit-library", "-emit-module",
     "-module-name", "AwesoMuxConfig",
     *[str(root / "Sources/AwesoMuxConfig" / name) for name in
       ["AgentIntegrationsConfig.swift", "TOMLDefault.swift", "FileManager+OwnerOnly.swift"]],
     "-o", str(build / "libAwesoMuxConfig.dylib"), "-emit-module-path", str(build / "AwesoMuxConfig.swiftmodule")],
    ["swiftc", "-swift-version", "6", "-package-name", "awesomux", "-parse-as-library", "-I", str(build), "-L", str(build),
     "-lAwesoMuxConfig", "-Xlinker", "-rpath", "-Xlinker", str(build),
     *[str(root / "Sources/awesoMux/Services" / name) for name in
       ["AgentIntegrationInstaller.swift", "AgentInstallManifestStore.swift", "AgentIntegrationInstallStateLock.swift"]],
     str(root / "script/opencode-integration-e2e/InstallerDriver.swift"), "-o", str(build / "driver")],
    [str(build / "driver"), str(fixture), str(root / "Resources")],
]
logs = []
for command in commands:
    result = subprocess.run(command, capture_output=True, text=True)
    logs.append(result.stdout + result.stderr)
    (out / "installer.log").write_text("\n".join(logs))
    if result.returncode:
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
print(logs[-1].strip())
print(f"Evidence: {out}")
