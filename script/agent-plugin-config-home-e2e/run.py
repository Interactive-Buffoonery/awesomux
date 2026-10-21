#!/usr/bin/env python3
"""Compile the production plugin runner and drive it against the real claude CLI
with two disposable CLAUDE_CONFIG_DIR folders. Writes report.json as evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, help='Evidence directory (default: a temporary directory)')
parser.add_argument('--source-ref', help='Compile production sources from this Git revision instead of the checkout')
parser.add_argument('--expect-bugs', action='store_true', help='Pass only if the per-folder expectations fail')
parser.add_argument('--old-ref', help='Also run the downgrade scenarios against a build compiled from this older revision')
parser.add_argument('--claude', default=shutil.which('claude'), help='claude executable (default: from PATH)')
args = parser.parse_args()
if not args.claude:
    sys.exit('claude not found on PATH; pass --claude')

root = Path(__file__).resolve().parents[2]
here = root / 'script/agent-plugin-config-home-e2e'
out = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix='amx-config-home-evidence-'))
out.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='amx-config-home-build-'))
work = Path(tempfile.mkdtemp(prefix='amx-config-home-work-'))
print(f'Evidence: {out}', flush=True)

services = [
    'AgentPluginRunner', 'ProcessAgentPluginRunner+Claude', 'ProcessAgentPluginRunner+Codex',
    'ProcessAgentPluginRunner+Grok', 'ProcessAgentPluginRunner+Persistence', 'AgentPluginStatus',
    'AgentPluginDiagnostics', 'AgentPluginInstallManifest', 'AgentPluginSourceFingerprint',
    'AgentPluginTemplateRenderer', 'AgentPluginDeployedCopyInspector', 'AgentConfigHome',
    'AgentHookHelperPath', 'AgentInstallManifestStore', 'AgentIntegrationInstallStateLock',
    'CommandRunner', 'ProcessCommandRunner', 'ProcessCodexAppServerClient',
    'ProcessCodexAppServerTransport', 'CodexAppServerClient', 'CodexHookEntry', 'JSONValue', 'OneShotFlag',
]
modules = {
    'SecureFileIO': ['Sources/SecureFileIO/SecureFileReader.swift'],
    'AwesoMuxBridgeProtocol': ['Sources/AwesoMuxBridgeProtocol/AgentKind.swift',
                               'Sources/AwesoMuxBridgeProtocol/MonotonicClock.swift'],
    'AwesoMuxConfig': ['Sources/AwesoMuxConfig/AgentIntegrationsConfig.swift',
                       'Sources/AwesoMuxConfig/TOMLDefault.swift',
                       'Sources/AwesoMuxConfig/FileManager+OwnerOnly.swift'],
}
def resolve(ref):
    return subprocess.check_output(['git', 'rev-parse', ref + '^{commit}'], cwd=root, text=True).strip() if ref else None


source_ref = resolve(args.source_ref)
old_ref = resolve(args.old_ref)
compile_log = []


def compile_driver(ref, name):
    """Builds the driver against production sources at `ref` (None = checkout)
    and returns its path plus the sha256 of every compiled source."""
    target = build / name
    target.mkdir(parents=True, exist_ok=True)

    def materialize(relative):
        if not ref:
            return root / relative
        destination = target / 'revision' / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(subprocess.check_output(['git', 'show', f'{ref}:{relative}'], cwd=root))
        return destination

    hashes = {}
    for module, files in modules.items():
        paths = [materialize(f) for f in files]
        hashes.update({f: hashlib.sha256(p.read_bytes()).hexdigest() for f, p in zip(files, paths)})
        command = ['swiftc', '-swift-version', '6', '-package-name', 'awesomux', '-parse-as-library', '-emit-library', '-emit-module',
                   '-module-name', module, '-I', str(target), '-L', str(target),
                   *[f'-l{m}' for m in modules if m != module and (target / f'lib{m}.dylib').exists()],
                   *map(str, paths), '-o', str(target / f'lib{module}.dylib'),
                   '-emit-module-path', str(target / f'{module}.swiftmodule')]
        result = subprocess.run(command, capture_output=True, text=True)
        compile_log.append(f'[{name}] {module}\n' + result.stdout + result.stderr)
        if result.returncode:
            print(result.stderr, file=sys.stderr)
            sys.exit(f'{name}: module {module} failed to compile')

    app_files = [f'Sources/awesoMux/Services/{service}.swift' for service in services]
    app_paths = [materialize(f) for f in app_files]
    hashes.update({f: hashlib.sha256(p.read_bytes()).hexdigest() for f, p in zip(app_files, app_paths)})
    command = ['swiftc', '-swift-version', '6', '-package-name', 'awesomux', '-parse-as-library', '-I', str(target), '-L', str(target),
               *[f'-l{m}' for m in modules], '-Xlinker', '-rpath', '-Xlinker', str(target),
               *map(str, app_paths), *map(str, harness), '-o', str(target / 'driver')]
    result = subprocess.run(command, capture_output=True, text=True)
    compile_log.append(f'[{name}] driver\n' + result.stdout + result.stderr)
    (out / 'compile.log').write_text('\n'.join(compile_log))
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        sys.exit(f'{name}: driver failed to compile')
    return target / 'driver', hashes


harness = [here / 'Driver.swift', here / 'Shims.swift']
driver, hashes = compile_driver(source_ref, 'current')
old_driver, old_hashes = compile_driver(old_ref, 'old') if old_ref else (None, None)

run = subprocess.run([str(driver), str(work), args.claude, str(root / 'Resources')],
                     capture_output=True, text=True, timeout=600)
(out / 'driver.stderr.log').write_text(run.stderr)
steps = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
by_step = {s['step']: s for s in steps}

# What a per-folder install model must show. Each check names the step, the
# observed field, and the expected value.
expectations = [
    ('initial', 'cliInstalled', {'A': False, 'B': False}),
    ('install-A', 'cliInstalled', {'A': True, 'B': False}),
    ('install-A', 'runnerStatus', {'A': 'Enabled', 'B': 'Not installed'}),
    ('install-B', 'cliInstalled', {'A': True, 'B': True}),
    ('install-B', 'runnerStatus', {'A': 'Enabled', 'B': 'Enabled'}),
    ('install-B', 'recordedFolders', ['A', 'B']),
    ('remove-A', 'cliInstalled', {'A': False, 'B': True}),
    ('remove-A', 'runnerStatus', {'A': 'Not installed', 'B': 'Enabled'}),
    ('remove-A', 'recordedFolders', ['B']),
    ('remove-B', 'cliInstalled', {'A': False, 'B': False}),
    ('remove-B', 'recordedFolders', []),
]
checks = []
for step, field, expected in expectations:
    observed = by_step.get(step, {}).get(field)
    checks.append({'step': step, 'field': field, 'expected': expected, 'observed': observed,
                   'pass': observed == expected})

# Concurrent same-provider probes (fresh folders): legacy import while a
# sibling holds the install-state lock, then the pane's two-wide folder sweep.
concurrency_work = Path(tempfile.mkdtemp(prefix='amx-config-home-concurrency-'))
concurrency = subprocess.run([str(driver), str(concurrency_work), args.claude, str(root / 'Resources'), 'concurrency'],
                             capture_output=True, text=True, timeout=600)
(out / 'concurrency.stderr.log').write_text(concurrency.stderr)
concurrency_steps = [json.loads(line) for line in concurrency.stdout.splitlines() if line.startswith('{')]
by_concurrency_step = {s['step']: s for s in concurrency_steps}
NEEDS_REPAIR = 'Needs repair'
enabled_both = ['A=Enabled', 'B=Enabled']
concurrency_expectations = [
    ('seed', 'outcome', ['Enabled', 'Enabled']),
    ('lock-held-control', 'storeLoadState', 'busy'),
    ('lock-held-probes', 'statuses', enabled_both),
    ('lock-held-probes', 'anyBusyNote', False),
    ('lock-held-probes', 'recordCounts', [2]),
    ('lock-held-probes', 'canonicalExists', False),
    ('lock-held-mutation', 'outcome', NEEDS_REPAIR),
    ('lock-held-mutation', 'cliInstalledA', True),
    ('lock-held-mutation', 'canonicalExists', False),
    ('released-probes', 'statuses', enabled_both),
    ('released-probes', 'anyBusyNote', False),
    ('released-probes', 'recordCounts', [2]),
    ('released-probes', 'canonicalExists', True),
    ('imported', 'canonicalEqualsLegacy', True),
    ('sweep', 'completionOrder', ['A', 'B', 'C']),
    ('sweep', 'slowestFolder', 'C'),
    ('sweep', 'maxInFlight', 2),
    ('sweep', 'statuses', {'A': 'Enabled', 'B': 'Enabled', 'C': 'Not installed'}),
    ('cleanup', 'cliInstalled', {'A': False, 'B': False}),
]
for step, field, expected in concurrency_expectations:
    observed = by_concurrency_step.get(step, {}).get(field)
    checks.append({'step': f'concurrency {step}', 'field': field, 'expected': expected, 'observed': observed,
                   'pass': concurrency.returncode == 0 and observed == expected})
shutil.rmtree(concurrency_work, ignore_errors=True)

# Downgrade and migration: the current build and a build from --old-ref take
# turns on one install state. Each scenario starts from fresh folders. An old
# writer keys records by provider alone, so it must be refused once the current
# build has written per-folder records; an old v1 manifest must still import.
scenarios = {
    'downgrade': [
        ('current', 'install', 'A', {'outcome': 'Enabled', 'manifestVersion': 2, 'recordedFolders': ['A']}),
        ('current', 'install', 'B', {'outcome': 'Enabled', 'manifestVersion': 2, 'recordedFolders': ['A', 'B']}),
        ('old', 'install', 'C', {'outcome': NEEDS_REPAIR, 'manifestVersion': 2, 'recordedFolders': ['A', 'B'],
                                 'cliInstalled': {'A': True, 'B': True, 'C': False}}),
        ('old', 'uninstall', 'A', {'outcome': NEEDS_REPAIR, 'manifestVersion': 2, 'recordedFolders': ['A', 'B'],
                                   'cliInstalled': {'A': True, 'B': True, 'C': False}}),
        ('current', 'uninstall', 'A', {'manifestVersion': 2, 'recordedFolders': ['B']}),
        ('current', 'uninstall', 'B', {'manifestVersion': 2, 'recordedFolders': [],
                                       'cliInstalled': {'A': False, 'B': False, 'C': False}}),
    ],
    'migrate-append': [
        ('old', 'install', 'A', {'outcome': 'Enabled', 'manifestVersion': 1, 'recordedFolders': ['A']}),
        ('current', 'install', 'B', {'outcome': 'Enabled', 'manifestVersion': 2, 'recordedFolders': ['A', 'B']}),
        ('old', 'install', 'C', {'outcome': NEEDS_REPAIR, 'manifestVersion': 2, 'recordedFolders': ['A', 'B']}),
        ('current', 'uninstall', 'A', {'manifestVersion': 2, 'recordedFolders': ['B'],
                                       'cliInstalled': {'A': False, 'B': True, 'C': False}}),
        ('current', 'uninstall', 'B', {'manifestVersion': 2, 'recordedFolders': []}),
    ],
    'migrate-remove': [
        ('old', 'install', 'A', {'outcome': 'Enabled', 'manifestVersion': 1, 'recordedFolders': ['A']}),
        ('current', 'uninstall', 'A', {'manifestVersion': 2, 'recordedFolders': [],
                                       'cliInstalled': {'A': False, 'B': False, 'C': False}}),
        # An empty current manifest loses nothing, so the old build may rebuild it.
        ('old', 'install', 'A', {'outcome': 'Enabled', 'manifestVersion': 1, 'recordedFolders': ['A']}),
        ('old', 'uninstall', 'A', {'manifestVersion': 1, 'recordedFolders': []}),
    ],
}
downgrade_steps = []
if old_driver:
    for scenario, sequence in scenarios.items():
        scenario_work = Path(tempfile.mkdtemp(prefix=f'amx-config-home-{scenario}-'))
        for index, (build_name, op, folder, expected) in enumerate(sequence):
            binary = driver if build_name == 'current' else old_driver
            result = subprocess.run([str(binary), str(scenario_work), args.claude, str(root / 'Resources'), op, folder],
                                    capture_output=True, text=True, timeout=300)
            (out / f'{scenario}-{index}.stderr.log').write_text(result.stderr)
            observed = next((json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')), {})
            downgrade_steps.append({'scenario': scenario, 'build': build_name, 'exit': result.returncode, **observed})
            label = f'{scenario}#{index} {build_name} {op} {folder}'
            for field, value in expected.items():
                checks.append({'step': label, 'field': field, 'expected': value, 'observed': observed.get(field),
                               'pass': result.returncode == 0 and observed.get(field) == value})
        shutil.rmtree(scenario_work, ignore_errors=True)

all_pass = run.returncode == 0 and concurrency.returncode == 0 and all(c['pass'] for c in checks)

claude_version = subprocess.run([args.claude, '--version'], capture_output=True, text=True).stdout.strip()
report = {
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'source_ref': source_ref,
    'old_ref': old_ref,
    'old_source_sha256': old_hashes,
    'claude_version': claude_version,
    'swift_version': subprocess.check_output(['swift', '--version'], text=True, stderr=subprocess.STDOUT).strip(),
    'source_sha256': hashes,
    'harness_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [*harness, here / 'run.py']},
    'driver_exit': run.returncode,
    'concurrency_exit': concurrency.returncode,
    'concurrency_steps': concurrency_steps,
    'work_dir': str(work),
    'steps': steps,
    'downgrade_steps': downgrade_steps,
    'checks': checks,
    'all_pass': all_pass,
}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
for c in checks:
    print(('PASS ' if c['pass'] else 'FAIL ') + f"{c['step']} {c['field']}: expected {c['expected']} observed {c['observed']}")
print(f"all_pass={all_pass} report={out / 'report.json'}")
shutil.rmtree(work, ignore_errors=True)
if args.expect_bugs:
    sys.exit(0 if not all_pass else 1)
sys.exit(0 if all_pass else 1)
