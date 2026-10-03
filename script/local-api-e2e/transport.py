#!/usr/bin/env python3
"""Exercise the actual listener; the host remains owned by the Swift E2E driver."""
import hashlib
import json
import os
import socket
import struct
import sys
import time
import uuid

profile = sys.argv[1]
path = f"/private/tmp/awesomux-api-{os.geteuid()}-{hashlib.sha256(profile.encode()).hexdigest()[:24]}/api.sock"
checks = []


def request(**changes):
    value = dict(schemaVersion=1, requestID=str(uuid.uuid4()), profile=profile, operation="list_agents")
    value.update(changes)
    return json.dumps(value).encode()


def exchange(payload=None, header=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(7)
        client.connect(path)
        client.sendall(header if header is not None else struct.pack(">I", len(payload)) + payload)
        def read(count):
            result = b""
            while len(result) < count:
                part = client.recv(count - len(result))
                assert part, "listener closed without a response"
                result += part
            return result
        length = struct.unpack(">I", read(4))[0]
        assert length <= 256 * 1024
        return json.loads(read(length))


def check(name, condition):
    assert condition, name
    checks.append(name)
    print("PASS:", name)


check("malformed JSON is explicit", exchange(b"{bad")["error"] == "invalid_request")
check("zero-length frame is explicit", exchange(header=struct.pack(">I", 0))["error"] == "invalid_request")
check("oversized request rejected before body read", exchange(header=struct.pack(">I", 8193))["error"] == "request_too_large")
check("schema mismatch is explicit", exchange(request(schemaVersion=99))["error"] == "unsupported_version")
check("profile mismatch cannot retarget", exchange(request(profile="production"))["error"] == "profile_mismatch")
check("unknown operation cannot execute", exchange(request(operation="send"))["error"] == "unsupported_operation")
check("extra command arguments are rejected", exchange(request(command="arbitrary"))["error"] == "invalid_request")
start = time.monotonic()
check("partial frame times out", exchange(header=b"\x00")["error"] == "timeout")
check("partial-frame deadline is bounded", time.monotonic() - start < 6)
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(path)
    client.sendall(struct.pack(">I", 100) + b"{")
# Cancellation releases a client slot without needing its original deadline.
time.sleep(0.1)
check("disconnect does not damage subsequent reads", exchange(request()).get("error") is None)
clients = []
try:
    for _ in range(8):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        client.sendall(b"\x00")
        clients.append(client)
    time.sleep(0.1)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as extra:
        extra.settimeout(1)
        extra.connect(path)
        check("client limit closes saturation without queued workers", extra.recv(1) == b"")
finally:
    for client in clients:
        client.close()
time.sleep(0.1)
check("listener recovers after saturation", exchange(request()).get("error") is None)
with open(sys.argv[2], "w") as output:
    json.dump(dict(checks=checks, profile=profile), output, indent=2)

# Client-side negotiation is checked against a separate same-user fixture peer.
import pathlib
import selectors
import subprocess

helper, host = sys.argv[3:5]
for change, expected in [
    (dict(profile="production"), "profile_mismatch"),
    (dict(requestID=str(uuid.uuid4())), "invalid_request"),
    (dict(schemaVersion=99), "invalid_request"),
]:
    fixture_profile = "development:" + uuid.uuid4().hex[:12]
    credential_handle = str(uuid.uuid4())
    subprocess.run(
        [helper, "credential", "store", "--profile", fixture_profile,
         "--credential-handle", credential_handle],
        input=os.urandom(32), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        check=True, timeout=7,
    )
    directory = pathlib.Path(f"/private/tmp/awesomux-api-{os.geteuid()}-{hashlib.sha256(fixture_profile.encode()).hexdigest()[:24]}")
    directory.mkdir(mode=0o700)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as fixture:
            fixture.bind(str(directory / "api.sock"))
            (directory / "api.sock").chmod(0o600)
            fixture.listen(1)
            process = subprocess.Popen(
                [helper, "--profile", fixture_profile, "--credential-handle", credential_handle, "list_agents"],
                stdout=subprocess.PIPE,
            )
            with fixture.accept()[0] as peer:
                def exact(count):
                    result = b""
                    while len(result) < count:
                        result += peer.recv(count - len(result))
                    return result
                size = struct.unpack(">I", exact(4))[0]
                incoming = json.loads(exact(size))
                response = dict(schemaVersion=1, requestID=incoming["requestID"], profile=fixture_profile,
                                appInstanceID=str(uuid.uuid4()), capturedAt="2026-10-02T00:00:00Z", agents=[])
                response.update(change)
                data = json.dumps(response).encode()
                peer.sendall(struct.pack(">I", len(data)) + data)
            output, _ = process.communicate(timeout=7)
            check(f"helper rejects peer {list(change)[0]} mismatch", json.loads(output)["error"] == expected)
    finally:
        subprocess.run(
            [helper, "credential", "delete", "--profile", fixture_profile,
             "--credential-handle", credential_handle],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=7,
        )

crash_profile = "development:" + uuid.uuid4().hex[:12]
crash_credential_handle = str(uuid.uuid4())
subprocess.run(
    [helper, "credential", "store", "--profile", crash_profile,
     "--credential-handle", crash_credential_handle],
    input=os.urandom(32), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    check=True, timeout=7,
)

def start_host():
    child = subprocess.Popen([host, "--crash-host", crash_profile], stdout=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            assert selector.select(timeout=5), "crash host failed to become ready"
            assert child.stdout.readline() == b"READY\n"
        return child
    except BaseException:
        child.kill()
        child.wait(timeout=5)
        raise

child = start_host()
child.kill()
child.wait(timeout=5)
successor = start_host()
try:
    result = subprocess.run(
        [helper, "--profile", crash_profile, "--credential-handle", crash_credential_handle, "list_agents"],
        capture_output=True, timeout=7,
    )
    check("crash successor safely replaces its exact stale socket", json.loads(result.stdout)["error"] == "access_disabled")
finally:
    successor.terminate()
    successor.wait(timeout=5)
    subprocess.run(
        [helper, "credential", "delete", "--profile", crash_profile,
         "--credential-handle", crash_credential_handle],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=7,
    )
with open(sys.argv[2], "w") as output:
    json.dump(dict(checks=checks, profile=profile), output, indent=2)
