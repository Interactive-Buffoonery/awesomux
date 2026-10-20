#!/usr/bin/env python3
"""Exercise the real bundled hook process; this fixture is not a provider/UI test."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--helper', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--include-timeout', action='store_true')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
helper = str(args.helper.resolve())
results = []


def read_line(sock):
    data = b''
    while b'\n' not in data:
        chunk = sock.recv(8192)
        if not chunk:
            return None
        data += chunk
        assert len(data) <= 8192
    return json.loads(data.split(b'\n')[0])


def identity(req):
    return {key: req[key] for key in ('target', 'providerSessionID', 'invocationID', 'revision')}


def response(req, choice):
    return {'identity': identity(req), 'state': 'delivering', 'choice': choice, 'source': 'Mac'}


def atomic(path, value):
    temporary = path.with_name('.' + str(uuid.uuid4()))
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    os.link(temporary, path)
    temporary.unlink()


def run_case(name, choice='allow', fallback=False, drop=False, broken=False, timeout=False):
    with tempfile.TemporaryDirectory(prefix='amx-perm-', dir='/private/tmp') as temp:
        directory = Path(temp)
        target = {key: str(uuid.uuid4()).upper() for key in ('runtimeID', 'workspaceID', 'paneID', 'version')}
        server = socket.socket(socket.AF_UNIX)
        server.settimeout(5)
        server.bind(str(directory / 'bridge.sock'))
        server.listen(2)
        endpoint = {'target': target, 'directory': str(directory)}
        if not fallback:
            endpoint['socket'] = str(directory / 'bridge.sock')
        atomic(directory / 'endpoint.json', endpoint)
        (directory / 'events.jsonl').touch(mode=0o600)
        env = dict(os.environ, AWESOMUX_AGENT_EVENT_FILE=str(directory / 'events.jsonl'),
                   AWESOMUX_LOCAL_PERMISSION=str(directory / 'endpoint.json'))
        payload = {'hook_event_name': 'PermissionRequest', 'session_id': 'fixture-session',
                   'tool_name': 'Bash', 'tool_input': {'command': 'echo fixture', 'content': 'SECRET-CONTENT'},
                   'tool_response': 'SECRET-RESPONSE'}
        pipe_read = pipe_write = None
        if broken:
            pipe_read, pipe_write = os.pipe()
            os.close(pipe_read)
        process = subprocess.Popen([helper, '--provider', 'claude-code'], stdin=subprocess.PIPE,
                                   stdout=pipe_write if broken else subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if pipe_write is not None:
            os.close(pipe_write)
        process.stdin.write(json.dumps(payload).encode()); process.stdin.close()
        connection = None
        ack = None
        original = None
        try:
            if not fallback:
                connection, _ = server.accept(); connection.settimeout(5)
                original = read_line(connection)
                assert original and original['helperPID'] == process.pid
                assert original['helperStartMicroseconds'] > 0
                if drop:
                    connection.close(); connection = None
            if fallback or drop:
                deadline = time.monotonic() + 5
                requests = []
                while time.monotonic() < deadline:
                    requests = list(directory.glob('req-*.json'))
                    if requests: break
                    time.sleep(.02)
                assert len(requests) == 1
                req = json.loads(requests[0].read_text())
                if original:
                    assert req == original, 'fallback must retain the exact invocation and deadline'
                if not timeout:
                    atomic(directory / ('dec-' + req['invocationID'] + '.json'), response(req, choice))
            else:
                req = original
                wire = (json.dumps(response(req, choice)) + '\n').encode()
                # Force split reply framing: one read is not one complete message.
                connection.sendall(wire[:13]); time.sleep(.02); connection.sendall(wire[13:])
                ack = read_line(connection)
            status = process.wait(timeout=125 if timeout else 5)
            stdout = b'' if broken else process.stdout.read()
            stderr = process.stderr.read()
            assert status == 0 and not stderr
            expected = b'' if broken or timeout else (json.dumps({'hookSpecificOutput': {
                'hookEventName': 'PermissionRequest', 'decision': {'behavior': choice}}}, separators=(',', ':')) + '\n').encode()
            assert stdout == expected, (stdout, expected)
            if fallback or drop:
                acks = list(directory.glob('ack-*.json'))
                assert len(acks) == (0 if broken or timeout else 1)
                if acks: assert json.loads(acks[0].read_text()) == identity(req)
                assert not list(directory.glob('req-*.json')), 'helper exit must withdraw its request'
            else:
                assert ack == (None if broken else identity(req)), 'ACK needs complete successful stdout'
            events = (directory / 'events.jsonl').read_text()
            assert 'SECRET-' not in events and 'echo fixture' not in events
            assert 'SECRET-' not in json.dumps(req)
            assert 'toolUseID' not in req, 'fixture deliberately omits native tool ID'
            results.append({'case': name, 'result': 'passed'})
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=5)
            if connection: connection.close()
            server.close()


try:
    run_case('bridge allow')
    run_case('bridge deny', choice='deny')
    run_case('file fallback allow', fallback=True)
    run_case('file fallback deny', fallback=True, choice='deny')
    run_case('dropped bridge reply retains invocation', drop=True)
    run_case('bridge stdout failure has no ACK', broken=True)
    run_case('file stdout failure has no ACK', fallback=True, broken=True)
    if args.include_timeout:
        run_case('file helper timeout outputs nothing', fallback=True, timeout=True)
finally:
    (args.output / 'result.json').write_text(json.dumps({'cases': results, 'count': len(results)}, indent=2) + '\n')
print(f'{len(results)} local permission helper cases passed')
