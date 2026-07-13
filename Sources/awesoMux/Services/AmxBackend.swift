import Foundation
import AwesoMuxCore
import os

// MARK: - AmxStatusChannel

/// Per-attach side-channel descriptor for the `amx` daemon lifecycle feed.
///
/// `fileURL` is the JSONL file the daemon writes lifecycle events to (minted
/// unique per attach so a respawn never appends to a stale file).  `token` is a
/// forgery-guard value exported into the attach environment; the daemon embeds it
/// in every emitted event so the reader can reject stale or mis-routed writes.
///
/// Both values are minted by `AmxBackend.makeStatusChannel(for:)` and injected
/// into the child environment by `AmxBackend.attachCommand(for:status:)` as
/// `AMX_STATUS_FILE` and `AMX_STATUS_TOKEN`.
struct AmxStatusChannel: Equatable {
    let fileURL: URL
    let token: String
}

// MARK: -

/// Locator for the bundled `amx` persistent-session backend (the vendored zmx,
/// see [ADR-0011](../../../docs/adr/0011-persistent-session-daemon-command-bridge.md)).
///
/// `amx` ships beside the main executable in `Contents/MacOS` (staged by
/// `script/build_and_run.sh`). The command-bridge spawns `amx attach <id>` as a
/// surface's child instead of a login shell; `amx` is also the awesoMux-owned
/// seam for daemon queries (cwd, idle/`wait`, history) that should be sourced
/// out-of-band rather than scraped from forwarded OSC.
///
/// This type is intentionally just the locator; the attach/list/wait/history
/// command surface and the `TerminalSessionID` mapping land with the bridge
/// implementation (INT-561 Increment 2).
enum AmxBackend {
    static let executableName = "amx"
    private static let envExecutablePath = "/usr/bin/env"
    private static let establishedMetadataRawValue = "amx:v1:established"
    /// 0700 so the socket dir is user-only (zmx's default is 0750, group-readable).
    private static let socketDirectoryMode = "700"
    /// Inherited zmx control vars that must not leak into the bridge — `ZMX_DIR`
    /// and `ZMX_DIR_MODE` are set explicitly below, so only these are scrubbed.
    private static let scrubbedEnvironmentKeys: Set<String> = [
        "ZMX_SESSION",
        "ZMX_SESSION_PREFIX",
        "ZMX_LOG_MODE"
    ]

    /// Dedicated, per-user socket directory for awesoMux's daemons. Because
    /// `amx list`/`amx kill` are scoped to `ZMX_DIR`, GC can only ever see — and
    /// reap — daemons awesoMux itself created here; a user's hand-run `zmx`/`amx`
    /// sessions live in zmx's default dir and are invisible to us by construction.
    ///
    /// Placed directly under `$TMPDIR` (per-user, not world-writable — no `/tmp`
    /// squatting) and kept short on purpose: the socket path is `dir + "/" + name`
    /// and must fit `sockaddr_un` (~103 bytes on macOS). Under `$TMPDIR` the name
    /// budget stays ≥ the 46-byte `TerminalSessionID` cap, so UUID ids always fit.
    static func sessionSocketDirectory() -> String {
        cachedSocketDirectory
    }

    /// Computed once: `$TMPDIR` is process-stable, so re-deriving the path on
    /// every spawn just churns string work on the bridge hot path.
    private static let cachedSocketDirectory: String = AppRuntimeProfile.current.amxSocketDirectoryPath

    /// Dedicated directory for ssh ControlMaster sockets — deliberately NOT the
    /// amx/zmx socket dir, which `amx list`/GC enumerate (a foreign %C socket
    /// there pollutes session state).
    ///
    /// Must be SHORT: `$TMPDIR` (`/var/folders/<hash>/T/…` = 60 bytes) leaves the
    /// final ControlPath at 102 bytes — under the 104-byte sockaddr_un limit, but
    /// ssh's `muxserver_listen` binds a *temporary* socket at `ControlPath` + `.`
    /// + 16 random chars first, which overflows to 119 bytes, so `unix_listener`
    /// fails and ssh exits with no session at all (INT-766). A short `/tmp` dir
    /// keeps the whole budget — dir + `/%C` + `.tmpsuffix` + NUL — well under 104.
    ///
    /// SECURITY: the socket placed here grants master access to the authenticated
    /// ssh connection (remote command execution), so the directory must not be
    /// hijackable. The dir is STABLE and lives under `$HOME` (`~/.awesomux/ssh`,
    /// OpenSSH's own `ControlPath ~/.ssh/sockets/%C` convention): unlike the
    /// earlier per-launch `mkdtemp` under world-writable `/tmp`, the parent is
    /// user-owned, so no other local user can pre-create or symlink the path.
    /// Stability is load-bearing, not just tidy (INT-698 live-smoke finding #8):
    /// a reattached pane's inner ssh — held alive by the persistent local zmx
    /// session — rides the ControlPath it was SPAWNED with. With a per-launch
    /// random dir, a relaunched app's bridge preflight forwarded through a fresh
    /// throwaway master that idled out at `ControlPersist=60` and silently took
    /// the forward (and the bridge) with it. One stable path means every launch,
    /// reattach, and preflight converge on the same `%C` master.
    ///
    /// Creation still verifies before trusting (lstat: real dir, not a symlink,
    /// owned by us, no group/world bits) and falls back to the old `mkdtemp`
    /// primitive on any doubt — degraded-but-safe, exactly the posture the
    /// mkdtemp design had.
    static func sshControlDirectory() -> String {
        cachedSSHControlDirectory
    }

    private static let cachedSSHControlDirectory: String = {
        let stable = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".awesomux/" + AppRuntimeProfile.current.sshControlDirectoryName)
        try? FileManager.default.createDirectory(
            atPath: stable, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory is a no-op on an existing path (it never re-applies
        // 0700 or checks what the path IS), so verify before trusting: a real
        // directory, not a symlink, owned by this uid, no group/world access.
        var status = stat()
        if lstat(stable, &status) == 0,
           (status.st_mode & S_IFMT) == S_IFDIR,
           status.st_uid == geteuid(),
           (status.st_mode & 0o077) == 0 {
            return stable
        }

        // Verification failed (hostile or corrupted `~/.awesomux`): fall back to
        // the unpredictable per-launch primitive. Bridge forwards won't survive
        // an app relaunch in this mode (finding #8), but the transport is safe —
        // which is the priority when $HOME itself can't be trusted.
        var template = Array("/tmp/awesomux-ssh-XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        if let created {
            return created
        }
        // mkdtemp failed too (e.g. /tmp unwritable): the OS-isolated per-user
        // `$TMPDIR`. It may be long enough that the sockaddr_un guard below
        // trips and ssh drops the shared ControlMaster — but that degradation
        // is safe, which is the priority when both $HOME and /tmp are broken.
        let fallback = (NSTemporaryDirectory() as NSString).appendingPathComponent("awesomux-ssh")
        try? FileManager.default.createDirectory(
            atPath: fallback, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return fallback
    }()

    /// macOS `sockaddr_un.sun_path` is 104 bytes, NUL-terminated (`<sys/un.h>`).
    /// Past that budget ssh does NOT degrade gracefully: setting up the
    /// ControlMaster fails and the whole `ControlMaster=auto` session exits
    /// without opening a shell (INT-766). `%C` expands to a fixed 40-char hex
    /// connection hash, and — critically — `muxserver_listen` first binds a
    /// TEMPORARY path of `ControlPath` + `.` + 16 random chars (17 bytes) before
    /// renaming to the final path, so the budget must reserve that suffix too or
    /// a ControlPath that "fits" still overflows during master setup.
    private static let sshControlPathHashWidth = 40
    /// `.` + 16 random chars appended by OpenSSH `muxserver_listen` for the
    /// pre-rename temporary control socket. Must be reserved in the budget.
    private static let sshControlPathTempSuffixWidth = 17
    /// Shared with `BridgeChannel`'s remote-socket-path budget check — one
    /// definition of the macOS `sockaddr_un` limit, not two drifting copies.
    static let sockaddrUnPathLimit = 104
    private static let logger = Logger(
        subsystem: "awesomux.amx",
        category: "ssh-control-path"
    )
    private static let diagnosticsProcessRunner = BoundedCommandRunner(
        executableCandidates: ["/bin/ps"],
        timeout: .seconds(2),
        maxOutputBytes: 4 * 1024 * 1024,
        environment: [:]
    )

    /// ControlMaster socket path for remote panes. `%C` (ssh's 40-char
    /// connection hash) is fixed-length and fits the sockaddr_un budget in the
    /// short dedicated dir above.
    static func sshControlPath() -> String {
        let directory = sshControlDirectory()
        // +1 separator, + the pre-rename temp suffix ssh actually binds, +1 NUL.
        let estimatedLength = directory.utf8.count + 1
            + sshControlPathHashWidth + sshControlPathTempSuffixWidth + 1
        if estimatedLength > sockaddrUnPathLimit {
            logger.warning(
                "ssh ControlPath temp-socket length \(estimatedLength, privacy: .public) exceeds the \(Self.sockaddrUnPathLimit, privacy: .public)-byte sockaddr_un limit; ControlMaster setup will fail and remote panes will not open"
            )
            // ponytail: fail loud in dev where it's cheap to notice; never
            // crash a release build — a warning plus the degraded path beats a
            // crash, and the short /tmp dir keeps this branch unreachable.
            #if DEBUG
            assertionFailure("ssh ControlPath is too long for sockaddr_un — shorten sshControlDirectory()")
            #endif
        }
        return "\(directory)/%C"
    }

    /// `env -u` tokens shared by both attach-command overloads. The ZMX
    /// control vars and the `AMX_STATUS_*` pair are scrubbed on every attach:
    /// an awesoMux launched from inside another awesoMux pane inherits the
    /// parent instance's status file *and* its matching forgery token, and
    /// without the scrub a status-less attach would hand the daemon a stale
    /// pair that validates against the wrong instance. (In the status
    /// overload the scrub is followed by fresh assignments — `env` applies
    /// `-u` flags before `NAME=VALUE` arguments, so the assignment wins.)
    ///
    /// The `AWESOMUX_*` pane-scoped keys are scrubbed only when the attach
    /// crosses ssh (spec "Security analysis": "the ssh command scrubs
    /// AWESOMUX_AGENT_EVENT_FILE, AWESOMUX_AGENT_*, and AMX_STATUS_*" —
    /// stripping the local ssh client's environment is what stops a
    /// promiscuous `SendEnv` from ever transmitting the local event channel).
    /// They must NOT be scrubbed for a local attach: the pane shell the
    /// daemon spawns inherits its environment through this very command, and
    /// the local agent hook reads `AWESOMUX_AGENT_EVENT_FILE` (and the
    /// health check requires the full pane-scoped set) from that inherited
    /// environment — an unconditional scrub would sever the local agent
    /// side channel. `env -u` takes exact names only — no globs — so the
    /// spec's `AWESOMUX_AGENT_*` is enumerated via
    /// `AgentRuntimeEnvironmentKey.paneScopedKeys`, the app's own definition
    /// of every pane-scoped key it injects (a future key added there is
    /// scrubbed here automatically).
    private static func environmentScrubTokens(remote: RemoteTarget?) -> [String] {
        var tokens = [
            "-u ZMX_SESSION",
            "-u ZMX_SESSION_PREFIX",
            "-u ZMX_LOG_MODE",
            "-u AMX_STATUS_FILE",
            "-u AMX_STATUS_TOKEN"
        ]
        if remote != nil {
            tokens += AgentRuntimeEnvironmentKey.paneScopedKeys.map { "-u \($0)" }
        }
        return tokens
    }

    /// The `ssh` tokens appended after `attach <id>` for a remote pane. Each
    /// token is shell-quoted by the caller. Transport only — no credentials
    /// (ADR-0022).
    private static func sshTailTokens(
        for remote: RemoteTarget,
        remoteCommand: String? = nil
    ) -> [String] {
        var tokens = [
            "ssh",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=" + sshControlPath(),
            "-o", "ControlPersist=60",
            "-o", "ServerAliveInterval=15"
        ]
        if remoteCommand != nil {
            // Supplying a command disables ssh's automatic TTY allocation.
            // The managed session must remain an interactive login shell, so
            // force a remote PTY when the bridge injects its env wrapper.
            tokens.append("-t")
        }
        tokens.append("--")
        tokens.append(remote.sshDestination)
        if let remoteCommand {
            tokens.append(remoteCommand)
        }
        return tokens
    }

    /// The backend ships beside the app's main executable in `Contents/MacOS`,
    /// the same convention as `awesoMuxAgentHook`.
    static func bundledExecutableURL() -> URL? {
        cachedBundledExecutableURL
    }

    /// Resolved once at first use. The bundle layout can't change in-place for a
    /// running .app — Sparkle-style updates relaunch the process — so the
    /// `isExecutableFile` stat is wasted work to repeat on every `queryCwd`.
    private static let cachedBundledExecutableURL: URL? = {
        guard let url = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent(executableName),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return nil
        }
        return url
    }()

    static func attachCommand(for sessionID: TerminalSessionID, remote: RemoteTarget? = nil) -> String? {
        guard let executableURL = bundledExecutableURL() else {
            return nil
        }
        return attachCommand(
            executablePath: executableURL.path,
            sessionID: sessionID,
            socketDirectory: sessionSocketDirectory(),
            remote: remote
        )
    }

    /// Attach command with a per-attach status side-channel. Resolves the bundled
    /// executable and delegates to the injectable overload.
    static func attachCommand(for sessionID: TerminalSessionID, status: AmxStatusChannel, remote: RemoteTarget? = nil) -> String? {
        guard let executableURL = bundledExecutableURL() else {
            return nil
        }
        return attachCommand(
            executablePath: executableURL.path,
            sessionID: sessionID,
            socketDirectory: sessionSocketDirectory(),
            status: status,
            remote: remote
        )
    }

    /// Pure assembly of the `/bin/sh -c` string libghostty runs for the bridge.
    /// Split out from `bundledExecutableURL()` so the security-sensitive shell
    /// construction — the zmx control-env scrub, the explicit `ZMX_DIR` pin,
    /// single-quote escaping, and the defense-in-depth id revalidation — is
    /// unit-testable without a real `amx` beside the test runner. Returns nil if
    /// the id fails validation (it can't via a constructed `TerminalSessionID`,
    /// but the guard is the last line if that invariant ever regresses).
    static func attachCommand(
        executablePath: String,
        sessionID: TerminalSessionID,
        socketDirectory: String,
        remote: RemoteTarget? = nil
    ) -> String? {
        guard TerminalSessionID.isValid(sessionID.rawValue) else {
            return nil
        }

        var tokens = [shellQuote(envExecutablePath)]
            + environmentScrubTokens(remote: remote)
            + [
                shellQuote("ZMX_DIR=" + socketDirectory),
                shellQuote("ZMX_DIR_MODE=" + socketDirectoryMode),
                shellQuote(executablePath),
                "attach",
                shellQuote(sessionID.rawValue)
            ]
        if let remote {
            tokens += sshTailTokens(for: remote).map(shellQuote)
        }
        return tokens.joined(separator: " ")
    }

    /// Pure assembly of the attach command with `AMX_STATUS_FILE` and
    /// `AMX_STATUS_TOKEN` injected so the daemon can write lifecycle events
    /// to the minted side-channel file. The security guarantees of the base
    /// overload (env scrub, ZMX_DIR pin, single-quote escaping, id revalidation)
    /// are fully preserved — this overload is additive only.
    static func attachCommand(
        executablePath: String,
        sessionID: TerminalSessionID,
        socketDirectory: String,
        status: AmxStatusChannel,
        remote: RemoteTarget? = nil
    ) -> String? {
        guard TerminalSessionID.isValid(sessionID.rawValue) else {
            return nil
        }

        var tokens = [shellQuote(envExecutablePath)]
            + environmentScrubTokens(remote: remote)
            + [
                shellQuote("ZMX_DIR=" + socketDirectory),
                shellQuote("ZMX_DIR_MODE=" + socketDirectoryMode),
                shellQuote("AMX_STATUS_FILE=" + status.fileURL.path),
                shellQuote("AMX_STATUS_TOKEN=" + status.token),
                shellQuote(executablePath),
                "attach",
                shellQuote(sessionID.rawValue)
            ]
        if let remote {
            tokens += sshTailTokens(for: remote).map(shellQuote)
        }
        return tokens.joined(separator: " ")
    }

    /// Mints a fresh per-attach status side-channel and pre-creates its file.
    ///
    /// The file path is unique per call (token bytes embedded in the name) so a
    /// respawn never appends to a stale file. The token is 16 bytes of
    /// crypto-random data expressed as a 32-char lowercase hex string — no
    /// shell-special characters.
    ///
    /// Returns nil if the file can't be created securely. We pre-create it via
    /// `AgentRuntimeEventFile.prepare(at:)` — `O_CREAT | O_EXCL`, owner
    /// validation, `fchmod 0600` on the descriptor — for two reasons:
    /// (1) it closes a same-UID pre-squat/forge window before the daemon opens
    /// the path, and (2) the watcher's `O_EVTONLY` arm silently no-ops on a
    /// missing file, so at attach time (before the daemon writes anything) the
    /// watcher would never arm and the session would lose its status feed. With
    /// the file present up front the watcher always arms. nil → the caller
    /// attaches without a status channel and falls back to the legacy exit path.
    static func makeStatusChannel(for sessionID: TerminalSessionID) -> AmxStatusChannel? {
        // 16 bytes = two random UInt64 values → 32 hex chars.
        var rng = SystemRandomNumberGenerator()
        let hi = UInt64.random(in: .min ... .max, using: &rng)
        let lo = UInt64.random(in: .min ... .max, using: &rng)
        let token = String(format: "%016llx%016llx", hi, lo)
        // Embed a token prefix in the filename so the file is unique per attach.
        let filename = "\(sessionID.rawValue)-\(token.prefix(8)).status.jsonl"
        let fileURL = URL(fileURLWithPath: sessionSocketDirectory())
            .appendingPathComponent(filename)
        guard AgentRuntimeEventFile.prepare(at: fileURL) else {
            return nil
        }
        return AmxStatusChannel(fileURL: fileURL, token: token)
    }

    // MARK: - Bridge attach assembly (INT-698 D1)

    /// The exec-channel command's result: a shell command to run over the
    /// shared ControlMaster and the JSON payload to pipe on its **stdin**.
    /// Declared as a value (not executed here) so the caller — the attach
    /// sequence, which owns the injected exec-channel closure — decides how
    /// and when to actually open the channel; this type only describes what
    /// to run and what to feed it.
    struct BridgeStateFileWrite: Sendable, Equatable {
        let command: String
        let stdinData: Data
    }

    /// Protocol string this app build offers in the bridge state file's
    /// `proto` field. Declared independently from
    /// `BridgeConnectionSupervisor.supportedProtocols` for the same reason
    /// that type documents: the wire is the contract, not shared Swift code.
    static let bridgeProtocolVersion = "awesomux-bridge-v1"

    /// Pure assembly of the exec-channel command that atomically replaces
    /// the remote bridge state file (spec: "The bridge state file"). Secrets
    /// (`token`, the current `socket`) travel on **stdin**, never argv or a
    /// remote command line; the temp name is a fresh 8-byte-random suffix
    /// per call — never a shared fixed `.tmp` name — so two overlapping
    /// writers for different attaches can never corrupt each other's temp
    /// file. Returns nil only if `channel.stateFilePath` isn't absolute,
    /// which `BridgeChannel.mint` already guarantees for any channel this
    /// app minted itself.
    static func bridgeStateFileWriteCommand(
        controlPath: String,
        remote: RemoteTarget,
        channel: BridgeChannel
    ) -> BridgeStateFileWrite? {
        guard channel.stateFilePath.hasPrefix("/") else {
            return nil
        }
        let stateFile = BridgeStateFile(
            proto: bridgeProtocolVersion,
            gen: channel.gen,
            socket: channel.remoteSocketPath,
            token: channel.token
        )
        // `BridgeStateFile` is a flat String/Int struct — encode failure has
        // no realistic path; `try?` just folds the impossible case into the
        // same nil as the path-shape guard above rather than pretending it
        // deserves its own error channel.
        guard let stdinData = try? JSONEncoder().encode(stateFile) else {
            return nil
        }

        // mkdir targets the state file's own parent, not a `~` respelling:
        // the spec's `~` is display shorthand for the captured absolute home,
        // and re-expanding `~` remotely could diverge from the captured value
        // (the state file would land in a directory nobody created).
        let bridgeDirectory = (channel.stateFilePath as NSString).deletingLastPathComponent
        let quotedDirectory = shellQuote(bridgeDirectory)
        let remoteScript = "umask 077; mkdir -p " + quotedDirectory
            + " && owner=$(stat -f '%u' " + quotedDirectory + ")"
            + " && mode=$(stat -f '%Lp' " + quotedDirectory + ")"
            + " && [ \"$owner\" = \"$(id -u)\" ] && [ \"$mode\" = 700 ]"
            + " && tmp=$(mktemp " + shellQuote(bridgeDirectory + "/.bridge-state.XXXXXXXX") + ")"
            + " && trap 'rm -f \"$tmp\"' EXIT HUP INT TERM"
            + " && cat > \"$tmp\" && chmod 600 \"$tmp\""
            + " && mv \"$tmp\" " + shellQuote(channel.stateFilePath)
            + " && trap - EXIT HUP INT TERM"
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            // `--` ends option parsing so a destination that begins with `-`
            // (a hostile saved target like `-oProxyCommand=…`) can never be
            // read as an ssh option — the ADR-0021 submitted-target lesson.
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(remoteScript)
        ]
        return BridgeStateFileWrite(command: tokens.joined(separator: " "), stdinData: stdinData)
    }

    /// ssh options for bridge EXEC-channel commands (home resolution,
    /// state-file write, admission, socket remove, helper version/self-check).
    /// Unlike the bare `-S` control operations (`-O forward`/`-O cancel`, which
    /// REQUIRE a live master), exec commands must be able to ESTABLISH the
    /// shared master when none exists: without `ControlMaster=auto`, an attach
    /// that begins with no live master (reconnect after master death — the
    /// live-smoke gate-9 failure) rides a direct fallback connection for the
    /// `$HOME` resolution, and the subsequent `-O forward` finds no master and
    /// the preflight permanently degrades. Flags mirror `sshTailTokens` (the
    /// attach path's exact persistence posture), minus the destination.
    private static let bridgeExecMasterOptionTokens = [
        "-o", "ControlMaster=auto",
        "-o", "ControlPersist=60",
        "-o", "ServerAliveInterval=15"
    ]

    /// Pure assembly of the one-time exec-channel command that resolves the
    /// remote `$HOME` (spec: "the one-time $HOME capture"), so the caller
    /// can inject `AWESOMUX_BRIDGE_STATE` as a fully resolved absolute path —
    /// helpers never expand `~` themselves. This probe is deliberately read-only:
    /// an unmanaged target without the installed helper must not be mutated just
    /// because the user opened a remote pane. The later state-file publish creates
    /// the bridge directory only after helper compatibility is confirmed. Callers
    /// resolve this exactly once (per host, or per process) and reuse the value for
    /// every subsequent
    /// `BridgeChannel.mint`; re-running it on every attach would still be
    /// correct (idempotent) but is wasted round trips.
    static func bridgeHomeResolutionCommand(controlPath: String, remote: RemoteTarget) -> String {
        let remoteScript = #"printf '%s' "$HOME""#
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            // See bridgeStateFileWriteCommand: `--` stops a `-`-prefixed
            // destination from being parsed as an ssh option.
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(remoteScript)
        ]
        return tokens.joined(separator: " ")
    }

    /// Pure assembly of the non-secret `env` prefix the spec's "Environment
    /// injected at session creation" table names — EXACTLY
    /// `AWESOMUX_BRIDGE_STATE`/`_SESSION`/`_HELPER` — prepended to whatever
    /// remote command actually runs on the far host (`$SHELL -l` or
    /// `zmx attach <remote-id>`, ADR-0023 §2). The per-attach secrets
    /// (token, socket) deliberately never appear here; they reach the remote
    /// only through the state file (`bridgeStateFileWriteCommand`), on
    /// stdin — this prefix carries only creation-stable, non-secret values.
    ///
    /// `remoteCommand` is deliberately NOT shell-quoted: it is an
    /// already-composed multi-token command line (`zmx attach <id>`, not one
    /// argv element), and quoting it would make `env` exec a single program
    /// literally named "zmx attach <id>". Callers own escaping any variable
    /// text inside it.
    static func bridgeEnvironmentPrefixedRemoteCommand(
        stateFilePath: String,
        session: TerminalSessionID,
        helperPath: String,
        remoteCommand: String
    ) -> String {
        let tokens = [
            shellQuote(envExecutablePath),
            // Belt-and-braces remote scrub of the LOCAL status pair. The outer
            // ssh attach command (`attachCommand`) already `-u`-scrubs these on
            // the crossing, but this prefix composes the remote-session command
            // independently, and a user `SendEnv AMX_STATUS_*` + server
            // `AcceptEnv AMX_STATUS_*` could still inject the local file/token
            // into the far session's environment. `env -u` strips them from
            // whatever this command inherits regardless of how they arrived, so
            // a remote agent can never read the local status channel's path or
            // forge its token. Exact names only — `env -u` cannot glob.
            "-u AMX_STATUS_FILE",
            "-u AMX_STATUS_TOKEN",
            shellQuote("AWESOMUX_BRIDGE_STATE=" + stateFilePath),
            shellQuote("AWESOMUX_BRIDGE_SESSION=" + session.rawValue),
            shellQuote("AWESOMUX_BRIDGE_HELPER=" + helperPath)
        ]
        return (tokens + [remoteCommand]).joined(separator: " ")
    }

    /// Builds the full local `amx attach ... ssh ...` command for a bridge-ready
    /// managed pane. Unlike `bridgeEnvironmentPrefixedRemoteCommand` alone,
    /// this places the env wrapper *after* the SSH destination so it executes
    /// on the managed target. Prefixing the local `amx` process only sets the
    /// variables on the SSH client; OpenSSH does not forward arbitrary client
    /// environment variables to the server.
    static func bridgeAttachCommand(
        executablePath: String,
        sessionID: TerminalSessionID,
        socketDirectory: String,
        status: AmxStatusChannel?,
        remote: RemoteTarget,
        stateFilePath: String,
        helperPath: String
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
        if let status {
            tokens += [
                shellQuote("AMX_STATUS_FILE=" + status.fileURL.path),
                shellQuote("AMX_STATUS_TOKEN=" + status.token)
            ]
        }
        tokens += [
            shellQuote(executablePath),
            "attach",
            shellQuote(sessionID.rawValue)
        ]

        let remoteShell = bridgeEnvironmentPrefixedRemoteCommand(
            stateFilePath: stateFilePath,
            session: sessionID,
            helperPath: helperPath,
            // `env` execs the expanded shell path directly. `exec` itself is a
            // shell builtin, not an executable, and would make env exit 127.
            remoteCommand: "\"$SHELL\" -l"
        )
        tokens += sshTailTokens(for: remote, remoteCommand: remoteShell).map(shellQuote)
        return tokens.joined(separator: " ")
    }

    static func bridgeAttachCommand(
        for sessionID: TerminalSessionID,
        status: AmxStatusChannel?,
        remote: RemoteTarget,
        stateFilePath: String,
        helperPath: String
    ) -> String? {
        guard let executableURL = bundledExecutableURL() else {
            return nil
        }
        return bridgeAttachCommand(
            executablePath: executableURL.path,
            sessionID: sessionID,
            socketDirectory: sessionSocketDirectory(),
            status: status,
            remote: remote,
            stateFilePath: stateFilePath,
            helperPath: helperPath
        )
    }

    /// Establishes the per-attach reverse forward against the shared
    /// ControlMaster (spec "Socket lifecycle": `-O forward` is unambiguous
    /// about master ownership, unlike a slave-side `-R`). Pairs with
    /// `bridgeReverseForwardCancelCommand` on teardown.
    static func bridgeReverseForwardCommand(
        controlPath: String,
        remote: RemoteTarget,
        channel: BridgeChannel
    ) -> String {
        reverseForwardControlCommand(
            controlPath: controlPath,
            remote: remote,
            operation: "forward",
            remoteSocketPath: channel.remoteSocketPath,
            localSocketPath: channel.localSocketPath
        )
    }

    /// Cancels a previously-established reverse forward by its exact
    /// `remote:local` socket pair (spec "Socket lifecycle"). Callers treat a
    /// nonzero exit as a no-op, not an error (master already gone, or an
    /// OpenSSH that rejects the cancel — "Cancellation failure is modeled").
    static func bridgeReverseForwardCancelCommand(
        controlPath: String,
        remote: RemoteTarget,
        remoteSocketPath: String,
        localSocketPath: String
    ) -> String {
        reverseForwardControlCommand(
            controlPath: controlPath,
            remote: remote,
            operation: "cancel",
            remoteSocketPath: remoteSocketPath,
            localSocketPath: localSocketPath
        )
    }

    /// Raw-path variant of `bridgeReverseForwardCommand` for a throwaway probe
    /// that has no `BridgeChannel` (the doctor's empirical reverse-forward
    /// check, INT-698 F1). Mirrors the cancel/remove builders, which already
    /// take loose socket paths rather than a channel.
    static func bridgeReverseForwardCommand(
        controlPath: String,
        remote: RemoteTarget,
        remoteSocketPath: String,
        localSocketPath: String
    ) -> String {
        reverseForwardControlCommand(
            controlPath: controlPath,
            remote: remote,
            operation: "forward",
            remoteSocketPath: remoteSocketPath,
            localSocketPath: localSocketPath
        )
    }

    private static func reverseForwardControlCommand(
        controlPath: String,
        remote: RemoteTarget,
        operation: String,
        remoteSocketPath: String,
        localSocketPath: String
    ) -> String {
        // `-O <op>` is a control command to the master named by `-S`; `-R` adds
        // (or, with cancel, removes) the StreamLocal reverse forward. The
        // `remote:local` pair is a single ssh argument.
        let spec = shellQuote(remoteSocketPath + ":" + localSocketPath)
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath),
            "-O", operation,
            "-R", spec,
            // See bridgeStateFileWriteCommand: `--` stops a `-`-prefixed
            // destination from being read as an ssh option (ADR-0021).
            "--",
            shellQuote(remote.sshDestination)
        ]
        return tokens.joined(separator: " ")
    }

    /// Removes exactly one remote socket file by its exact path — never a glob
    /// (spec "Socket lifecycle": the socket ledger is the only deletion
    /// authority; no `find … -delete` over the shared `/tmp` prefix, ever).
    static func bridgeRemoteSocketRemoveCommand(
        controlPath: String,
        remote: RemoteTarget,
        remoteSocketPath: String
    ) -> String {
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            "--",
            shellQuote(remote.sshDestination),
            "rm", "-f", shellQuote(remoteSocketPath)
        ]
        return tokens.joined(separator: " ")
    }

    /// Removes exactly one remote bridge STATE FILE by its exact minted path
    /// (INT-698 live-smoke finding #7): teardown previously cancelled the
    /// forward and removed the socket but left `~/.awesomux/bridge/<session>.json`
    /// behind forever on every clean pane close — not the spec's accepted
    /// crash-leak. Same exact-path/no-glob discipline as the socket removal.
    ///
    /// The delete is GUARDED on generation identity (adversarial-review
    /// finding): the state path is per-SESSION, shared with any successor
    /// re-mint, and teardown's ssh round trips suspend long enough for a
    /// close-then-reopen successor to publish at the same path — an
    /// unconditional `rm` would then delete the successor's live file and
    /// silently kill its bridge until the next attach. `grep -qsF` for this
    /// generation's unique socket BASENAME (never the full path: JSONEncoder
    /// escapes `/` as `\/` inside the file, and the basename is slash-free
    /// and per-mint unique) makes the delete a no-op once a successor owns
    /// the file. The basename is already argv-visible in the cancel/rm
    /// commands, so the guard leaks nothing new.
    static func bridgeStateFileRemoveCommand(
        controlPath: String,
        remote: RemoteTarget,
        stateFilePath: String,
        remoteSocketPath: String
    ) -> String {
        let socketBasename = (remoteSocketPath as NSString).lastPathComponent
        let quotedState = shellQuote(stateFilePath)
        let script = "grep -qsF -- \(shellQuote(socketBasename)) \(quotedState)"
            + " && rm -f -- \(quotedState)"
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(script)
        ]
        return tokens.joined(separator: " ")
    }

    /// Owner-only admission probe (spec attach sequence, step 3): stats the
    /// just-bound remote socket over the exec channel. `[ -O ]` is true only
    /// when the socket's owner is this ssh session's own user — the spec's
    /// "owner = session user" without the app needing to know the remote uid.
    /// The two `stat` spellings cover GNU (`-c %a`) and BSD (`-f %Lp`); the
    /// first that succeeds prints the octal mode, which `bridgeAdmissionPassed`
    /// then checks for owner-only bits.
    static func bridgeRemoteSocketAdmissionCommand(
        controlPath: String,
        remote: RemoteTarget,
        remoteSocketPath: String
    ) -> String {
        let quoted = shellQuote(remoteSocketPath)
        let script = "if [ -S \(quoted) ] && [ -O \(quoted) ]; then "
            + "stat -c %a \(quoted) 2>/dev/null || stat -f %Lp \(quoted) 2>/dev/null; fi"
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(script)
        ]
        return tokens.joined(separator: " ")
    }

    /// Parses `bridgeRemoteSocketAdmissionCommand`'s stdout: admission passes
    /// only when the socket exists, is owned by the session user (the command
    /// emits nothing otherwise), AND its mode carries no group/world bits.
    /// Empty/garbled output fails closed — the standing fail-open-to-no-bridge
    /// posture means a rejected admission just degrades this attach.
    static func bridgeAdmissionPassed(statOutput: String) -> Bool {
        guard let line = statOutput
            .split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
            let mode = Int(line, radix: 8)
        else {
            return false
        }
        return mode & 0o077 == 0
    }

    /// Runs the installed remote helper's `--version` over the shared master so
    /// the doctor can intersect its advertised proto set against the app's
    /// (INT-698 F1, spec "Doctor integration"). `--version` needs no bridge env
    /// — it only prints the protocols this helper build understands.
    static func bridgeHelperVersionCommand(
        controlPath: String,
        remote: RemoteTarget,
        helperPath: String
    ) -> String {
        let remoteScript = shellQuote(helperPath) + " --version"
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            // See bridgeStateFileWriteCommand: `--` stops a `-`-prefixed
            // destination from being parsed as an ssh option (ADR-0021).
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(remoteScript)
        ]
        return tokens.joined(separator: " ")
    }

    /// Runs the remote helper's `--self-check` over the shared master (INT-698
    /// F1). The helper reads the bridge state file under its custody rules and
    /// attempts one handshake, so its exit code reports both the state-file
    /// custody and the round-trip signals. The bridge env prefix (identical to
    /// the attach path's, secrets NEVER included — only the creation-stable
    /// path/session/helper values) points the helper at the published state
    /// file; the exec channel discards stderr, so the app consumes only the
    /// exit code, never the terse message contents.
    static func bridgeHelperSelfCheckCommand(
        controlPath: String,
        remote: RemoteTarget,
        helperPath: String,
        stateFilePath: String,
        session: TerminalSessionID
    ) -> String {
        let remoteScript = bridgeEnvironmentPrefixedRemoteCommand(
            stateFilePath: stateFilePath,
            session: session,
            helperPath: helperPath,
            remoteCommand: shellQuote(helperPath) + " --self-check"
        )
        let tokens = [
            "ssh",
            "-S", shellQuote(controlPath)
        ] + bridgeExecMasterOptionTokens + [
            "--",
            shellQuote(remote.sshDestination),
            shellQuote(remoteScript)
        ]
        return tokens.joined(separator: " ")
    }

    /// Queries the current working directory of the running daemon by running
    /// `amx cwd <sessionID>`. Returns the first nonempty trimmed line of stdout,
    /// or nil on empty output, nonzero exit, timeout, or missing binary.
    static func queryCwd(_ sessionID: TerminalSessionID) async -> String? {
        guard TerminalSessionID.isValid(sessionID.rawValue),
              let executableURL = bundledExecutableURL() else {
            return nil
        }
        let runner = BoundedCommandRunner(
            executableCandidates: [executableURL.path],
            timeout: .seconds(1),
            maxOutputBytes: 4 * 1024,
            environment: bridgeProcessEnvironment()
        )
        guard let data = await runner.run(
            arguments: ["cwd", sessionID.rawValue],
            inDirectory: FileManager.default.currentDirectoryPath
        ), let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Self.parseCwdOutput(output)
    }

    /// Extracts the cwd from raw `amx cwd` stdout.
    ///
    /// Returns the first nonempty line after trimming whitespace, or nil when
    /// the output is empty or whitespace-only. Extracted as a pure helper so it
    /// can be unit-tested without spawning the binary.
    ///
    /// The result flows to `updatePane` and a Finder reveal, so validate it as a
    /// plausible absolute path: an absolute prefix (relative paths are
    /// meaningless without the daemon's cwd), a sane length bound, no embedded
    /// NUL (which would truncate a C path downstream), and no bidi/zero-width
    /// codepoints (a click-to-open resolver now consumes this as a trusted
    /// base). A malformed line — daemon error text, a partial write — yields
    /// nil rather than a bogus cwd.
    static func parseCwdOutput(_ raw: String) -> String? {
        guard let candidate = raw.split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }
        guard candidate.hasPrefix("/"),
              candidate.utf8.count <= 1024,
              !candidate.contains("\0") else {
            return nil
        }
        // A cwd carrying bidi/zero-width codepoints is either corrupt or
        // hostile; reject so this function's "plausible path" contract holds
        // for every caller, not just ones that re-fence.
        guard !MarkdownLinkIntercept.containsUnsafePathScalars(candidate) else {
            return nil
        }
        return candidate
    }

    static func sessionExists(_ sessionID: TerminalSessionID) async -> Bool {
        guard let executableURL = bundledExecutableURL() else {
            return false
        }

        let runner = BoundedCommandRunner(
            executableCandidates: [executableURL.path],
            timeout: .seconds(1),
            // `list --short` output scales with the live-session count (~47 bytes
            // per ID line). Match `listSessions`'s 1 MB headroom so a large
            // session set can't truncate the list and make a live session read
            // as absent — which the legacy fallback would treat as a dead daemon
            // and respawn unnecessarily.
            maxOutputBytes: 1024 * 1024,
            environment: bridgeProcessEnvironment()
        )
        guard let data = await runner.run(
            arguments: ["list", "--short"],
            inDirectory: FileManager.default.currentDirectoryPath
        ),
              let output = String(data: data, encoding: .utf8) else {
            return false
        }

        return output.split(whereSeparator: \.isNewline)
            .contains { $0 == sessionID.rawValue }
    }

    /// Verbose `amx list`, parsed into `LiveDaemon`s. Empty on any failure —
    /// GC is best-effort cleanup, never launch-critical.
    static func listSessions() async -> [LiveDaemon] {
        await listSessionsResult() ?? []
    }

    /// Diagnostics needs to distinguish an empty daemon list from an unavailable
    /// `amx` query so it can keep app-process data while naming the partial refresh.
    /// Existing GC callers deliberately retain their best-effort empty-array shape.
    static func listSessionsResult() async -> [LiveDaemon]? {
        guard let executableURL = bundledExecutableURL() else { return nil }
        let runner = BoundedCommandRunner(
            executableCandidates: [executableURL.path],
            timeout: .seconds(2),
            maxOutputBytes: 1024 * 1024,
            environment: bridgeProcessEnvironment()
        )
        guard let data = await runner.run(
            arguments: ["list"],
            inDirectory: FileManager.default.currentDirectoryPath
        ), let output = String(data: data, encoding: .utf8) else { return nil }
        return DaemonGCPlan.parseAmxList(output)
    }

    /// Resource-bearing process snapshot for the local Diagnostics pane. `comm`
    /// is the executable path only; command arguments are intentionally absent.
    /// Uses `-xo` (current user only): diagnostics only groups this user's app,
    /// daemon, shell, and agent processes — not other UIDs' full process tables.
    static func currentDiagnosticsProcessSnapshot() async -> [DiagnosticsRawProcess]? {
        guard let data = await diagnosticsProcessRunner.run(
            arguments: ["-xo", "pid=,ppid=,%cpu=,rss=,comm="],
            inDirectory: "/"
        ), let output = String(data: data, encoding: .utf8) else { return nil }
        let snapshot = DiagnosticsProcessParser.parse(output)
        return snapshot.isEmpty ? nil : snapshot
    }

    /// `ps` snapshot of every process (`pid ppid comm`). Rooted at `/` with an
    /// empty environment so it can't inherit anything surprising.
    ///
    /// Returns `nil` (not `[]`) when `ps` fails, times out, or yields nothing
    /// parseable — the caller MUST distinguish "no process info" from "no
    /// children", because an empty snapshot would make every daemon look idle
    /// and reap live work. A successful `ps` always has many rows.
    static func currentProcessSnapshot() async -> [ProcEntry]? {
        let runner = BoundedCommandRunner(
            executableCandidates: ["/bin/ps"],
            timeout: .seconds(2),
            maxOutputBytes: 4 * 1024 * 1024,
            environment: [:]
        )
        guard let data = await runner.run(
            arguments: ["-axo", "pid=,ppid=,comm="],
            inDirectory: "/"
        ), let output = String(data: data, encoding: .utf8) else { return nil }
        let snapshot = DaemonGCPlan.parseProcessSnapshot(output)
        return snapshot.isEmpty ? nil : snapshot
    }

    static func isIdle(_ daemon: LiveDaemon, snapshot: [ProcEntry]) -> Bool {
        DaemonGCPlan.isIdle(daemonPID: daemon.pid, in: snapshot)
    }

    nonisolated private static let killLog = Logger(subsystem: "awesomux.daemon", category: "kill")

    /// Fire-and-forget fan-out kill for daemon ids an explicit destroy just
    /// made unreachable; mirrors the clear-workspace path. Kills are
    /// independent (one hung `amx kill` must not serialize the rest) and
    /// launch-time GC reaps any that fail or never run.
    static func killSessionsDetached(_ ids: [TerminalSessionID], context: StaticString) {
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask {
                        if await killSession(id) == false {
                            killLog.info("\(context, privacy: .public) kill failed sessionID=\(id.rawValue, privacy: .public); launch GC will reap")
                        }
                    }
                }
            }
        }
    }

    /// `amx kill <id> --force`. Returns whether `amx` exited 0 — NOT a confirmed
    /// reap: zmx exits 0 even when the session was already gone or the underlying
    /// kill failed. The caller re-lists afterward to count daemons actually gone.
    static func killSession(_ id: TerminalSessionID) async -> Bool {
        guard TerminalSessionID.isValid(id.rawValue),
              let executableURL = bundledExecutableURL() else { return false }
        let runner = BoundedCommandRunner(
            executableCandidates: [executableURL.path],
            timeout: .seconds(2),
            maxOutputBytes: 64 * 1024,
            environment: bridgeProcessEnvironment()
        )
        return await runner.run(
            arguments: ["kill", id.rawValue, "--force"],
            inDirectory: FileManager.default.currentDirectoryPath
        ) != nil
    }

    static var establishedSessionMetadata: TerminalBackendMetadata {
        TerminalBackendMetadata(rawValue: establishedMetadataRawValue)
    }

    /// Environment for spawned `amx list`/`kill`: scrub inherited zmx control
    /// vars and pin `ZMX_DIR` to awesoMux's own socket dir so these commands are
    /// scoped to our daemons only (the ownership boundary GC relies on).
    private static func bridgeProcessEnvironment() -> [String: String] {
        cachedBridgeProcessEnvironment
    }

    /// Built once: `ProcessInfo.environment` rebuilds the whole dict on every
    /// access (documented hot-path trap, mirrored by `toolAugmentedEnvironment`
    /// elsewhere), and the bridge spawns subprocesses frequently. The inherited
    /// environment is process-stable, so snapshot the scrubbed/pinned result.
    private static let cachedBridgeProcessEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        for key in scrubbedEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["ZMX_DIR"] = cachedSocketDirectory
        environment["ZMX_DIR_MODE"] = socketDirectoryMode
        return environment
    }()

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
