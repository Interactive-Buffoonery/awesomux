#!/usr/bin/env python3
"""Exercise the installed OpenCode V2 plugin with isolated server and PTY clients."""
import argparse
import base64
import fcntl
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import select
import secrets
import shutil
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opencode", default=shutil.which("opencode"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--part-rows", action="store_true", help="Exercise the V2 experimental split assistant storage")
    args = parser.parse_args()
    if not args.opencode:
        parser.error("opencode executable is required")
    root = (args.output or Path(tempfile.mkdtemp(prefix="awesomux-opencode-live-"))).resolve()
    root.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parents[2]
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG") if key in os.environ}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
               XDG_DATA_HOME=str(root / "data"), XDG_CACHE_HOME=str(root / "cache"),
               XDG_STATE_HOME=str(root / "state"), TERM="xterm-256color", COLORTERM="truecolor")
    password = secrets.token_urlsafe(32)
    env["OPENCODE_PASSWORD"] = password
    authorization = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
    package = root / "config/opencode/plugins/awesomux-opencode-status"
    package.mkdir(parents=True, exist_ok=True)
    for template, name in (("status", "index.js"), ("tui", "tui.js")):
        shutil.copyfile(repo / f"Resources/AgentIntegrations/open_code/awesomux-opencode-{template}.js.template", package / name)
    shutil.copyfile(repo / "Resources/AgentIntegrations/open_code/awesomux-opencode-legacy.js.template",
                    package.parent / "awesomux-opencode-status.js")
    helper = root / "hook helper.py"
    helper.write_text("#!/usr/bin/env python3\nimport os,sys\nwith open(os.environ['AWESOMUX_AGENT_EVENT_FILE'],'a') as f:f.write(sys.stdin.read()+'\\n')\n")
    helper.chmod(0o700)
    model_request = threading.Event()
    finish_model = threading.Event()
    model_paths = []

    class ModelHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            model_paths.append(self.path)
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            model_request.set()
            finish_model.wait(timeout=15)
            chunks = [
                {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "fixture success"}, "finish_reason": None}]},
                {"id": "fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture",
                 "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                 "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}},
            ]
            try:
                for chunk in chunks:
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    model_server = ThreadingHTTPServer(("127.0.0.1", 0), ModelHandler)
    model_thread = threading.Thread(target=model_server.serve_forever, daemon=True)
    model_thread.start()
    (root / "config/opencode/opencode.json").write_text(json.dumps({
        "experimental": {"part_rows": args.part_rows},
        "model": "awesomux-fixture/fixture",
        "providers": {"awesomux-fixture": {
            "package": "@opencode/ai/providers/openai-compatible",
            "env": [],
            "settings": {"baseURL": f"http://127.0.0.1:{model_server.server_port}/v1", "apiKey": "awesomux-local-fixture"},
            "models": {"fixture": {"limit": {"context": 10000, "output": 1000}}},
        }},
    }))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    processes = []
    terminals = []
    logs = []
    hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((repo / "Resources/AgentIntegrations/open_code").glob("*.template"))}
    report = {"templates": hashes, "version": subprocess.check_output([args.opencode, "--version"], text=True).strip(), "output": str(root), "checks": []}

    def request(path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(base + path, data=data, headers={"Content-Type": "application/json", "Authorization": authorization})
        try:
            with urllib.request.urlopen(req, timeout=5) as response:
                payload = response.read()
                return json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{path}: HTTP {error.code}: {error.read().decode()}") from error

    def drain():
        for fd, log in terminals:
            while select.select([fd], [], [], 0)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    break
                if not data:
                    break
                log.write(data)
                log.flush()

    def wait_for(check, description, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            drain()
            if check():
                report["checks"].append(description)
                return
            time.sleep(0.05)
        raise RuntimeError("Timed out: " + description)

    def events(sink):
        if not sink.exists():
            return []
        return [json.loads(line) for line in sink.read_text().splitlines() if line]

    try:
        log = open(root / "server.log", "wb")
        logs.append(log)
        server = subprocess.Popen([args.opencode, "serve", "--hostname", "127.0.0.1", "--port", str(port)],
                                  cwd=root, env=env, stdout=log, stderr=log, start_new_session=True)
        processes.append(server)
        def ready():
            try:
                return request("/api/info") is not None
            except Exception:
                return False
        wait_for(ready, "isolated server starts without pane environment")
        sessions = []
        sinks = []
        for index in range(2):
            info = request("/api/session", {"location": {"directory": str(root)}, "title": f"pane-{index}"})["data"]
            session_id = info["id"]
            sessions.append(session_id)
            sink = root / f"pane-{index}.jsonl"
            sinks.append(sink)
            pane_env = dict(env, AWESOMUX_AGENT_EVENT_PROTOCOL="awesomux-agent-v1",
                            AWESOMUX_AGENT_EVENT_FILE=str(sink), AWESOMUX_AGENT_HOOK=str(helper),
                            AWESOMUX_PANE_ID=f"fixture-pane-{index}")
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            log = open(root / f"tui-{index}.log", "wb")
            logs.append(log)
            proc = subprocess.Popen([args.opencode, "--server", base, "--session", session_id, str(root)],
                                    cwd=root, env=pane_env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
            os.close(slave)
            processes.append(proc)
            terminals.append((master, log))
            wait_for(lambda: any(e.get("hook_event_name") == "SessionStart" for e in events(sink)),
                     f"pane {index} emits SessionStart through real TUI plugin")
            wait_for(lambda: any(e.get("hook_event_name") == "Stop" for e in events(sink)),
                     f"pane {index} emits initial idle Stop")
        plugins = request("/api/plugin?location[directory]=" + urllib.parse.quote(str(root)))
        local_plugins = [plugin for plugin in plugins["data"] if plugin.get("source", {}).get("type") == "local"]
        (root / "plugins.json").write_text(json.dumps(local_plugins, indent=2))
        plugin = next(plugin for plugin in local_plugins if plugin["id"] == "awesomux.status")
        assert plugin["state"]["status"] == "active", "awesoMux server plugin failed to load"
        assert plugin["features"].get("tui"), "TUI part not discovered"
        assert all(plugin["state"]["status"] == "active" for plugin in local_plugins), "local plugin load error"
        report["checks"].append("real server discovers both plugin parts and legacy stub without load errors")

        child = request("/api/session", {"parentID": sessions[0], "title": "child", "permissions": [
            {"action": "awesomux-fixture", "resource": "*", "effect": "ask"}]})["data"]["id"]
        permission = request(f"/api/session/{child}/permission", {"action": "awesomux-fixture", "resources": ["fixture"]})["data"]
        assert permission["effect"] == "ask", "fixture permission was not queued"
        wait_for(lambda: any(e.get("hook_event_name") == "PermissionRequest" for e in events(sinks[0])),
                 "descendant permission reaches its selected root pane")
        request(f"/api/session/{child}/permission/{permission['id']}/reply", {"decision": "once"})
        wait_for(lambda: any(e.get("hook_event_name") == "PermissionReplied" for e in events(sinks[0])),
                 "descendant permission resolution clears root attention")
        form = request(f"/api/session/{child}/form", {"title": "Fixture question", "fields": [{"key": "answer", "type": "string"}]})["data"]
        wait_for(lambda: any(e.get("hook_event_name") == "Notification" for e in events(sinks[0])),
                 "descendant form reaches root as input-required notification")
        request(f"/api/session/{child}/form/{form['id']}/reply", {"answer": {"answer": "fixture"}})
        wait_for(lambda: sum(e.get("hook_event_name") == "PermissionReplied" for e in events(sinks[0])) >= 2,
                 "form resolution clears root attention")
        assert not any(e.get("hook_event_name") in ("PermissionRequest", "Notification") for e in events(sinks[1])), "descendant attention leaked to other pane"
        report["checks"].append("descendant attention never reaches sibling pane")

        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        log = open(root / "tui-outside-awesomux.log", "wb")
        logs.append(log)
        outside = subprocess.Popen([args.opencode, "--server", base, "--session", child, str(root)],
                                   cwd=root, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        processes.append(outside)
        terminals.append((master, log))
        wait_for(lambda: log.tell() > 0 and outside.poll() is None,
                 "TUI without awesoMux environment starts against same server")
        for index, sink in enumerate(sinks):
            assert events(sink), f"pane {index} has no events"
            assert all(e.get("session_id") == sessions[index] for e in events(sink)), "cross-pane event leakage"
        report["checks"].append("two TUI clients on one server write only their own session to their pane sink")
        before_success = len(events(sinks[0]))
        request(f"/api/session/{sessions[0]}/model", {"model": {"providerID": "awesomux-fixture", "id": "fixture"}})
        request(f"/api/session/{sessions[0]}/prompt", {"text": "local successful execution fixture"})
        wait_for(lambda: model_request.is_set(), "execution reaches only the local mock provider")
        wait_for(lambda: any(e.get("hook_event_name") == "UserPromptSubmit" for e in events(sinks[0])[before_success:]),
                 "running model execution reaches owning pane as UserPromptSubmit")
        finish_model.set()
        wait_for(lambda: any(e.get("hook_event_name") == "Stop" for e in events(sinks[0])[before_success:]),
                 "successful model execution reaches owning pane as Stop")
        assert request(f"/api/session/{sessions[0]}")["data"].get("outcome") == "succeeded", "model execution did not succeed"
        assert not any(e.get("hook_event_name") == "UserPromptSubmit" for e in events(sinks[1])), "running status leaked to sibling pane"
        report["checks"].append("successful running/completion never changes sibling pane")
        report["modelRequests"] = list(model_paths)
        database = root / "data/opencode/opencode.db"
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            inline = connection.execute("SELECT data FROM session_message WHERE session_id = ? AND type = 'assistant'", (sessions[0],)).fetchall()
            split = connection.execute("SELECT type, data FROM session_part WHERE session_id = ? ORDER BY ordinal", (sessions[0],)).fetchall()
        inline_parts = [part for (data,) in inline for part in json.loads(data).get("content", [])]
        split_parts = [json.loads(data) for _, data in split]
        assert any(part.get("text") == "fixture success" for part in inline_parts + split_parts), "successful response not durably projected"
        assert all(part["type"] == row_type for (row_type, _), part in zip(split, split_parts)), "split type column missing from JSON payload"
        if args.part_rows:
            assert split_parts, "experimental split storage did not produce part rows"
        else:
            assert inline_parts, "default V2 storage did not produce inline assistant content"
        report["database"] = {"inlineParts": len(inline_parts), "splitParts": len(split_parts)}
        report["checks"].append("actual assistant storage and part JSON types match the selected V2 storage mode")

        # A child failure is not the root's terminal outcome.
        request(f"/api/session/{child}/model", {"model": {"providerID": "awesomux-missing", "id": "fixture"}})
        request(f"/api/session/{child}/prompt", {"text": "child failure fixture"})
        wait_for(lambda: request(f"/api/session/{child}")["data"].get("outcome") == "failed",
                 "descendant execution fails without changing its root's outcome")
        assert not any(e.get("hook_event_name") == "StopFailure" for e in events(sinks[0])), "child failure changed root status"
        report["checks"].append("child failure does not report a false root StopFailure")
        # A deliberately nonexistent provider cannot contact a model or consume credentials.
        request(f"/api/session/{sessions[0]}/model", {"model": {"providerID": "awesomux-missing", "id": "fixture"}})
        request(f"/api/session/{sessions[0]}/prompt", {"text": "isolated failure fixture"})
        wait_for(lambda: any(e.get("hook_event_name") == "StopFailure" for e in events(sinks[0])),
                 "real failed execution reaches pane 0 as StopFailure")
        assert not any(e.get("hook_event_name") == "StopFailure" for e in events(sinks[1])), "failure leaked to other pane"
        report["checks"].append("pane 0 failure does not change pane 1")
        for fd, _ in terminals:
            os.write(fd, b"\x03")
        wait_for(lambda: all(any(e.get("hook_event_name") == "SessionEnd" for e in events(sink)) for sink in sinks),
                 "graceful TUI exit emits SessionEnd for both pane owners", timeout=5)
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=str(error))
    finally:
        finish_model.set()
        model_server.shutdown()
        model_server.server_close()
        model_thread.join(timeout=5)
        for proc in reversed(processes):
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
        drain()
        for fd, _ in terminals:
            os.close(fd)
        for log in logs:
            log.close()
        server_log = root / "server.log"
        if server_log.exists():
            server_log.write_text(server_log.read_text(errors="replace").replace(password, "[fixture password redacted]"))
        report["cleanup"] = "all owned process groups terminated and reaped"
        (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
