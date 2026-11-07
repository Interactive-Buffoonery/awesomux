#!/usr/bin/env python3
"""Verify V1 auto-discovers the compatibility bridge without real config or models."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencode", required=True, help="Path to an OpenCode 1.18.29 executable")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    binary = str(Path(args.opencode).resolve())
    root = (args.output or Path(tempfile.mkdtemp(prefix="awesomux-opencode-v1-live-"))).resolve()
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    version = subprocess.check_output([binary, "--version"], text=True).strip()
    if version != "1.18.29":
        parser.error(f"expected OpenCode 1.18.29, got {version}")
    package = root / "config/opencode/plugins/awesomux-opencode-status"
    package.mkdir(parents=True, exist_ok=True)
    source_hashes = {}
    for template, destination in (("status", package / "index.js"), ("tui", package / "tui.js"),
                                  ("legacy", package.parent / "awesomux-opencode-status.js")):
        source = repo / f"Resources/AgentIntegrations/open_code/awesomux-opencode-{template}.js.template"
        shutil.copyfile(source, destination)
        source_hashes[str(source.relative_to(repo))] = hashlib.sha256(source.read_bytes()).hexdigest()
    (package.parent.parent / "opencode.json").write_text(json.dumps({"autoupdate": False}))
    helper = root / "hook helper.py"
    helper.write_text("#!/usr/bin/env python3\nimport os,sys\nwith open(os.environ['AWESOMUX_AGENT_EVENT_FILE'],'a') as f:f.write(sys.stdin.read()+'\\n')\n")
    helper.chmod(0o700)
    sink = root / "events.jsonl"
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
               OPENCODE_DISABLE_DEFAULT_PLUGINS="true", OPENCODE_DISABLE_MODELS_FETCH="true",
               AWESOMUX_AGENT_EVENT_PROTOCOL="awesomux-agent-v1", AWESOMUX_AGENT_EVENT_FILE=str(sink),
               AWESOMUX_AGENT_HOOK=str(helper))
    password = secrets.token_urlsafe(32)
    env["OPENCODE_SERVER_PASSWORD"] = password
    authorization = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    report = {"version": version, "checks": [], "sourceHashes": source_hashes}
    process = None

    def request(path, body=None):
        data = None if body is None else json.dumps(body).encode()
        headers = {"Content-Type": "application/json", "Authorization": authorization,
                   "x-opencode-directory": str(root)}
        with urllib.request.urlopen(urllib.request.Request(base + path, data=data, headers=headers), timeout=5) as response:
            return json.load(response)

    def wait_for(check, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"owned server exited {process.returncode}")
            if check():
                return
            time.sleep(0.05)
        raise RuntimeError("timed out waiting for owned server or hook")

    def events():
        return [json.loads(line) for line in sink.read_text().splitlines() if line] if sink.exists() else []

    try:
        with open(root / "server.log", "wb") as log:
            process = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", str(port), "--print-logs"],
                                       cwd=root, env=env, stdout=log, stderr=log, start_new_session=True)

            def ready():
                try:
                    return request("/global/health").get("healthy") is True
                except (urllib.error.URLError, TimeoutError):
                    return False

            wait_for(ready)
            report["checks"].append("isolated V1 server started")
            session = request("/session", {"title": "awesoMux V1 compatibility fixture"})
            session_id = session["id"]
            wait_for(lambda: any(event.get("hook_event_name") == "SessionStart" for event in events()))
            # A second request gives the asynchronous event callback another
            # server operation to settle before counting its single delivery.
            assert request(f"/session/{session_id}")["id"] == session_id
            receipts = events()
            assert receipts == [{"hook_event_name": "SessionStart", "session_id": session_id}], receipts
            report["checks"].append("top-level bridge auto-discovered without explicit plugin configuration")
            report["checks"].append("synthetic session creation emits exactly one SessionStart through real V1 plugin")
            report["checks"].append("nested package is not loaded twice by V1 discovery")
            report["receipts"] = receipts
            report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
    finally:
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        report["ownedServerStopped"] = process is None or process.poll() is not None
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(f"Evidence: {root}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
