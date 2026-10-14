#!/usr/bin/env python3
"""Compile production sources, run disposable child/pipe E2Es, retain evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import re
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--expect-bugs', action='store_true')
parser.add_argument('--source-ref', help='Compile unchanged production sources from this Git revision')
parser.add_argument('--contracts', action='store_true', help='Run the existing, unmodified fake-transport suite in a standalone package')
parser.add_argument('--cases', nargs='+', default=['close', 'timeout', 'cancel', 'echo', 'silent', 'closed-send', 'exit', 'deinit'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='codex-transport-e2e-'))
services = root / 'Sources/awesoMux/Services'
names = ['ProcessCodexAppServerTransport', 'ProcessCodexAppServerClient', 'CodexAppServerClient', 'CodexHookEntry', 'JSONValue', 'OneShotFlag', 'ProcessCommandRunner', 'CommandRunner']
sources = [services / (name + '.swift') for name in names]
bridge = root / 'Sources/AwesoMuxBridgeProtocol/MonotonicClock.swift'
source_paths = sources + [bridge]
source_ref = subprocess.check_output(['git', 'rev-parse', args.source_ref + '^{commit}'], cwd=root, text=True).strip() if args.source_ref else None

def materialize(source):
    if not source_ref:
        return source
    destination = build / 'revision' / source.relative_to(root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(subprocess.check_output(['git', 'show', source_ref + ':' + str(source.relative_to(root))], cwd=root))
    return destination

sources = [materialize(source) for source in sources]
bridge = materialize(bridge)
commands = [
    ['swiftc', '-swift-version', '6', '-emit-library', '-emit-module', '-module-name', 'AwesoMuxBridgeProtocol', str(bridge), '-o', str(build / 'libAwesoMuxBridgeProtocol.dylib'), '-emit-module-path', str(build / 'AwesoMuxBridgeProtocol.swiftmodule')],
    ['swiftc', '-swift-version', '6', '-parse-as-library', '-I', str(build), '-L', str(build), '-lAwesoMuxBridgeProtocol', '-Xlinker', '-rpath', '-Xlinker', str(build), *map(str, sources), str(root / 'script/codex-transport-e2e/Driver.swift'), '-o', str(build / 'driver')],
]
with (out / 'build.log').open('w') as log:
    for command in commands:
        log.write(repr(command) + '\n'); log.flush()
        subprocess.run(command, check=True, stdout=log, stderr=log)
results = []
for mode in args.cases:
    home = build / ('case-' + mode)
    home.mkdir()
    command = [str(build / 'driver'), mode, sys.executable, str(root / 'script/codex-transport-e2e/fixture.py'), str(home)]
    with (out / (mode + '.log')).open('w') as log:
        driver = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
        try:
            code = driver.wait(timeout=6)
        except subprocess.TimeoutExpired:
            log.write('WATCHDOG: driver exceeded 6 seconds\n'); log.flush()
            # Popen owns/reaps the driver; the fixture has its own alarm.
            driver.kill()
            driver.wait()
            code = 124
    expected = {'close': 1, 'timeout': 124, 'cancel': 124}.get(mode, 0) if args.expect_bugs else 0
    results.append({'mode': mode, 'exit': code, 'expected': expected, 'passed': code == expected})
if args.contracts:
    package = build / 'contracts'
    app = package / 'Sources/awesoMux'
    clock = package / 'Sources/AwesoMuxBridgeProtocol'
    tests = package / 'Tests/awesoMuxTests'
    for directory in [app, clock, tests]:
        directory.mkdir(parents=True)
    for source in sources:
        shutil.copy2(source, app)
    shutil.copy2(bridge, clock)
    for name in ['CodexAppServerClientTests.swift', 'FakeCodexAppServerTransport.swift']:
        shutil.copy2(materialize(root / 'Tests/awesoMuxTests' / name), tests)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CodexTransportContracts", platforms: [.macOS(.v15)], targets: [
    .target(name: "AwesoMuxBridgeProtocol"),
    .target(name: "awesoMux", dependencies: ["AwesoMuxBridgeProtocol"]),
    .testTarget(name: "awesoMuxTests", dependencies: ["awesoMux"])
])
''')
    with (out / 'contracts.log').open('w') as log:
        result = subprocess.run(['swift', 'test', '--package-path', str(package), '--filter', 'ProcessCodexAppServerClientTests'], stdout=log, stderr=log, timeout=120)
    text = (out / 'contracts.log').read_text()
    match = re.search(r'Test run with (\d+) tests? .*passed', text)
    results.append({'mode': 'existing-contracts', 'exit': result.returncode, 'count': int(match[1]) if match else 0, 'passed': result.returncode == 0 and bool(match) and int(match[1]) > 0})
report = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), 'swift_version': subprocess.check_output(['swift', '--version'], text=True, stderr=subprocess.STDOUT).strip(), 'source_ref': source_ref, 'source_sha256': {str(original.relative_to(root)): hashlib.sha256(actual.read_bytes()).hexdigest() for original, actual in zip(source_paths, sources + [bridge])}, 'harness_sha256': {name: hashlib.sha256((root / 'script/codex-transport-e2e' / name).read_bytes()).hexdigest() for name in ['run.py', 'fixture.py', 'Driver.swift']}, 'build': str(build), 'results': results}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(results, indent=2))
sys.exit(0 if all(r['passed'] for r in results) else 1)
