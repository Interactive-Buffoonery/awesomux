#!/usr/bin/env python3
"""Compile production sources, run disposable child/pipe E2Es, retain evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--expect-bugs', action='store_true')
parser.add_argument('--cases', nargs='+', default=['close', 'timeout', 'cancel', 'echo'])
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='codex-transport-e2e-'))
services = root / 'Sources/awesoMux/Services'
names = ['ProcessCodexAppServerTransport', 'ProcessCodexAppServerClient', 'CodexAppServerClient', 'CodexHookEntry', 'JSONValue', 'OneShotFlag', 'ProcessCommandRunner', 'CommandRunner']
sources = [services / (name + '.swift') for name in names]
bridge = root / 'Sources/AwesoMuxBridgeProtocol/MonotonicClock.swift'
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
            # This group belongs exclusively to this driver and its fixture.
            os.killpg(driver.pid, signal.SIGKILL)
            driver.wait()
            code = 124
        finally:
            # Kill only the unique process group created above, never a PID from disk.
            try:
                os.killpg(driver.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    expected = (1 if mode == 'close' else 124) if args.expect_bugs and mode != 'echo' else 0
    results.append({'mode': mode, 'exit': code, 'expected': expected, 'passed': code == expected})
report = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), 'source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, 'build': str(build), 'results': results}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(results, indent=2))
sys.exit(0 if all(r['passed'] for r in results) else 1)
