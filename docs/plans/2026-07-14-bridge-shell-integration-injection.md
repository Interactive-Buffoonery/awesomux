# Bridged Shell Integration Injection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make daemon-spawned (command-bridge) zsh shells source ghostty's shell integration so OSC-133 prompt marks flow, fixing the false "activity that will be interrupted" warning on every bridged workspace close.

**Architecture:** libghostty injects shell-integration env (the zsh `ZDOTDIR` trick) only when its direct child is a recognized shell. Bridged panes spawn `env -u … amx attach <id>` instead, so the injection never happens; the zmx daemon is a `fork()` of the first attach client and `execvpe`s `$SHELL` with the client's environment (`vendor/zmx/src/main.zig:718-761, 802-974`). Therefore: replicate ghostty's zsh injection as `KEY=VALUE` tokens on the attach command itself. Injecting on EVERY attach (not just the first) is required, not merely safe: a reattach that finds a stale/unresponsive socket flips `should_create` and forks a replacement daemon (`main.zig:811, 858, 865`), so the reattach environment is load-bearing on that recovery path. Injection is gated on the effective `$SHELL` being zsh — leaving `ZDOTDIR` in a bash/fish daemon's environment would leak into any nested zsh launched later (cross-model review finding #3). Local attaches only — the remote/SSH tail runs `"$SHELL" -l` on the far host where a local resources path is meaningless.

**Tech Stack:** Swift 6.3 / SwiftPM, swift-testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Never modify `vendor/ghostty` or `vendor/zmx` (submodules).
- Conventional Commits, subject ≤72 chars, lowercase imperative.
- New tests use swift-testing, not XCTest.
- Run `./script/swift-test.sh` for tests; `./script/format.sh <changed files>` before committing; `./script/preflight.sh` before opening the PR.
- The injection must no-op when `GHOSTTY_RESOURCES_DIR` is unset (dev `swift run` with unstaged resources): `AwesoMuxApp.swift:60-75` only sets it when `<resources>/ghostty/shell-integration` exists on disk, so its presence *is* the existence check — do not add filesystem probes to `AmxBackend`.
- Read `GHOSTTY_RESOURCES_DIR`/`ZDOTDIR` from `ProcessInfo.processInfo.environment` at call time (after the app's startup env sanitization), never re-derive from `Bundle.main`.

## Background for the implementer

- `AmxBackend.attachCommand` has two pure overloads (`Sources/awesoMux/Services/AmxBackend.swift:309-332` base, `:339-365` status) that assemble a `/usr/bin/env` command string token-by-token. Both are covered by exact-full-string tests in `Tests/awesoMuxTests/AmxBackendTests.swift`.
- ghostty's zsh injection (`vendor/ghostty/src/termio/shell_integration.zig:895-921`, reference only): if `ZDOTDIR` is already set, preserve it as `GHOSTTY_ZSH_ZDOTDIR`; then set `ZDOTDIR=<resources_dir>/shell-integration/zsh`. ghostty's bundled `.zshenv` restores the user's real `ZDOTDIR` and sources the integration that emits OSC-133.
- The daemon-spawned shell for a REMOTE session is `ssh …` (zmx trailing-command form), not zsh — injection there is pointless; keep the remote command string byte-identical to today so `BridgeAttachAssemblyTests` expectations for the remote tail stay meaningful.

---

### Task 1: Shell-integration env tokens in the base attach overload

**Files:**
- Modify: `Sources/awesoMux/Services/AmxBackend.swift:309-332` (base overload) and add one private helper near `environmentScrubTokens` (`:214-226`)
- Test: `Tests/awesoMuxTests/AmxBackendTests.swift`

**Interfaces:**
- Produces: `private static func shellIntegrationEnvTokens(remote: RemoteTarget?, ghosttyResourcesDir: String?, inheritedZDOTDIR: String?, shellPath: String?) -> [String]` — returns already-`shellQuote`d tokens. Both ordinary overloads (Task 1 and Task 2) call it. The pure overloads gain three trailing parameters with `nil` defaults: `ghosttyResourcesDir: String? = nil`, `inheritedZDOTDIR: String? = nil`, `shellPath: String? = nil`. The `Bundle.main` wrapper overloads (`:275-300`) pass `ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"]`, `…["ZDOTDIR"]`, and `…["SHELL"]`. `bridgeAttachCommand` is NOT touched — it requires a non-optional `RemoteTarget` (remote-only by construction) and the local bridge path resolves through the ordinary wrappers (`CommandBridgeEnactor.swift:151`).

- [ ] **Step 1: Write the failing tests**

Append to `AmxBackendAttachCommandTests` in `Tests/awesoMuxTests/AmxBackendTests.swift`:

```swift
@Test("injects zsh shell-integration ZDOTDIR when resources dir is provided and SHELL is zsh")
func injectsShellIntegrationZDOTDIR() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-zdot"))
    let command = try #require(AmxBackend.attachCommand(
        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        ghosttyResourcesDir: "/Apps/awesoMux.app/Contents/Resources/ghostty",
        shellPath: "/bin/zsh"
    ))
    #expect(command.contains(
        "'ZDOTDIR=/Apps/awesoMux.app/Contents/Resources/ghostty/shell-integration/zsh'"
    ))
    // No pre-existing ZDOTDIR → the preserve token must be absent, so the
    // integration .zshenv unsets ZDOTDIR after chaining (ghostty parity).
    #expect(!command.contains("GHOSTTY_ZSH_ZDOTDIR"))
}

@Test("preserves a pre-existing ZDOTDIR via GHOSTTY_ZSH_ZDOTDIR")
func preservesInheritedZDOTDIR() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-zdotkeep"))
    let command = try #require(AmxBackend.attachCommand(
        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        ghosttyResourcesDir: "/res/ghostty",
        inheritedZDOTDIR: "/Users/me/.config/zsh",
        shellPath: "/bin/zsh"
    ))
    #expect(command.contains("'ZDOTDIR=/res/ghostty/shell-integration/zsh'"))
    #expect(command.contains("'GHOSTTY_ZSH_ZDOTDIR=/Users/me/.config/zsh'"))
}

@Test("omits shell-integration tokens when resources dir is absent or empty")
func omitsShellIntegrationWithoutResourcesDir() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-nores"))
    let missing = try #require(AmxBackend.attachCommand(
        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        shellPath: "/bin/zsh"
    ))
    #expect(!missing.contains("ZDOTDIR"))
    let empty = try #require(AmxBackend.attachCommand(
        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        ghosttyResourcesDir: "",
        shellPath: "/bin/zsh"
    ))
    #expect(!empty.contains("ZDOTDIR"))
}

@Test("omits shell-integration tokens when SHELL is not zsh (or unknown)")
func omitsShellIntegrationForNonZshShell() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-bash"))
    for shell in ["/bin/bash", "/usr/local/bin/fish", nil] as [String?] {
        let command = try #require(AmxBackend.attachCommand(
            executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
            sessionID: id,
            socketDirectory: "/tmp/amx",
            ghosttyResourcesDir: "/res/ghostty",
            shellPath: shell
        ))
        // A ZDOTDIR left in a bash/fish daemon's environment would leak into
        // any nested zsh launched later — inject for zsh only.
        #expect(!command.contains("ZDOTDIR"))
    }
}

@Test("omits shell-integration tokens on the remote attach variant")
func omitsShellIntegrationForRemote() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-zdotremote"))
    let command = try #require(AmxBackend.attachCommand(
        executablePath: "/opt/awesomux/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        remote: RemoteTarget(user: "alice", host: "box")!,
        ghosttyResourcesDir: "/res/ghostty",
        shellPath: "/bin/zsh"
    ))
    #expect(!command.contains("ZDOTDIR"))
}
```

Note: the new `ghosttyResourcesDir:`/`inheritedZDOTDIR:` parameters must come AFTER `remote:` in the signature or use the exact parameter order the implementation chooses — keep test call sites and implementation consistent.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/edequalsawesome/Development/awesomux-worktrees/debug-stutter-close-warning && ./script/swift-test.sh --filter AmxBackendAttachCommandTests 2>&1 | tail -20`
Expected: compile FAILURE — `extra argument 'ghosttyResourcesDir' in call` (parameter doesn't exist yet).

- [ ] **Step 3: Implement the helper and thread it through the base overload**

In `Sources/awesoMux/Services/AmxBackend.swift`, after `environmentScrubTokens` (line 226), add:

```swift
/// Shell-integration env tokens for the daemon-spawned shell (INT close-risk
/// fix): libghostty's own zsh injection never fires for the bridge because
/// the surface child is `env … amx attach`, not a recognized shell, so the
/// daemon's zsh starts without ghostty integration and never emits OSC-133
/// prompt marks — leaving `needs_confirm_quit` conservatively true forever.
/// Mirror ghostty's `setupZsh` (vendor/ghostty/src/termio/shell_integration.zig):
/// point ZDOTDIR at the bundled integration dir and preserve any pre-existing
/// ZDOTDIR via GHOSTTY_ZSH_ZDOTDIR so the integration .zshenv can chain back.
/// Every attach carries these, not just the first: a reattach that finds a
/// stale socket forks a REPLACEMENT daemon from its own environment (zmx
/// ensureSession recovery path), so the attach env is load-bearing there
/// too. Gated on the effective $SHELL being zsh — a ZDOTDIR left in a
/// bash/fish daemon's environment would leak into any nested zsh launched
/// later. Local attaches only: a remote session's daemon spawns `ssh`, and
/// the resources path doesn't exist on the far host.
/// ponytail: zsh only — bash/nu need argv rewriting zmx doesn't support;
/// add fish/elvish via XDG_DATA_DIRS if a non-zsh user reports the warning.
private static func shellIntegrationEnvTokens(
    remote: RemoteTarget?,
    ghosttyResourcesDir: String?,
    inheritedZDOTDIR: String?,
    shellPath: String?
) -> [String] {
    guard remote == nil,
        let ghosttyResourcesDir, !ghosttyResourcesDir.isEmpty,
        let shellPath, ShellRecognition.basename(shellPath) == "zsh"
    else { return [] }
    var tokens = [
        shellQuote("ZDOTDIR=" + ghosttyResourcesDir + "/shell-integration/zsh")
    ]
    if let inheritedZDOTDIR {
        tokens.append(shellQuote("GHOSTTY_ZSH_ZDOTDIR=" + inheritedZDOTDIR))
    }
    return tokens
}
```

`ShellRecognition` lives in `AwesoMuxCore` (`Sources/AwesoMuxCore/Services/ShellRecognition.swift:16-24`), which this file already imports; its `basename` strips directories and the login-shell `-` prefix.

Change the base pure overload (`:309-332`) signature and token assembly:

```swift
static func attachCommand(
    executablePath: String,
    sessionID: TerminalSessionID,
    socketDirectory: String,
    remote: RemoteTarget? = nil,
    ghosttyResourcesDir: String? = nil,
    inheritedZDOTDIR: String? = nil,
    shellPath: String? = nil
) -> String? {
    guard TerminalSessionID.isValid(sessionID.rawValue) else {
        return nil
    }

    var tokens = [shellQuote(envExecutablePath)]
        + environmentScrubTokens(remote: remote)
        + [
            shellQuote("ZMX_DIR=" + socketDirectory),
            shellQuote("ZMX_DIR_MODE=" + socketDirectoryMode)
        ]
        + shellIntegrationEnvTokens(
            remote: remote,
            ghosttyResourcesDir: ghosttyResourcesDir,
            inheritedZDOTDIR: inheritedZDOTDIR,
            shellPath: shellPath
        )
        + [
            shellQuote(executablePath),
            "attach",
            shellQuote(sessionID.rawValue)
        ]
    if let remote {
        tokens += sshTailTokens(for: remote).map(shellQuote)
    }
    return tokens.joined(separator: " ")
}
```

Update the `Bundle.main` wrapper (`:275-285`) to pass the live values:

```swift
static func attachCommand(for sessionID: TerminalSessionID, remote: RemoteTarget? = nil) -> String? {
    guard let executableURL = bundledExecutableURL() else {
        return nil
    }
    let env = ProcessInfo.processInfo.environment
    return attachCommand(
        executablePath: executableURL.path,
        sessionID: sessionID,
        socketDirectory: sessionSocketDirectory(),
        remote: remote,
        ghosttyResourcesDir: env["GHOSTTY_RESOURCES_DIR"],
        inheritedZDOTDIR: env["ZDOTDIR"],
        shellPath: env["SHELL"]
    )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/swift-test.sh --filter AmxBackendAttachCommandTests 2>&1 | tail -20`
Expected: PASS, including the pre-existing `assemblesCommand` exact-string test (unchanged — it passes no `ghosttyResourcesDir`, so the token list is identical to before).

- [ ] **Step 5: Commit**

```bash
cd /Users/edequalsawesome/Development/awesomux-worktrees/debug-stutter-close-warning
git add Sources/awesoMux/Services/AmxBackend.swift Tests/awesoMuxTests/AmxBackendTests.swift
git commit -m "fix(bridge): inject zsh shell integration into daemon spawn"
```

---

### Task 2: Same tokens in the status overload; bridgeAttachCommand stays byte-identical

**Files:**
- Modify: `Sources/awesoMux/Services/AmxBackend.swift:339-365` (status overload) and the status `Bundle.main` wrapper (`:289-300`)
- Do NOT modify `bridgeAttachCommand` (`:566-607`): it requires a non-optional `RemoteTarget` (remote-only), and the local bridge path resolves through the ordinary wrappers (`CommandBridgeEnactor.swift:151`) — threading the parameters there would be dead API surface
- Test: `Tests/awesoMuxTests/AmxBackendTests.swift`, `Tests/awesoMuxTests/Bridge/BridgeAttachAssemblyTests.swift`

**Interfaces:**
- Consumes: `shellIntegrationEnvTokens(remote:ghosttyResourcesDir:inheritedZDOTDIR:shellPath:)` from Task 1.
- Produces: the status pure overload gains the same three trailing `String? = nil` parameters; its `Bundle.main` wrapper reads `ProcessInfo` exactly like Task 1's wrapper.

- [ ] **Step 1: Write the failing tests**

Append to `AmxBackendAttachCommandTests`:

```swift
@Test("status overload injects the same shell-integration tokens")
func statusOverloadInjectsShellIntegration() throws {
    let id = try #require(TerminalSessionID(rawValue: "abc123-zdotstatus"))
    let status = AmxBackend.makeStatusChannel()
    let command = try #require(AmxBackend.attachCommand(
        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
        sessionID: id,
        socketDirectory: "/tmp/amx",
        status: status,
        ghosttyResourcesDir: "/res/ghostty",
        shellPath: "/bin/zsh"
    ))
    #expect(command.contains("'ZDOTDIR=/res/ghostty/shell-integration/zsh'"))
}
```

In `Tests/awesoMuxTests/Bridge/BridgeAttachAssemblyTests.swift`, add (adapting to that suite's existing fixture helpers — read the file first; it covers `bridgeAttachCommand`):

```swift
@Test("bridgeAttachCommand never carries shell-integration tokens")
func bridgeAttachCommandStaysClean() throws {
    // Build a bridgeAttachCommand with the suite's existing fixtures and
    // assert !command.contains("ZDOTDIR") — it is remote-only by
    // construction and must remain byte-identical to the pre-change output.
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./script/swift-test.sh --filter 'AmxBackendAttachCommandTests|BridgeAttachAssembly' 2>&1 | tail -20`
Expected: compile FAILURE (`extra argument 'ghosttyResourcesDir'`) for the status overload; the bridge test fails or fails to compile depending on fixture shape.

- [ ] **Step 3: Implement**

Mirror Task 1 exactly in the status pure overload (`:339-365`): add the three parameters, insert `+ shellIntegrationEnvTokens(remote: remote, ghosttyResourcesDir: ghosttyResourcesDir, inheritedZDOTDIR: inheritedZDOTDIR, shellPath: shellPath)` between the `AMX_STATUS_TOKEN` token and the executable token. Update its `Bundle.main` wrapper (`:289-300`) to pass the three `ProcessInfo` values. Leave `bridgeAttachCommand` untouched.

- [ ] **Step 4: Run tests to verify they pass**

Run: `./script/swift-test.sh --filter 'AmxBackendAttachCommandTests|BridgeAttachAssembly' 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/awesoMux/Services/AmxBackend.swift Tests/awesoMuxTests/AmxBackendTests.swift Tests/awesoMuxTests/Bridge/BridgeAttachAssemblyTests.swift
git commit -m "fix(bridge): thread shell-integration env through status and bridge attach"
```

---

### Task 3: Full-suite verification and live smoke

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Full test suite**

Run: `./script/swift-test.sh 2>&1 | tail -30`
Expected: both the swift-testing AND XCTest summaries pass (check both — the final "passed" line covers swift-testing only).

- [ ] **Step 2: Formatter check on changed files**

Run: `./script/format.sh Sources/awesoMux/Services/AmxBackend.swift && git diff --stat`
Expected: no unexpected formatting churn; inspect any diff before proceeding.

- [ ] **Step 3: Live smoke — new daemon shell gets integration**

Build and run the dev app, then in a NEW bridged workspace's shell run:

```bash
echo "ZDOTDIR-now=[$ZDOTDIR]"; typeset -f | grep -c _ghostty || print "no ghostty funcs"
```

Expected: ghostty integration functions exist in the daemon-spawned zsh (`grep -c` ≥ 1) AND `ZDOTDIR-now` is restored — empty (or the user's own value), NOT stuck on the bundled `…/shell-integration/zsh` path. Then click the workspace X while idle at the prompt: NO "activity will be interrupted" dialog. IMPORTANT: existing daemons keep their pre-fix shells — only NEWLY created workspaces (fresh daemon spawns) prove the fix. Note this limitation in the PR body.

- [ ] **Step 4: Preflight and commit any doc note**

Run: `./script/preflight.sh 2>&1 | tail -15`
Expected: pass (a known pre-existing bash-3.2 `mapfile` exit-127 issue #24 may appear — check the test summary, cite the issue, move on).
