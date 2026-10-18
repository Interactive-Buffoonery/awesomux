#!/usr/bin/env python3
"""Local launched-app menu gate. Run the whole command under the native lease."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def validate_baseline(baseline):
    if not isinstance(baseline, dict):
        raise ValueError('baseline must be an object')
    if not isinstance(baseline.get('operatingSystem'), str):
        raise ValueError('baseline.operatingSystem must be a string')
    if baseline.get('source') != 'NSApp.mainMenu':
        raise ValueError('baseline.source must be NSApp.mainMenu')

    def items(value, location):
        if not isinstance(value, list):
            raise ValueError(f'{location} must be an array')
        for index, item in enumerate(value):
            path = f'{location}[{index}]'
            if not isinstance(item, dict):
                raise ValueError(f'{path} must be an object')
            for key, expected in (('title', str), ('separator', bool), ('enabled', bool),
                                  ('hidden', bool), ('keyEquivalent', str),
                                  ('modifiers', int), ('state', int)):
                # bool subclasses int in Python; Swift encodes distinct field types.
                if type(item.get(key)) is not expected:
                    raise ValueError(f'{path}.{key} must be {expected.__name__}')
            if item['modifiers'] < 0:
                raise ValueError(f'{path}.modifiers must be unsigned')
            items(item.get('children'), f'{path}.children')

    items(baseline.get('items'), 'baseline.items')


def stop_owned_group(process, record, save_report):
    if process is None or record.get('status') == 'exhausted':
        return
    group = process.pid  # Allocated by this Popen's start_new_session=True.
    record.update(processID=process.pid, processGroupID=group, status='stopping')
    save_report()

    def group_exists():
        process.poll()  # Reap the direct child, even if descendants outlive it.
        try:
            os.killpg(group, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            # macOS can report EPERM for a group containing only exit zombies.
            # Treat it as present until poll/reaping yields ESRCH.
            return True

    def send(sig):
        try:
            os.killpg(group, sig)
            record['lastSignal'] = sig
        except ProcessLookupError:
            pass
        except PermissionError:
            # An exit zombie may race the probe; still verify group exhaustion.
            pass
        except OSError as error:
            # Keep the lease and paths until exhaustion, even if signaling fails.
            record['signalError'] = str(error)
        save_report()

    if group_exists():
        send(signal.SIGTERM)
        deadline = time.monotonic() + 5
        while group_exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if group_exists():
            send(signal.SIGKILL)
        # A leader's exit is not group exhaustion. Never release the lease early.
        while group_exists():
            time.sleep(0.05)
    process.wait()
    record.update(status='exhausted', exitCode=process.returncode)
    save_report()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True,
                        help='new artifact directory, outside the checkout')
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument('--baseline', type=Path, help='reviewed observed baseline.json')
    choice.add_argument('--capture', action='store_true', help='capture only; no regression verdict')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.is_relative_to(ROOT) or output.exists():
        parser.error('--output must be a new directory outside the checkout')
    baseline = None
    if not args.capture:
        try:
            baseline = json.loads(args.baseline.read_text())
            validate_baseline(baseline)
        except (OSError, ValueError, RecursionError) as error:
            parser.error(f'invalid --baseline: {error}')
    output.mkdir(parents=True)
    report = {'status': 'failed', 'coverage': 'empty-profile launch menu only',
              'gaps': ['no command invocation or physical keyboard routing',
                       'no workspace, sheet, floating-panel or Companion state transitions',
                       'no rendered UI or VoiceOver verification']}
    staging = None
    process = None
    interrupted_signal = None
    report['staging'] = {'status': 'not-started'}
    report['app'] = {'status': 'not-started'}

    def interrupted(signum, _frame):
        nonlocal interrupted_signal
        # Unwind only after Popen ownership is retained; repeated signals cannot
        # interrupt group cleanup or path cleanup.
        if interrupted_signal is None:
            interrupted_signal = signum

    def check_interrupted():
        if interrupted_signal is not None:
            raise KeyboardInterrupt(f'signal {interrupted_signal}')

    def save_report():
        try:
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        except OSError as error:
            # Artifact I/O must not abandon children or release their lease.
            report['artifactError'] = str(error)


    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    profile_paths = []
    bundle_id = None
    bundle = output / 'stage' / 'awesoMux.app'
    try:
        report.update(sourceCommit=run('git', 'rev-parse', 'HEAD', cwd=ROOT,
                                       capture_output=True, text=True).stdout.strip(),
                      sourceDirty=bool(run('git', 'status', '--porcelain', cwd=ROOT,
                                            capture_output=True, text=True).stdout))
        check_interrupted()
        with (output / 'build.log').open('w') as log:
            staging = subprocess.Popen([str(ROOT / 'script/build_and_run.sh'),
                                        '--stage-menu-e2e', str(bundle.parent)],
                                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            report['staging'].update(processID=staging.pid, processGroupID=staging.pid,
                                     status='running')
            save_report()
            while staging.poll() is None:
                check_interrupted()
                time.sleep(0.1)
            check_interrupted()
            if staging.returncode != 0:
                raise subprocess.CalledProcessError(staging.returncode, staging.args)
            stop_owned_group(staging, report['staging'], save_report)
        check_interrupted()
        import plistlib
        with (bundle / 'Contents/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        bundle_id = info['CFBundleIdentifier']
        identity = bundle_id.removeprefix('com.interactivebuffoonery.awesomux.dev.')
        if len(identity) != 12 or any(c not in '0123456789abcdef' for c in identity):
            bundle_id = None
            raise RuntimeError('staged host does not have an isolated development identity')
        profile_paths = [Path.home() / 'Library/Application Support' / f'awesoMux-dev-{identity}',
                         Path.home() / '.config' / f'awesomux-dev-{identity}']
        # Never move aside an existing profile, even if an unlikely UUID collision occurs.
        if any(path.exists() for path in profile_paths):
            profile_paths = []
            bundle_id = None
            raise RuntimeError('fresh profile already exists; refusing launch')
        domain = subprocess.run(['defaults', 'read', bundle_id], capture_output=True)
        if domain.returncode == 0:
            profile_paths = []
            bundle_id = None
            raise RuntimeError('fresh defaults domain already exists; refusing launch')
        binary = bundle / 'Contents/MacOS/awesoMux'
        report.update(bundleID=bundle_id, executable=str(binary),
                      executableSHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
        check_interrupted()
        with (output / 'app.log').open('w') as log:
            process = subprocess.Popen([str(binary), '--menu-e2e-output', str(output / 'menu.json')],
                                       stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            report['processID'] = process.pid
            report['app'].update(processID=process.pid, processGroupID=process.pid,
                                 status='running')
            save_report()
            check_interrupted()
            deadline = time.monotonic() + 25
            while not (output / 'menu.json').exists():
                check_interrupted()
                if process.poll() is not None:
                    raise RuntimeError(f'host exited before capture: {process.returncode}')
                if time.monotonic() >= deadline:
                    raise RuntimeError('no stable NSApp.mainMenu capture; see app.log (debug host required)')
                time.sleep(0.1)
            check_interrupted()
            snapshot = json.loads((output / 'menu.json').read_text())
        if snapshot['processID'] != process.pid or snapshot['bundleID'] != bundle_id:
            raise RuntimeError('capture identity does not match the launched child')
        if snapshot['source'] != 'NSApp.mainMenu':
            raise RuntimeError('capture did not originate in NSApp.mainMenu')
        observed = {key: snapshot[key] for key in ('operatingSystem', 'source', 'items')}
        validate_baseline(observed)
        encoded = json.dumps(observed, indent=2, ensure_ascii=False) + '\n'
        (output / 'baseline.json').write_text(encoded)
        if args.capture:
            report['status'] = 'capture-only'
        elif baseline != observed:
            expected = json.dumps(baseline, indent=2, ensure_ascii=False) + '\n'
            (output / 'menu.diff').write_text(''.join(difflib.unified_diff(
                expected.splitlines(True), encoded.splitlines(True),
                fromfile=str(args.baseline), tofile='observed baseline.json')))
            raise RuntimeError('menu baseline differs; inspect menu.diff and menu.json')
        else:
            report['status'] = 'passed'
    except KeyboardInterrupt as error:
        report['status'] = 'failed'
        report['error'] = str(error)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        report['error'] = str(error)
    finally:
        verdict = report['status']
        report['status'] = 'cleaning-up'
        stop_owned_group(staging, report['staging'], save_report)
        stop_owned_group(process, report['app'], save_report)
        if process is not None:
            report['childExitCode'] = process.returncode
        if any(record.get('signalError') for record in (report['staging'], report['app'])):
            report['status'] = 'failed'
            report['cleanupError'] = 'owned group signaling failed; see lifecycle records'
        try:
            # Fresh, run-owned paths only. Keep logs/snapshots and discard the large bundle.
            for path in [*profile_paths, bundle.parent]:
                if path.exists():
                    run('trash', str(path))
            if bundle_id:
                subprocess.run(['defaults', 'delete', bundle_id], capture_output=True)
            report['cleanup'] = 'owned groups exhausted or not started; run-owned bundle/profile removed'
        except (OSError, subprocess.CalledProcessError) as error:
            report['status'] = 'failed'
            report['cleanupError'] = str(error)
        if report.get('artifactError') or report.get('cleanupError'):
            report['status'] = 'failed'
        else:
            report['status'] = verdict
        if interrupted_signal is not None:
            report['status'] = 'failed'
            report['interruptedSignal'] = interrupted_signal
            report.setdefault('error', f'signal {interrupted_signal}')
        save_report()
    if report.get('artifactError'):
        report['status'] = 'failed'
    print(f"{report['status']}: {output / 'report.json'}")
    return 130 if interrupted_signal else (1 if report['status'] == 'failed' else 0)


if __name__ == '__main__':
    sys.exit(main())
