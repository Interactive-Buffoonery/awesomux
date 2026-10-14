#!/usr/bin/env python3
"""Exercise the production local API client against disposable same-user peers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import threading
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=True)
driver = args.output.resolve() / "peer-close-driver"
sources = root / "Sources/AwesoMuxLocalAPI"
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "6", "-o", str(driver),
    *[str(sources / name) for name in (
        "LocalAPIContract.swift", "LocalAPIContext.swift", "LocalAPIAttention.swift",
        "LocalAPIAuthorization.swift", "LocalAPIEndpoint.swift", "LocalAPITransport.swift",
    )], str(Path(__file__).with_name("peer-close.swift")),
], check=True)

results = []
for name in ("empty_response", "partial_header", "partial_body", "complete_response"):
    profile = "development:" + uuid.uuid4().hex[:12]
    digest = hashlib.sha256(profile.encode()).hexdigest()[:24]
    directory = Path(f"/private/tmp/awesomux-api-{os.geteuid()}-{digest}")
    directory.mkdir(mode=0o700)
    path = directory / "api.sock"
    errors = []
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.settimeout(10)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)

        def serve():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(5)

                    def read(count):
                        data = b""
                        while len(data) < count:
                            chunk = peer.recv(count - len(data))
                            if not chunk:
                                raise RuntimeError("client closed before its request")
                            data += chunk
                        return data

                    length = struct.unpack(">I", read(4))[0]
                    request = json.loads(read(length))
                    if name == "partial_header":
                        peer.sendall(b"\x00\x00")
                    elif name == "partial_body":
                        peer.sendall(struct.pack(">I", 100) + b'{"schemaVe')
                    elif name == "complete_response":
                        response = json.dumps(dict(
                            schemaVersion=1, requestID=request["requestID"], profile=profile,
                            appInstanceID=str(uuid.uuid4()), capturedAt="2026-10-14T12:00:00Z",
                        )).encode()
                        peer.sendall(struct.pack(">I", len(response)) + response)
            except Exception as error:
                errors.append(str(error))

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            actual = subprocess.run([str(driver), profile], capture_output=True, text=True,
                                    timeout=10, check=True).stdout.strip()
            thread.join(timeout=10)
            if thread.is_alive() or errors:
                raise RuntimeError(errors or "peer did not finish")
        finally:
            path.unlink(missing_ok=True)
            directory.rmdir()
    expected = "success" if name == "complete_response" else "transport_failure"
    results.append(dict(name=name, expected=expected, actual=actual, passed=actual == expected))

actual = subprocess.run([str(driver), "cancelled"], capture_output=True, text=True,
                        timeout=10, check=True).stdout.strip()
results.append(dict(name="explicit_cancellation", expected="cancelled", actual=actual,
                    passed=actual == "cancelled"))
report = dict(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              checks=results, surface="production LocalAPIClient with real Unix sockets")
(args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
for result in results:
    print(f"{'PASS' if result['passed'] else 'FAIL'}: {result['name']}: "
          f"expected={result['expected']} actual={result['actual']}")
raise SystemExit(0 if all(result["passed"] for result in results) else 1)
