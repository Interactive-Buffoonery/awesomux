#!/usr/bin/env python3
"""Deterministic, manual native terminal lifecycle gate. No app build step."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
PRODUCTION = [
    "docs/shortcuts.md", "docs/amx-automation.md", "script/runtime-profile.sh", "script/native-ui.sh",
    "Sources/awesoMux/Views/AgentProjectTranscriptBrowser.swift",
    "Sources/AwesoMuxCore/Services/AgentProjectTranscripts.swift",
    "Sources/awesoMux/Services/AgentTranscriptPaneInputs.swift",
    "Sources/awesoMux/Services/AgentTranscriptOpener.swift",
    "Sources/awesoMux/App/AwesoMuxApp.swift",
    "Sources/awesoMux/Services/AppRuntimeProfile.swift",
    "Sources/awesoMux/Services/AmxBackend.swift",
    "Sources/awesoMux/Services/KeyboardShortcutCatalog.swift",
    "Sources/awesoMux/Services/DestructivePaneActionConfirmationPolicy.swift",
    "Sources/awesoMux/Views/TerminalSplitLayoutView.swift",
    "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceNSView.swift",
    "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceProcessExitHandler.swift",
    "Sources/awesoMux/Views/GhosttySurface/GhosttySurfaceInputBridge.swift",
    "Sources/AwesoMuxCore/Stores/SessionStore.swift",
    "Sources/AwesoMuxCore/Models/SessionSnapshot.swift",
    "Sources/AwesoMuxCore/Stores/RecentlyClosedWorkspaceReducer.swift",
    "Sources/awesoMux/App/NSAlert+KeyboardAccept.swift",
    "Sources/awesoMux/Services/GhosttyConfigManager.swift",
    "Sources/awesoMux/Services/FirstRunTourController.swift",
    "Sources/awesoMux/Services/NotificationPrimePolicy.swift",
    "Sources/awesoMux/Services/WorkspaceNotificationBridge.swift",
    "Sources/AwesoMuxConfig/NotificationConfig.swift",
    "Sources/AwesoMuxConfig/NotificationPreferences.swift",
    "Sources/AwesoMuxConfig/ConfigPathResolver.swift",
    "docs/adr/0002-window-close-keybinding-model.md",
    "vendor/ghostty", "vendor/zmx",
]

class Blocked(Exception):
    pass


def run(argv, **kwargs):
    result = subprocess.run([str(x) for x in argv], capture_output=True, text=True,
                            timeout=kwargs.pop("timeout", 15), **kwargs)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} exited {result.returncode}: {result.stderr.strip()}")
    return result.stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def open_fixture_root(value, temporary_directory):
    root = Path(value)
    if not root.is_absolute() or ".." in root.parts:
        raise Blocked("Fixture root must be an absolute path without parent traversal")
    temporary = temporary_directory.resolve(strict=True)
    # getconf may use the system /var alias; only that trusted prefix is canonicalized.
    relative = None
    for base in (temporary_directory, temporary):
        try:
            relative = root.relative_to(base)
            break
        except ValueError:
            pass
    if relative is None or not relative.parts:
        raise Blocked("Fixture root must be inside DARWIN_USER_TEMP_DIR")
    descriptor = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for component in relative.parts:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise Blocked("Fixture root must be owned by the runner UID with mode 0700")
        return temporary / relative, descriptor
    except BaseException:
        os.close(descriptor)
        raise


def submodule_source(path):
    def git(*arguments):
        return subprocess.check_output(["git", *arguments], cwd=path)

    if any(entry.startswith(b"160000 ") for entry in git("ls-files", "--stage", "-z").split(b"\0")):
        raise RuntimeError("Nested submodules need explicit freshness capture: " + str(path))
    untracked = []
    for name in sorted(filter(None, git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"))):
        relative = Path(os.fsdecode(name))
        if any((path / parent).is_symlink() for parent in relative.parents):
            raise RuntimeError("Untracked path has a symlink parent: " + str(relative))
        file = path / relative
        if file.is_symlink():
            kind, content = "symlink", os.fsencode(os.readlink(file))
        else:
            with os.fdopen(os.open(file, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                    raise RuntimeError("Unsupported untracked file: " + str(relative))
                kind, content = "file", stream.read()
        untracked.append([os.fsdecode(name), kind, hashlib.sha256(content).hexdigest()])
    return {"head": git("rev-parse", "HEAD").decode().strip(),
            "stagedDiffSHA256": hashlib.sha256(git("diff", "--cached", "--binary", "--no-ext-diff",
                                                   "--no-textconv", "--ignore-submodules=none", "HEAD")).hexdigest(),
            "unstagedDiffSHA256": hashlib.sha256(git("diff", "--binary", "--no-ext-diff",
                                                     "--no-textconv", "--ignore-submodules=none")).hexdigest(),
            "untrackedSHA256": hashlib.sha256(json.dumps(untracked, ensure_ascii=True).encode()).hexdigest()}


def source():
    paths = sorted(set(PRODUCTION + [str(p.relative_to(ROOT)) for p in HERE.iterdir() if p.is_file()]))
    return {"head": run(["git", "rev-parse", "HEAD"], cwd=ROOT),
            "dirtyDiffSHA256": hashlib.sha256(subprocess.check_output(
                ["git", "diff", "HEAD", "--binary"], cwd=ROOT)).hexdigest(),
            "submodules": {p: submodule_source(ROOT / p) for p in paths if not (ROOT / p).is_file()},
            "files": {p: (digest(ROOT / p) if (ROOT / p).is_file() else
                          run(["git", "rev-parse", "HEAD"], cwd=ROOT / p)) for p in paths}}


def poll(label, predicate, seconds=15):
    deadline = time.monotonic() + seconds
    while True:
        value = predicate()
        if value and time.monotonic() <= deadline:
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError("Deadline: " + label)
        time.sleep(0.1)


def observe_process(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat=,lstart=,comm="],
                            capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, TZ="UTC", LC_ALL="C"))
    raw = result.stdout.strip()
    if result.returncode == 1 and not raw:
        return {"running": False, "state": "absent", "raw": raw}
    if result.returncode:
        raise RuntimeError("Process observation failed: " + result.stderr.strip())
    if not raw:
        return {"running": False, "state": "absent", "raw": raw}
    fields = raw.split(None, 6)
    if fields[0].startswith("Z"):
        return {"running": False, "state": fields[0], "raw": raw}
    if len(fields) != 7:
        raise RuntimeError("Malformed process observation: " + raw)
    return {"running": True, "state": fields[0], "raw": raw,
            "processStart": " ".join(fields[1:6]), "executableRaw": fields[6],
            "executableCanonical": str(Path(fields[6]).resolve())}


def alive(pid):
    return observe_process(pid)["running"]


def diagnostic_command(argv, path, seconds=8, limit=1024 * 1024):
    """Bound tool lifetime and retained bytes; always reap our diagnostic child."""
    evidence = {"command": [str(arg) for arg in argv], "path": str(path),
                "timeoutSeconds": seconds, "byteLimit": limit}
    with path.open("wb") as stream, selectors.DefaultSelector() as selector:
        process = subprocess.Popen(evidence["command"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + seconds
            retained = 0
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    evidence["timedOut"] = True
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fd, min(65536, limit - retained + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    stream.write(chunk[:limit - retained])
                    retained += len(chunk)
                    if retained > limit:
                        evidence["truncated"] = True
                        break
                if evidence.get("truncated"):
                    break
            evidence["retainedBytes"] = min(retained, limit)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
            process.stdout.close()
            evidence["returncode"] = process.returncode
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--bundle", type=Path, default=ROOT / "dist/awesoMux.app")
    parser.add_argument("--check-prerequisites", action="store_true")
    parser.add_argument("--project-transcripts", action="store_true")
    parser.add_argument("--diagnose-startup", action="store_true",
                        help="Run one real isolated setup, then stop before the journey")
    parser.add_argument("--check-freshness", type=Path)
    args = parser.parse_args()
    if args.diagnose_startup and (args.check_prerequisites or args.check_freshness):
        parser.error("--diagnose-startup requires a real setup")
    if args.check_freshness:
        fresh = json.loads(args.check_freshness.read_text())["source"] == source()
        print("fresh" if fresh else "stale: source/harness identity differs; rerun E2E")
        return 0 if fresh else 1
    if not args.output:
        parser.error("--output is required")
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    report = {"status": "blocked", "mode": "prerequisites" if args.check_prerequisites else ("startup" if args.diagnose_startup else ("project-transcripts" if args.project_transcripts else "lifecycle")),
              "steps": [], "screenshots": [], "cleanup": {"status": "not-needed"},
              "runnerContext": {"sshSessionPresent": any(key in os.environ for key in ("SSH_CONNECTION", "SSH_TTY"))}}
    helper = output / "native"
    app_pid = None
    launch_attempted = False
    launch_receipt = output / "launch-receipt.json"
    window_id = None
    profile = None
    owned_paths = []
    fixtures = None
    fixture_root = None
    fixture_identity = None
    fixture_helper = HERE / "fixture.py"
    launched = False
    env = None
    bundle = output / "run/awesoMux.app"
    binary = bundle / "Contents/MacOS/awesoMux"
    started = time.monotonic()

    def log(scenario, outcome, **evidence):
        entry = dict(scenario=scenario, outcome=outcome, elapsed=round(time.monotonic() - started, 3), **evidence)
        report["steps"].append(entry)
        with (output / "steps.jsonl").open("a") as stream:
            stream.write(json.dumps(entry) + "\n")
        save()

    def save():
        temporary = output / "report.next.json"
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(output / "report.json")

    def owned_running():
        if app_pid is None:
            return False
        expected_start = " ".join(report["appProcessStart"].split())
        exit_deadline = None
        while True:
            observation = observe_process(app_pid)
            report["lastAppProcessObservation"] = observation
            if not observation["running"]:
                return False
            exiting = "E" in observation["state"]
            removed_comm = observation["executableRaw"] == "(" + binary.name + ")"
            if observation["processStart"] != expected_start or (
                    observation["executableCanonical"] != str(binary.resolve()) and not (exiting and removed_comm)):
                raise RuntimeError("Owned app executable/process-start identity changed: " + json.dumps(observation))
            if not exiting and exit_deadline is None:
                return True
            if exit_deadline is None:
                exit_deadline = time.monotonic() + 5
                report.setdefault("appExitingObservations", []).append(observation)
                save()
            if time.monotonic() >= exit_deadline:
                raise RuntimeError("Exiting owned app did not become absent/zombie: " + json.dumps(observation))
            time.sleep(0.1)

    def signal_owned(signum):
        if owned_running():
            event = {"signal": signum, "observation": report["lastAppProcessObservation"]}
            report.setdefault("signals", []).append(event)
            save()
            try:
                os.kill(app_pid, signum)
            except ProcessLookupError:
                event["outcome"] = "already-exited"

    def check_console():
        state = json.loads(run([helper, "session"]))
        report["consoleState"] = state
        save()
        if state.get("ready") is not True:
            raise Blocked("Interactive console unavailable: " + "; ".join(state.get("errors", ["Unknown console state"])))

    def helper_result(arguments, **kwargs):
        nonlocal launch_attempted
        try:
            return json.loads(run([helper, *arguments], **kwargs))
        except RuntimeError as error:
            marker = "Interactive console unavailable: "
            if marker in str(error):
                report["consoleState"] = json.loads(str(error).split(marker, 1)[1])
                if arguments[0] == "launch":
                    # The helper's only launch console guard precedes LaunchServices dispatch.
                    launch_attempted = False
                    report["launch"]["consoleBlockedBeforeDispatch"] = True
                save()
                raise Blocked(str(error)) from error
            raise

    def native(command, *extra):
        check_console()
        if not owned_running():
            raise RuntimeError("Owned app exited before native operation")
        return helper_result([command, app_pid, *extra])

    def snapshot():
        state = native("snapshot")
        if window_id is not None and state["windowID"] != window_id:
            raise RuntimeError("Owned window changed")
        return state

    def menu(group, title):
        snapshot()
        native("menu", window_id, group, title)
        log("dispatch", "sent", menu=group, item=title)

    def capture(name):
        snapshot()
        try:
            evidence = native("screenshot", window_id, output / (name + ".png"))
        except Exception as error:
            raise Blocked("Required window PNG unavailable: " + str(error)) from error
        evidence["sha256"] = digest(Path(evidence["path"]))
        report["screenshots"].append(evidence)
        save()

    def retain_storage_diagnostics():
        if app_pid is None or not owned_running():
            return
        path = output / "runtime-open-files.txt"
        evidence = diagnostic_command(
            ["/usr/sbin/lsof", "-a", "-p", app_pid, "-Ffn"], path)
        evidence["observation"] = report["lastAppProcessObservation"]
        evidence["externalPaths"] = sorted({
            line[1:] for line in path.read_text(errors="replace").splitlines()
            if line.startswith("n/Volumes/")
        })
        report["runtimeStorage"] = evidence
        save()

    def retain_startup_diagnostics():
        if app_pid is None or "startupDiagnostics" in report:
            return
        evidence = {"pid": app_pid, "commands": []}
        report["startupDiagnostics"] = evidence
        try:
            # Sample before AX calls or cleanup can obscure the startup stall.
            if not owned_running():
                evidence["sampleSkipped"] = "Owned process already exited"
            else:
                evidence["sampleObservation"] = report["lastAppProcessObservation"]
                try:
                    evidence["commands"].append(diagnostic_command(
                        ["/usr/bin/sample", app_pid, "2", "10", "-file", "/dev/stdout"],
                        output / "startup-sample.txt"))
                except Exception as error:
                    evidence["sampleError"] = str(error)
            # Revalidate birth/executable before querying logs for this PID.
            owned_running()
            evidence["logObservation"] = report["lastAppProcessObservation"]
            start = report.get("launch", {}).get("requestedAtUTC")
            if start:
                end = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S+0000")
                evidence["commands"].append(diagnostic_command(
                    ["/usr/bin/log", "show", "--style", "compact", "--info", "--debug",
                     "--start", start, "--end", end, "--predicate", f"processIdentifier == {app_pid}"],
                    output / "startup-unified.log"))
            else:
                evidence["logSkipped"] = "Launch timestamp unavailable"
        except Exception as error:
            evidence["error"] = str(error)
        finally:
            (output / "startup-diagnostics.json").write_text(json.dumps(evidence, indent=2) + "\n")
            save()

    def retain_failure():
        retain_storage_diagnostics()
        retain_startup_diagnostics()
        if app_pid:
            diagnostic_path = output / "failure-diagnostic.json"
            try:
                diagnostic = native("diagnose")
            except Exception as diagnostic_error:
                diagnostic = {"error": str(diagnostic_error), "pid": app_pid}
            diagnostic_path.write_text(json.dumps(diagnostic, indent=2) + "\n")
            report["failureDiagnostic"] = str(diagnostic_path)
        if app_pid and window_id:
            try:
                capture("last-failure")
            except Exception as capture_error:
                report["failureCaptureError"] = str(capture_error)

    def amx(*arguments):
        return run([bundle / "Contents/MacOS/amx", *arguments], env=env)

    def sessions():
        listing = amx("list", "--short").splitlines()
        if any(not re.fullmatch(r"[0-9a-f-]{36}", item) for item in listing):
            raise RuntimeError("Unexpected session inventory")
        return set(listing)

    def receipt(path):
        return json.loads(path.read_text()) if path.exists() else None

    def title(session):
        return str(fixtures / "panes" / session)

    def terminal_matches(description, session):
        prefix = "Terminal output, "
        return description.startswith(prefix + "/") and str(Path(description[len(prefix):]).resolve()) == title(session)

    def same_identity(data, session):
        return data and all(data.get(key) == value for key, value in identities[session].items())

    def type_into(session, text):
        readiness = {"session": session, "pollCount": 0, "lastObservation": None}
        def ready():
            state = native("input-ready", window_id, title(session))
            readiness["pollCount"] += 1
            readiness["lastObservation"] = state
            return state["ready"]
        try:
            poll("exact focused terminal", ready)
        finally:
            report.setdefault("inputReadiness", []).append(readiness)
            save()
        native("type", window_id, title(session), text + "\r")

    def response_for(nonce, session):
        return "TL_RESPONSE_" + hashlib.sha256((secret + nonce + session).encode()).hexdigest()[:20]

    def audit_challenges(read_history=True):
        ledger = report.get("challenges", [])
        if not ledger:
            return
        current = sessions() if read_history else set()
        histories = {session: amx("history", session) for session in current}
        for item in ledger:
            prefix = "response-" + item["nonce"] + "-"
            intended = prefix + item["session"] + ".json"
            for path in fixtures.glob(prefix + "*"):
                if path.name not in (intended, intended + ".next"):
                    raise RuntimeError("Challenge executed in sibling: " + path.name)
            for sibling in (set(item["siblings"]) | current) - {item["session"]}:
                if sibling in histories and any(marker in histories[sibling] for marker in (
                        response_for(item["nonce"], sibling), response_for(item["nonce"], item["session"]))):
                    raise RuntimeError("Challenge response in sibling history: " + sibling)

    def challenge(session, scenario):
        nonce = secrets.token_hex(12)
        report.setdefault("challenges", []).append({"scenario": scenario, "nonce": nonce,
                                                   "session": session, "siblings": sorted(sessions() - {session})})
        save()
        type_into(session, f"{shlex.quote(sys.executable)} {shlex.quote(str(fixture_helper))} respond $$ {nonce}")
        response = response_for(nonce, session)
        def received():
            audit_challenges()
            data = receipt(fixtures / ("response-" + nonce + "-" + session + ".json"))
            history = amx("history", session).replace("\r", "")
            return data if same_identity(data, session) \
                and data["response"] == response and response in history.splitlines() else None
        data = poll("challenge response " + scenario, received)
        poll("synthetic shell prompt ready", lambda: snapshot()["focusedValue"].rstrip().endswith(
            "TL_PROMPT_" + report["runID"]))
        audit_challenges()
        (output / (scenario + "-history.txt")).write_text(amx("history", session))
        log(scenario, "pass", nonce=nonce, response=response, receipt=data)

    def interrupted(signum, _frame):
        raise RuntimeError("Cancelled by signal " + str(signum))

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    code = 2
    try:
        report["source"] = source()
        save()
        if sys.platform != "darwin":
            raise Blocked("macOS GUI session required")
        for executable in ("swiftc", "trash", "codesign"):
            if not shutil.which(executable):
                raise Blocked("Missing executable: " + executable)
        if not (args.bundle / "Contents/MacOS/awesoMux").is_file() or not (args.bundle / "Contents/MacOS/amx").is_file():
            raise Blocked("Stage first: ./script/build_and_run.sh --stage-local-api-e2e")
        run(["swiftc", HERE / "native.swift", "-o", helper], timeout=120)
        prerequisites = json.loads(run([helper, "probe"]))
        report["prerequisites"] = prerequisites
        report["consoleState"] = prerequisites["consoleState"]
        if prerequisites["console"] is not True:
            raise Blocked("Interactive console unavailable: " + "; ".join(prerequisites["consoleState"]["errors"]))
        if not all(prerequisites[key] is True for key in ("accessibility", "screenCapture")):
            raise Blocked("GUI/Accessibility/Screen Recording prerequisite unavailable")
        socket_base = Path(run(["getconf", "DARWIN_USER_TEMP_DIR"]))
        fixture_override = os.environ.get("HEAVY_GATE_UI_FIXTURE_ROOT")
        if fixture_override is not None:
            fixture_root, descriptor = open_fixture_root(fixture_override, socket_base)
            try:
                fixtures = Path(tempfile.mkdtemp(prefix="native-ui-", dir=fixture_root))
                fixture_identity = os.stat(fixtures.name, dir_fd=descriptor, follow_symlinks=False)
            finally:
                os.close(descriptor)
        else:
            fixtures = output / "fixtures"
            fixtures.mkdir(mode=0o700)
        if fixture_root is not None:
            fixture_helper = fixtures / "fixture.py"
            shutil.copy2(HERE / "fixture.py", fixture_helper)
            if digest(fixture_helper) != digest(HERE / "fixture.py"):
                raise Blocked("Copied fixture helper differs from committed source")
        report["fixtures"] = {"path": str(fixtures), "temporary": fixture_root is not None,
                              "helper": str(fixture_helper), "helperSHA256": digest(fixture_helper)}
        save()
        fixture_home = fixtures / "home"
        fixture_home.mkdir(mode=0o700)
        (fixtures / "panes").mkdir(mode=0o700)
        # These overrides belong only to isolated child processes, never this runner.
        env = {key: os.environ[key] for key in ("PATH", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING") if key in os.environ}
        env.update(HOME=str(fixture_home), CFFIXED_USER_HOME=str(fixture_home),
                   SHELL="/bin/zsh", ZDOTDIR=str(fixtures), XDG_CONFIG_HOME=str(fixture_home / ".config"),
                   TL_FIXTURES=str(fixtures), TMPDIR=str(socket_base) + "/", LANG="en_US.UTF-8", TZ="UTC", LC_ALL="C")
        resolved_paths = json.loads(run([helper, "paths"], env=env))
        expected_paths = {"home": str(fixture_home), "nsHome": str(fixture_home),
                          "support": str(fixture_home / "Library/Application Support"),
                          "environmentHome": str(fixture_home), "fixedHome": str(fixture_home)}
        canonical_paths = {key: str(Path(value).resolve()) for key, value in resolved_paths.items()}
        report["pathIsolation"] = {"expected": expected_paths, "resolved": resolved_paths,
                                   "canonicalResolved": canonical_paths}
        if canonical_paths != expected_paths:
            raise Blocked("Disposable HOME/Foundation path isolation probe mismatch")
        if args.check_prerequisites:
            report["ready"] = True
            report["reason"] = "Prerequisites ready; lifecycle not executed"
            log("prerequisites", "ready")
            code = 0
        else:
            run_dir = (fixtures if fixture_root is not None else output) / "run"
            bundle = run_dir / "awesoMux.app"
            binary = bundle / "Contents/MacOS/awesoMux"
            run_dir.mkdir(mode=0o700)
            profile_text = run(["/bin/bash", "-c", 'source "$1"; awesomux_resolve_profile "development:$(awesomux_worktree_id "$2")"; awesomux_print_profile',
                                "lifecycle", ROOT / "script/runtime-profile.sh", run_dir])
            profile = dict(line.split("=", 1) for line in profile_text.splitlines())
            socket = socket_base / profile["socket"]
            support = Path(canonical_paths["support"]) / profile["support"]
            config = fixture_home / ".config" / profile["config"]
            defaults_file = fixture_home / "Library/Preferences" / (profile["bundle"] + ".plist")
            for path in (socket, support, config, defaults_file):
                if path.exists() or path.is_symlink():
                    raise Blocked("Preexisting profile collision: " + str(path))
            for defaults_env in (None, env):
                defaults = subprocess.run(["defaults", "read", profile["bundle"]], capture_output=True,
                                          env=defaults_env, timeout=15)
                if defaults.returncode == 0:
                    raise Blocked("Preexisting defaults domain collision")
            report["profile"] = dict(profile, namespace=str(socket), supportPath=str(support), configPath=str(config))
            # Reserve collision-sensitive directories before copying or launching.
            for path in (socket, support, config):
                path.mkdir(mode=0o700, parents=True)
                owned_paths.append(path)
            (config / "config.toml").write_text(
                "[terminal]\ncommand_bridge_enabled = true\n"
                "[workspaces]\nconfirm_close_with_running_agent = true\n"
                "[notifications]\nmuted = true\n"
                + (("[appearance]\nui_text_scale = " + os.environ.get("PR775_SCALE", "1.0") + "\nui_font = \"Georgia\"\n") if args.project_transcripts else ""))
            secret = secrets.token_hex(32)
            (fixtures / "secret").write_text(secret)
            report["runID"] = secrets.token_hex(6)
            shutil.copytree(args.bundle, bundle, symlinks=True)
            if fixture_root is not None:
                for path in bundle.rglob("*"):
                    if path.is_symlink() and not path.resolve().is_relative_to(bundle.resolve()):
                        raise Blocked("Copied app symlink escapes its bundle: " + str(path))
                if not (bundle / "Contents/Resources/awesoMux_DesignSystem.bundle").is_dir():
                    raise Blocked("Copied app lacks bundled design-system fonts")
            info = bundle / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            metadata["CFBundleIdentifier"] = profile["bundle"]
            metadata["CFBundleDisplayName"] = profile["display"]
            metadata["CFBundleName"] = profile["display"]
            info.write_bytes(plistlib.dumps(metadata))
            run(["codesign", "--force", "--deep", "--sign", "-", bundle], timeout=60)
            run(["codesign", "--verify", "--deep", "--strict", bundle], timeout=60)
            report["signatureVerification"] = "codesign --verify --deep --strict: passed"
            report["binary"] = {"sourceBundle": str(args.bundle.resolve()), "path": str(binary),
                                "sha256": digest(binary), "amxSHA256": digest(bundle / "Contents/MacOS/amx")}
            startup = f'''PS1='TL_PROMPT_{report["runID"]} '
[[ "$ZMX_SESSION" =~ '^[0-9a-f-]{{36}}$' ]] || exit 91
mkdir -m 700 -- "$TL_FIXTURES/panes/$ZMX_SESSION" && cd -P -- "$TL_FIXTURES/panes/$ZMX_SESSION" || exit 91
{shlex.quote(sys.executable)} {shlex.quote(str(fixture_helper))} register $$
printf '\\033]7;file://%s%s\\007\\033]2;%s\\007' "$HOST" "$PWD" "$PWD"
'''
            (fixtures / ".zshenv").write_text(f'''if [[ "$CFFIXED_USER_HOME" != {shlex.quote(str(fixture_home))} || "$TL_FIXTURES" != {shlex.quote(str(fixtures))} || "$ZDOTDIR" != {shlex.quote(str(fixtures))} ]]; then
    print -u2 'Terminal lifecycle fixture startup isolation mismatch'
    exit 90
fi
export TL_HOME_BEFORE_FIXTURE="$HOME"
export TL_ZDOTDIR_AT_FIXTURE="$ZDOTDIR"
export HOME={shlex.quote(str(fixture_home))}
export GHOSTTY_SHELL_FEATURES=""
''')
            (fixtures / ".zshrc").write_text(startup)
            env.update(ZMX_DIR=str(socket), ZMX_DIR_MODE="700")
            request_path = output / "launch-request.json"
            request_path.write_text(json.dumps({"bundle": str(bundle), "bundleID": profile["bundle"],
                                               "environment": env,
                                               "arguments": ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]}, indent=2))
            report["launch"] = {"method": "NSWorkspace.OpenConfiguration", "request": str(request_path),
                                "receipt": str(launch_receipt), "stdoutStderr": "not redirected by LaunchServices",
                                "requestedAtUTC": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S+0000")}
            check_console()
            launch_attempted = True
            save()
            launch = helper_result(["launch", request_path, launch_receipt], env=env, timeout=20)
            app_pid = launch["pid"]
            launched = True
            report["appPID"] = app_pid
            report["appProcessStart"] = launch["processStart"]
            report["launch"]["identity"] = launch
            if not owned_running():
                raise RuntimeError("LaunchServices app exited before identity verification")
            save()
            def initial_window():
                if not owned_running():
                    raise RuntimeError("Owned app exited before window readiness")
                try:
                    return native("snapshot")
                except RuntimeError as error:
                    if not any(message in str(error) for message in (
                            "Expected one owned standard AX/CG window",
                            "Exact owned AX/CG window correspondence unavailable")):
                        raise
                    return False
            try:
                state = poll("owned content window", initial_window)
            except BaseException as error:
                retain_startup_diagnostics()
                diagnostic_path = output / "window-readiness-diagnostic.json"
                try:
                    diagnostic = native("diagnose")
                except Exception as diagnostic_error:
                    diagnostic = {"error": str(diagnostic_error), "pid": app_pid}
                diagnostic["readinessFailure"] = str(error)
                diagnostic_path.write_text(json.dumps(diagnostic, indent=2) + "\n")
                report["windowReadinessDiagnostic"] = str(diagnostic_path)
                raise
            window_id = state["windowID"]
            report["windowID"] = window_id
            report["initialWindow"] = state
            activation = native("activate", window_id)
            report["activation"] = activation
            save()
            if not activation["activationRequested"]:
                raise RuntimeError("Cannot activate owned window: " + json.dumps(activation))
            def activated_window():
                observed = snapshot()
                return observed if observed["frontmost"] and observed["ownedWindowFocused"] else None
            report["activatedWindow"] = poll("owned app/window focused after activation", activated_window)
            if state["terminals"] or sessions():
                raise RuntimeError("Fresh profile unexpectedly has an existing terminal")
            report["activeScenario"] = "TL01"
            menu("File", "New Workspace")
            def first_backend():
                if snapshot()["modalCount"]:
                    raise Blocked("Unexpected owned modal before first backend; inspect retained diagnostic; no dialog action taken")
                return len(sessions()) == 1
            poll("first backend", first_backend)
            first = next(iter(sessions()))
            if args.project_transcripts or args.diagnose_startup:
                data = poll("shell identity", lambda: receipt(fixtures / (first + ".json")))
                if data["session"] != first or data["profile"] != profile["profile"] \
                        or Path(data["namespace"]).resolve() != socket.resolve() or not alive(data["shellPID"]) \
                        or data["home"] != str(fixture_home) or data["fixedHome"] != str(fixture_home) \
                        or data["startupZDOTDIR"] != str(fixtures) or data["zdotdir"] != str(fixtures) \
                        or str(Path(data["cwd"]).resolve()) != title(first):
                    raise RuntimeError("Fixture shell/profile identity mismatch")
                identities = {first: data}
                report["identities"] = identities
            if args.diagnose_startup:
                poll("terminal ready", lambda: any(terminal_matches(t, first) for t in snapshot()["terminals"]))
                report["reason"] = "Startup ready; lifecycle and transcript journeys not executed"
                log("startup", "pass")
            elif args.project_transcripts:
                project = Path(run([helper, "canonical-path", title(first)]))
                slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in str(project))
                claude = fixture_home / ".claude/projects" / slug
                codex = fixture_home / ".codex/sessions/2026/10/22"
                claude.mkdir(parents=True); codex.mkdir(parents=True)
                ids = [f"10000000-0000-4000-8000-{n:012d}" for n in range(1,5)]
                def write(path, rows):
                    path.write_text("".join(json.dumps(row)+"\n" for row in rows))
                    path.chmod(0o600)
                write(claude/(ids[0]+".jsonl"), [{"type":"user", "sessionId":ids[0], "cwd":str(project), "message":{"content":"PR775_CLAUDE_SYNTHETIC"}}])
                for i, cwd, extra in [(1,project,{}),(2,project.parent,{}),(3,project,{"source":{"subagent":{}}})]:
                    write(codex/("rollout-"+ids[i]+".jsonl"), [
                        {"type":"session_meta","payload":{"id":ids[i],"cwd":str(cwd),"source":"cli",**extra}},
                        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"PR775_CODEX_SYNTHETIC"}]}}])
                poll("terminal ready", lambda: any(terminal_matches(t,first) for t in snapshot()["terminals"]))
                menu("Pane", "Browse Project Transcripts")
                def listed():
                    nodes=native("dump",window_id)
                    text=json.dumps(nodes)
                    return nodes if ids[0] in text and ids[1] in text else None
                listing=poll("project transcript rows",listed)
                listing_text=json.dumps(listing)
                assert ids[2] not in listing_text and ids[3] not in listing_text
                (output/"browser-ax.json").write_text(json.dumps(listing,indent=2))
                capture("browser-scale-"+os.environ.get("PR775_SCALE","1.0"))
                refresh_id = "10000000-0000-4000-8000-000000000005"
                if refresh_id in listing_text:
                    raise RuntimeError("Refresh fixture unexpectedly existed before creation")
                write(claude/(refresh_id+".jsonl"), [{"type":"user", "sessionId":refresh_id, "cwd":str(project), "message":{"content":"PR775_REFRESH_SYNTHETIC"}}])
                native("press",window_id,"Refresh")
                def refreshed():
                    nodes = listed()
                    return nodes if nodes and refresh_id in json.dumps(nodes) else None
                refreshed_listing = poll("new transcript appears after refresh", refreshed)
                if any(excluded in json.dumps(refreshed_listing) for excluded in ids[2:]):
                    raise RuntimeError("Refresh included an unrelated or child transcript")
                report["refreshVerifiedID"] = refresh_id
                native("press",window_id,"Cancel")
                poll("cancel dismissed browser",lambda: not any((b["title"]=="Refresh" or b["description"]=="Refresh") for b in snapshot()["buttons"]))
                menu("Pane", "Browse Project Transcripts")
                poll("rows after reopen",listed)
                native("press",window_id,"Open")
                def opened():
                    nodes=native("dump",window_id)
                    text=json.dumps(nodes)
                    return nodes if "PR775_" in text and "SYNTHETIC" in text else None
                document=poll("opened synthetic transcript",opened)
                (output/"document-ax.json").write_text(json.dumps(document,indent=2))
                focus=snapshot()
                report["documentFocus"]=focus
                assert not focus["focusedTerminal"]
                assert "PR775_" in focus["focusedValue"]
                capture("opened-document")
                report["browserVerification"]={"expectedIDs":ids[:2]+[refresh_id],"excludedIDs":ids[2:],"scale":os.environ.get("PR775_SCALE","1.0"),"font":"Georgia","voiceOverSpeech":"not tested"}
                log("PR775", "pass", checks=["project and child filtering", "refresh", "cancel and reopen", "open", "document focus"])
            else:
                menu("Pane", "Split Right")
                poll("two backend sessions", lambda: len(sessions()) == 2)
                current = sessions()
                identities = {}
                for session in current:
                    data = poll("shell identity", lambda s=session: receipt(fixtures / (s + ".json")))
                    if data["session"] != session or data["profile"] != profile["profile"] \
                            or Path(data["namespace"]).resolve() != socket.resolve() or not alive(data["shellPID"]) \
                            or data["home"] != str(fixture_home) or data["fixedHome"] != str(fixture_home) \
                            or data["startupZDOTDIR"] != str(fixtures) or data["zdotdir"] != str(fixtures) \
                            or str(Path(data["cwd"]).resolve()) != title(session):
                        raise RuntimeError("Fixture shell/profile identity mismatch")
                    identities[session] = data
                second = next(iter(current - {first}))
                if identities[first]["workspace"] != identities[second]["workspace"]:
                    raise RuntimeError("Split created another workspace")
                report["identities"] = identities
                poll("two native terminals", lambda: len(snapshot()["terminals"]) == 2)
                capture("two-panes-ready")
                log("TL01", "pass", sessions=sorted(current))
                report["activeScenario"] = "TL02"
                menu("Pane", "Focus Pane 1")
                challenge(first, "TL02-pane1")
                menu("Pane", "Focus Pane 2")
                challenge(second, "TL02-pane2")
                log("TL02", "pass")
                report["activeScenario"] = "TL03"
                type_into(second, f"{shlex.quote(sys.executable)} {shlex.quote(str(fixture_helper))} job $$")
                job = poll("controlled foreground job", lambda: receipt(fixtures / "job.json"))
                if not same_identity(job, second) or not alive(job["jobPID"]):
                    raise RuntimeError("Controlled job identity mismatch")
                report["job"] = job
                menu("Pane", "Focus Pane 1")
                type_into(first, "exit")
                poll("exited pane removed", lambda: first not in sessions() and len(snapshot()["terminals"]) == 1)
                poll("exited root shell gone", lambda: not alive(identities[first]["shellPID"]))
                before = receipt(fixtures / "job.json")["heartbeat"]
                poll("sibling job survived", lambda: receipt(fixtures / "job.json")["heartbeat"] > before)
                if not alive(identities[second]["shellPID"]):
                    raise RuntimeError("Sibling shell died")
                log("TL03", "pass", shellPID=identities[second]["shellPID"], jobPID=job["jobPID"])
                report["activeScenario"] = "TL04"
                menu("Pane", "Close Workspace")
                poll("busy-close modal", lambda: {"Cancel", "Close Workspace"}.issubset(
                    {b["title"] for b in snapshot()["modalButtons"]}))
                capture("busy-close-modal")
                before = receipt(fixtures / "job.json")["heartbeat"]
                native("cancel", window_id)
                poll("modal dismissed", lambda: not any(b["title"] == "Cancel" for b in snapshot()["buttons"]))
                poll("cancel preserves running job", lambda: receipt(fixtures / "job.json")["heartbeat"] > before)
                if sessions() != {second} or not alive(job["jobPID"]) or not alive(identities[second]["shellPID"]):
                    raise RuntimeError("Cancel changed shell/job/backend identity")
                log("TL04", "pass", jobPID=job["jobPID"])
                report["activeScenario"] = "TL05"
                (fixtures / "release").touch()
                poll("job completed normally", lambda: receipt(fixtures / "job-finished.json") and not alive(job["jobPID"]))
                challenge(second, "TL05-before-close")
                menu("Workspace", "Close Workspace")
                poll("workspace soft closed", lambda: len(snapshot()["terminals"]) == 0)
                if sessions() != {second} or not alive(identities[second]["shellPID"]):
                    raise RuntimeError("Soft close destroyed persistent shell")
                menu("Workspace", "Reopen Closed Workspace")
                def reopened():
                    terminals = snapshot()["terminals"]
                    return len(terminals) == 1 and terminal_matches(terminals[0], second)
                poll("reopened same terminal", reopened)
                menu("Pane", "Focus Pane 1")
                challenge(second, "TL05-reopened")
                if sessions() != {second} or not alive(identities[second]["shellPID"]):
                    raise RuntimeError("Reopen replaced persistent shell")
                capture("reopened-usable-terminal")
                log("TL05", "pass", session=second, shellPID=identities[second]["shellPID"])
                audit_challenges()
            retain_storage_diagnostics()
            report["status"] = "pass"
            code = 0
    except Blocked as error:
        report["status"] = "blocked"
        report["reason"] = str(error)
        log(report.get("activeScenario", "prerequisites"), "blocked", reason=str(error))
        code = 2
        retain_failure()
    except BaseException as error:
        report["status"] = "fail"
        report["reason"] = str(error)
        log(report.get("activeScenario", "setup"), "fail", reason=str(error))
        code = 1
        retain_failure()
    finally:
        # Cancellation must not interrupt scoped cleanup a second time.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if owned_paths:
            report["cleanup"] = {"status": "pending", "paths": [str(p) for p in owned_paths]}
            save()
            try:
                if launch_attempted and app_pid is None:
                    # A cancelled/lost helper response may follow a successful launch.
                    # Recover only the run-exclusive executable; never a process name.
                    def recover_launch():
                        rows = run(["/bin/ps", "-axo", "pid=,stat=,lstart=,comm="],
                                   env=dict(os.environ, TZ="UTC", LC_ALL="C")).splitlines()
                        matches = []
                        for row in rows:
                            parts = row.strip().split(None, 7)
                            if len(parts) == 8 and str(Path(parts[7]).resolve()) == str(binary.resolve()):
                                matches.append({"pid": int(parts[0]), "observation": {
                                    "running": not parts[1].startswith("Z"), "state": parts[1], "raw": row,
                                    "processStart": " ".join(parts[2:7]), "executableRaw": parts[7],
                                    "executableCanonical": str(Path(parts[7]).resolve())}})
                        if len(matches) > 1:
                            raise RuntimeError("Multiple processes for exclusive copied bundle")
                        if not matches:
                            return None
                        report["launch"]["cleanupRecoveryCandidateObservation"] = matches[0]["observation"]
                        save()
                        return matches[0]
                    recorded_launch = receipt(launch_receipt)
                    if recorded_launch and recorded_launch.get("status") == "launched":
                        app_pid = recorded_launch["pid"]
                        launched = True
                        report["appPID"] = app_pid
                        report["appProcessStart"] = recorded_launch["processStart"]
                    elif not recorded_launch or recorded_launch.get("status") != "error":
                        candidate = poll("recover exact LaunchServices PID", recover_launch, seconds=12)
                        app_pid = candidate["pid"]
                        launched = True
                        report["appPID"] = app_pid
                        recovered = observe_process(app_pid)
                        report["launch"]["cleanupRecoveredObservation"] = recovered
                        report["launch"]["cleanupRecoveredPID"] = True
                        save()
                        if not recovered["running"]:
                            app_pid = None
                        elif not candidate["observation"]["running"]:
                            raise RuntimeError("Recovery PID became live after disappearance: " + json.dumps(recovered))
                        else:
                            report["appProcessStart"] = candidate["observation"]["processStart"]
                            exiting_removed = "E" in recovered["state"] and recovered["executableRaw"] == "(" + binary.name + ")"
                            if recovered["processStart"] != report["appProcessStart"] or (
                                    recovered["executableCanonical"] != str(binary.resolve()) and not exiting_removed):
                                raise RuntimeError("Recovered launch identity changed: " + json.dumps(recovered))
                if report["status"] != "pass":
                    retain_startup_diagnostics()
                if owned_running():
                    signal_owned(signal.SIGTERM)
                    try:
                        poll("owned app exited after TERM", lambda: not owned_running(), seconds=5)
                    except RuntimeError as error:
                        if not str(error).startswith("Deadline:"):
                            raise
                        signal_owned(signal.SIGKILL)
                        poll("owned app exited after KILL", lambda: not owned_running(), seconds=5)
                if launched:
                    run([ROOT / "script/amx-reap.sh", "--profile", profile["profile"], "all"],
                        env=dict(env, AWESOMUX_AMX=str(bundle / "Contents/MacOS/amx")), timeout=30)
                    poll("namespace empty after cleanup", lambda: not sessions())
                    for data in report.get("identities", {}).values():
                        poll("fixture root shell exited", lambda p=data["shellPID"]: not alive(p))
                    if "job" in report:
                        poll("fixture job exited", lambda: not alive(report["job"]["jobPID"]))
                    try:
                        audit_challenges(read_history=False)
                        report["finalChallengeAudit"] = "pass: no sibling receipts through backend termination"
                    except RuntimeError as audit_error:
                        report["status"] = "fail"
                        report["reason"] = str(audit_error)
                        report["finalChallengeAudit"] = "fail"
                        code = 1
                        log("TL02-final-audit", "fail", reason=str(audit_error))
                defaults = subprocess.run(["defaults", "read", profile["bundle"]], capture_output=True, env=env, timeout=15)
                if defaults.returncode == 0:
                    run(["defaults", "delete", profile["bundle"]], env=env)
                for path in owned_paths:
                    if path.exists() or path.is_symlink():
                        run(["trash", path])
                if fixture_root is None and bundle.exists():
                    run(["trash", bundle])
                report["cleanup"]["status"] = "pass"
            except BaseException as error:
                report["cleanup"].update(status="fail", reason=str(error))
                report["status"] = "fail"
                code = 1
        if fixtures is not None:
            fixture_cleanup = {"status": "pending", "path": str(fixtures)}
            report["cleanup"]["fixtures"] = fixture_cleanup
            try:
                if launch_attempted and report["cleanup"]["status"] != "pass":
                    raise RuntimeError("Fixture cleanup retained paths: process cleanup incomplete")
                if fixture_root is not None:
                    _, descriptor = open_fixture_root(fixture_override, socket_base)
                    try:
                        current = os.stat(fixtures.name, dir_fd=descriptor, follow_symlinks=False)
                        if (current.st_dev, current.st_ino) != (fixture_identity.st_dev, fixture_identity.st_ino):
                            raise RuntimeError("Owned fixture directory identity changed")
                        run(["trash", fixtures])
                    finally:
                        os.close(descriptor)
                else:
                    secret_path = fixtures / "secret"
                    if secret_path.exists() or secret_path.is_symlink():
                        run(["trash", secret_path])
                fixture_cleanup["status"] = "pass"
            except BaseException as error:
                fixture_cleanup.update(status="fail", reason=str(error))
                report["cleanup"]["status"] = "fail"
                report["status"] = "fail"
                code = 1
        save()
    print(str(output / "report.json"))
    return code

if __name__ == "__main__":
    sys.exit(main())
