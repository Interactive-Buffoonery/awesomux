#!/usr/bin/env python3
"""Verify guarded Codex shared-server hook attribution with real TUIs and the real hook helper.

Each scenario gets a fresh CODEX_HOME and HOME, a local mock Responses server,
and two Codex TUIs in separate PTYs that stand in for awesoMux panes A and B.
Each TUI carries its own AWESOMUX_AGENT_EVENT_FILE, as awesoMux exports per
pane. The repository's Codex hooks.json is trusted through the TUI's own
startup review. AWESOMUX_AGENT_HOOK points at a wrapper that records each hook
invocation, then hands the payload to the awesoMuxAgentHook built from this
checkout. Prompts carry distinct text so each thread is tied to the TUI that
submitted it. The report compares hook invocations with what each pane file
received. Exit status is nonzero unless every scenario matches its expectation.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
HOOKS_JSON = ROOT / 'Resources/AgentIntegrations/codex/plugins/awesomux-codex-status/hooks/hooks.json'
SCENARIOS = ['shared-daemon', 'no-daemon', 'founder-closed']
ENV_ALLOWLIST = ['PATH', 'LANG', 'LC_ALL', 'LC_CTYPE', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR']

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, help='Evidence directory (default: a new temporary directory)')
parser.add_argument('--codex', help='Codex executable (default: codex on PATH)')
parser.add_argument('--scenarios', nargs='+', choices=SCENARIOS, default=SCENARIOS)
args = parser.parse_args()


def resolve_codex():
    candidate = args.codex or subprocess.run(['/usr/bin/which', 'codex'], capture_output=True, text=True).stdout.strip()
    if not candidate:
        sys.exit('codex not found on PATH')
    return str(Path(candidate).resolve())


CODEX = resolve_codex()
out = (args.output or Path(tempfile.mkdtemp(prefix='codex-shared-server-evidence-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
run_dir = Path(tempfile.mkdtemp(prefix='run-', dir=out))
print(f'Evidence: {run_dir}', flush=True)


class MockResponses(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    requests = 0
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def _send(self, code, content_type, body):
        self.send_response(code)
        self.send_header('content-type', content_type)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, 'application/json', b'{"models":[],"data":[],"object":"list"}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length') or 0))
        if not self.path.endswith('/responses'):
            return self._send(404, 'application/json', b'{}')
        with MockResponses.lock:
            MockResponses.requests += 1
        rid, mid = 'resp_' + uuid.uuid4().hex, 'msg_' + uuid.uuid4().hex
        events = [
            ('response.created', {'type': 'response.created', 'response': {'id': rid}}),
            ('response.output_item.done', {'type': 'response.output_item.done', 'output_index': 0, 'item': {
                'type': 'message', 'role': 'assistant', 'id': mid,
                'content': [{'type': 'output_text', 'text': 'mock reply'}]}}),
            ('response.completed', {'type': 'response.completed', 'response': {'id': rid, 'usage': {
                'input_tokens': 1, 'input_tokens_details': None, 'output_tokens': 1,
                'output_tokens_details': None, 'total_tokens': 2}}}),
        ]
        self._send(200, 'text/event-stream', ''.join(f'event: {e}\ndata: {json.dumps(d)}\n\n' for e, d in events).encode())


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def base_env(home, codex_home):
    env = {k: os.environ[k] for k in ENV_ALLOWLIST if k in os.environ}
    env.update({'HOME': str(home), 'CODEX_HOME': str(codex_home), 'TERM': 'xterm-256color'})
    return env


CLIENTS = []


class Client:
    def __init__(self, name, env, work, extra_args):
        self.name, self.out, self.fd = name, b'', None
        self.pid, fd = pty.fork()
        if self.pid == 0:
            try:
                os.chdir(work)
                os.execve(CODEX, [CODEX, *extra_args], env)
            except BaseException as error:
                os.write(2, f'exec failed: {error}\n'.encode())
            finally:
                os._exit(127)
        self.fd = fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
        CLIENTS.append(self)

    def write(self, text):
        for ch in text:
            os.write(self.fd, ch.encode())
            pump(0.02)

    def stop(self, evidence_dir):
        # pty.fork makes the child a session and process-group leader, so the
        # group signal also reaches any launcher descendants.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.pid, sig)
            except (ProcessLookupError, PermissionError):
                # macOS reports EPERM once only the unreaped leader remains.
                break
            pump(0.5)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        (evidence_dir / f'screen-{self.name}.bin').write_bytes(self.out)
        CLIENTS.remove(self)


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        live = [c for c in CLIENTS if c.fd is not None]
        if not live:
            time.sleep(min(0.1, max(0, end - time.time())))
            continue
        ready, _, _ = select.select([c.fd for c in live], [], [], 0.1)
        for c in live:
            if c.fd in ready:
                try:
                    data = os.read(c.fd, 65536)
                except OSError:
                    os.close(c.fd)
                    c.fd = None
                    continue
                c.out += data
                if b'\x1b[6n' in data:
                    os.write(c.fd, b'\x1b[1;1R')


def wait_for(predicate, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return True
        pump(0.2)
    return predicate()


def read_jsonl(path):
    if not path.exists():
        return None
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def owned_processes(codex_home):
    """Processes running the scenario's installed Codex daemon binary, plus their descendants.

    Ownership is decided by the executable path, which Codex installs under
    CODEX_HOME/packages, never by free-text matches against command lines.
    """
    # check=True: a failed scan must surface as an error, never as "no processes".
    ps = subprocess.run(['ps', '-axo', 'pid=,ppid=,args='], capture_output=True, text=True, check=True).stdout
    table = {}
    for line in ps.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2])
    prefix = str(codex_home) + '/'
    # argv[0] leads args; match the prefix on the whole string because the
    # path itself can contain spaces.
    owned = {pid for pid, (_, cmd) in table.items() if cmd.startswith(prefix)}
    grew = True
    while grew:
        children = {pid for pid, (ppid, _) in table.items() if ppid in owned and pid not in owned}
        owned |= children
        grew = bool(children)
    return {pid: table[pid][1][:200] for pid in sorted(owned)}


def write_wrapper(path, helper, log):
    # Records each invocation independently of whether the pane file exists,
    # then forwards the untouched payload to the production helper.
    path.write_text(f'''#!/bin/bash
payload="$(cat)"
{shlex.quote(sys.executable)} -I -c '
import json, os, sys, time
d = json.loads(sys.argv[1])
rec = {{"t": time.time(), "envPane": os.environ.get("AWESOMUX_PANE_ID"), "event": d.get("hook_event_name"),
       "thread": d.get("session_id"), "prompt": d.get("prompt")}}
open(sys.argv[2], "a").write(json.dumps(rec) + "\\n")' "$payload" {shlex.quote(str(log))}
printf '%s' "$payload" | {shlex.quote(str(helper))} "$@"
status=$?
printf '%s\n' "$status" >> {shlex.quote(str(log))}.exit
exit "$status"
''')
    path.chmod(0o700)


def run(scenario, helper, port):
    base = run_dir / scenario
    home, codex_home, work, panes = base / 'home', base / 'codex-home', base / 'work', base / 'panes'
    for d in (home, codex_home, work, panes):
        d.mkdir(parents=True)
    (codex_home / 'hooks.json').write_bytes(HOOKS_JSON.read_bytes())
    (codex_home / 'config.toml').write_text(f'''model = "mock-model"
model_provider = "mock"

[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false

[features]
hooks = true

[projects."{os.path.realpath(work)}"]
trust_level = "trusted"
''')
    invocations = base / 'hook-invocations.jsonl'
    wrapper = base / 'hook-wrapper.sh'
    write_wrapper(wrapper, helper, invocations)
    files = {n: panes / f'{n}.jsonl' for n in ('A', 'B')}
    for f in files.values():
        f.touch(mode=0o600)
    env = base_env(home, codex_home)
    pane_env = lambda name: {**env, 'AWESOMUX_AGENT_EVENT_FILE': str(files[name]),
                             'AWESOMUX_AGENT_HOOK': str(wrapper), 'AWESOMUX_PANE_ID': name}
    extra = ['--no-daemon'] if scenario == 'no-daemon' else []
    started_requests = MockResponses.requests
    result = {'scenario': scenario, 'clientArgs': extra, 'cleanupErrors': []}

    def submit(client, prompt):
        client.write(prompt)
        client.write('\r')
        return wait_for(lambda: turn_completed(read_jsonl(invocations) or [], prompt), 15)

    def cleanup_step(name, step):
        try:
            step()
        except Exception as error:
            result['cleanupErrors'].append(f'{name}: {type(error).__name__}: {error}'[:300])

    def stop_daemon():
        stop = subprocess.run([CODEX, 'app-server', 'daemon', 'stop'], env=env, capture_output=True, text=True, timeout=30)
        result['daemonStop'] = {'exit': stop.returncode, 'output': (stop.stdout + stop.stderr).strip()[:300]}

    def kill_leftovers():
        leftovers = owned_processes(codex_home)
        result['leftoverProcessesKilled'] = leftovers
        for pid in leftovers:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(0.5)
        result['survivingProcesses'] = owned_processes(codex_home)

    try:
        a = Client('A', pane_env('A'), work, extra)
        pump(4)
        a.write('2')  # Hook review: "Trust all and continue"
        a.write('\r')
        pump(2)
        result['aTurnCompleted'] = submit(a, 'prompt from A')
        b = Client('B', pane_env('B'), work, extra)
        pump(4)
        result['bTurnCompleted'] = submit(b, 'prompt from B')
        version = subprocess.run([CODEX, 'app-server', 'daemon', 'version'], env=env, capture_output=True, text=True, timeout=20)
        result['daemonVersion'] = version.stdout.strip() or version.stderr.strip()[:300]
        result['appServerProcesses'] = owned_processes(codex_home)
        if scenario == 'founder-closed':
            result['beforeFounderClosed'] = {n: read_jsonl(f) for n, f in files.items()}
            # awesoMux deletes a pane's event file when the pane closes.
            a.stop(base)
            files['A'].unlink()
            result['bSecondTurnCompleted'] = submit(b, 'second prompt from B')
        result['eventsBeforeShutdown'] = {n: read_jsonl(f) for n, f in files.items()}
    except Exception as error:
        result['scenarioError'] = f'{type(error).__name__}: {error}'[:300]
    finally:
        for c in list(CLIENTS):
            cleanup_step(f'stop client {c.name}', lambda c=c: c.stop(base))
        cleanup_step('daemon stop', stop_daemon)
        cleanup_step('kill leftovers', kill_leftovers)
        result['mockModelRequests'] = MockResponses.requests - started_requests
        result['hookInvocations'] = []

        def collect_evidence():
            result['hookInvocations'] = read_jsonl(invocations) or []
            exits = Path(f'{invocations}.exit')
            result['helperExitCodes'] = exits.read_text().split() if exits.exists() else []
            result['eventsAfterShutdown'] = {n: read_jsonl(f) for n, f in files.items()}
        cleanup_step('collect evidence', collect_evidence)
    return result


def turn_completed(calls, prompt):
    """A Stop for the prompt's thread logged after that prompt's own submit record."""
    for index, call in enumerate(calls):
        if call['event'] == 'UserPromptSubmit' and call['prompt'] == prompt:
            return any(c['event'] == 'Stop' and c['thread'] == call['thread'] for c in calls[index + 1:])
    return False


def threads_by_client(result):
    prompts = {'prompt from A': 'A', 'prompt from B': 'B', 'second prompt from B': 'B'}
    owners = {}
    for c in result['hookInvocations']:
        if c['event'] == 'UserPromptSubmit' and c['prompt'] in prompts:
            owners.setdefault(c['thread'], set()).add(prompts[c['prompt']])
    return {t: next(iter(o)) if len(o) == 1 else 'ambiguous' for t, o in owners.items()}


def turn_phases(events, thread):
    return {e.get('phase') for e in events or [] if e.get('providerSessionID') == thread}


def verdict(result):
    owners = threads_by_client(result)
    thread_a = [t for t, o in owners.items() if o == 'A']
    thread_b = [t for t, o in owners.items() if o == 'B']
    calls = result['hookInvocations']
    checks = {
        'noScenarioError': 'scenarioError' not in result,
        'noCleanupErrors': not result.get('cleanupErrors'),
        'noSurvivingProcesses': not result.get('survivingProcesses'),
        'aTurnCompleted': turn_completed(calls, 'prompt from A'),
        'bTurnCompleted': turn_completed(calls, 'prompt from B'),
        # Empty pane files only prove the guard when the helper itself succeeded.
        'helperExitedZeroEveryCall': bool(calls) and result.get('helperExitCodes') == ['0'] * len(calls),
        'oneThreadPerClient': len(thread_a) == 1 and len(thread_b) == 1 and 'ambiguous' not in owners.values(),
    }
    before = result.get('eventsBeforeShutdown') or {}
    after = result.get('eventsAfterShutdown') or {}
    turn = {'sessionStart', 'promptSubmit', 'stop'}
    only = lambda events, threads: bool(events) and all(e.get('providerSessionID') in threads for e in events)
    if checks['oneThreadPerClient']:
        ta, tb = thread_a[0], thread_b[0]
        a_events, b_events = before.get('A'), before.get('B')
        if result['scenario'] == 'no-daemon':
            checks['noAppServer'] = not result.get('appServerProcesses')
            for label, snapshot in (('BeforeShutdown', before), ('AfterShutdown', after)):
                checks['aFileHasOnlyThreadA' + label] = only(snapshot.get('A'), {ta})
                checks['bFileHasOnlyThreadB' + label] = only(snapshot.get('B'), {tb})
            checks['bothTurnsComplete'] = turn <= turn_phases(a_events, ta) and turn <= turn_phases(b_events, tb)
            expected = 'PASS: each pane file holds only its own client thread'
        elif result['scenario'] == 'shared-daemon':
            checks['appServerRunning'] = bool(result.get('appServerProcesses'))
            checks['fileAEmptyBeforeShutdown'] = a_events == []
            checks['fileAEmptyAfterShutdown'] = after.get('A') == []
            checks['fileBEmptyBeforeShutdown'] = b_events == []
            checks['fileBEmptyAfterShutdown'] = after.get('B') == []
            checks['bothThreadsHooksSawPaneA'] = all(c['envPane'] == 'A' for c in calls if c['thread'] in {ta, tb})
            expected = 'PASS: daemon-hosted hooks run for both clients; both pane files stay empty'
        else:
            baseline = result.get('beforeFounderClosed') or {}
            second = [c for c in calls if c['event'] == 'UserPromptSubmit' and c['prompt'] == 'second prompt from B']
            checks['appServerRunning'] = bool(result.get('appServerProcesses'))
            checks['baselineFilesEmpty'] = baseline.get('A') == [] and baseline.get('B') == []
            checks['bothThreadsHooksSawPaneA'] = all(c['envPane'] == 'A' for c in calls if c['thread'] in {ta, tb})
            checks['bSecondTurnCompleted'] = turn_completed(calls, 'second prompt from B')
            checks['secondTurnHookRanWithPaneA'] = bool(second) and all(c['envPane'] == 'A' for c in second)
            checks['fileARemovedBeforeShutdown'] = a_events is None
            checks['fileARemovedAfterShutdown'] = after.get('A') is None
            checks['fileBEmptyBeforeShutdown'] = b_events == []
            checks['fileBEmptyAfterShutdown'] = after.get('B') == []
            expected = "PASS: after A's pane closes, B's later hooks run; B's file stays empty and A's file stays removed"
    else:
        expected = 'INCONCLUSIVE'
    ok = all(checks.values())
    return ok, (expected if ok else 'FAIL') , checks


helper_path = None
log = run_dir / 'build-helper.log'
with log.open('w') as f:
    # The build may fetch package dependencies on a cold checkout.
    subprocess.run(['swift', 'build', '--product', 'awesoMuxAgentHook'], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, check=True)
bin_dir = subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip()
helper_path = Path(bin_dir) / 'awesoMuxAgentHook'

port = free_port()
server = ThreadingHTTPServer(('127.0.0.1', port), MockResponses)
threading.Thread(target=server.serve_forever, daemon=True).start()
report = {
    'codexPath': CODEX,
    'codexVersion': subprocess.check_output([CODEX, '--version'], text=True).strip(),
    'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    'helperSha256': hashlib.sha256(helper_path.read_bytes()).hexdigest(),
    'hooksJsonSha256': hashlib.sha256(HOOKS_JSON.read_bytes()).hexdigest(),
    'harnessSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'results': [],
}
all_ok = True
try:
    for scenario in args.scenarios:
        print(f'== {scenario}', flush=True)
        result = run(scenario, helper_path, port)
        ok, summary, checks = verdict(result)
        result.update({'verdict': summary, 'checks': checks})
        all_ok = all_ok and ok
        print(f'   {summary}', flush=True)
        if not ok:
            print(f'   failed checks: {[k for k, v in checks.items() if not v]}', flush=True)
        report['results'].append(result)
finally:
    server.shutdown()
    (run_dir / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Report: {run_dir / "report.json"}', flush=True)
sys.exit(0 if all_ok else 1)
