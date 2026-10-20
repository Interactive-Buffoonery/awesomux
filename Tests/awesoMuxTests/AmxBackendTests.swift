import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

// Regression coverage for the security-sensitive bridge command construction
// (INT-561 / INT-570 / INT-572). `attachCommand(executablePath:sessionID:socketDirectory:)`
// is the injectable, `Bundle.main`-free seam so the env scrub, the explicit
// ZMX_DIR pin, and single-quote escaping can be asserted without a real `amx`
// beside the test runner.
@Suite("AmxBackend attach-command assembly")
struct AmxBackendAttachCommandTests {
    @Test("create-or-attach carries sorted recovery labels")
    func createOrAttachCarriesRecoveryLabels() throws {
        let id = try #require(TerminalSessionID(rawValue: "abc123-labels"))
        let metadata = DaemonRecoveryMetadata(
            workspaceTitle: "Build",
            paneTitle: nil,
            groupID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            groupName: "Work",
            groupRemote: nil,
            agentKind: .codex
        )
        let command = try #require(
            AmxBackend.attachCommand(
                executablePath: "/Apps/amx",
                sessionID: id,
                socketDirectory: "/tmp/amx",
                mode: .createOrAttach(metadata: metadata)
            ))

        #expect(command.contains(" attach --labels '"))
        let assignments = metadata.encodedLabelAssignments.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        #expect(command.contains("'\(assignments)' 'abc123-labels'"))
    }

    @Test("existing-only attach cannot create or mutate labels")
    func existingOnlyAttach() throws {
        let id = try #require(TerminalSessionID(rawValue: "abc123-existing"))
        let command = try #require(
            AmxBackend.attachCommand(
                executablePath: "/Apps/amx",
                sessionID: id,
                socketDirectory: "/tmp/amx",
                mode: .existingOnly
            ))

        #expect(command.contains(" attach --existing 'abc123-existing'"))
        #expect(!command.contains("--labels"))
        #expect(command.contains("-u ZMX_SESSION"))
    }

    @Test(arguments: ["plain", "spaces", "quote", "socket", "status", "zsh", "fish", "hostile"])
    func attachCommandPreservesShellArguments(scenario: String) throws {
        let directory = try TemporaryDirectory(prefix: "amx-shell-quoting")
        let root = directory.url
        let suffix: String
        switch scenario {
        case "spaces": suffix = "weird path/amx"
        case "quote": suffix = "a'b/amx"
        case "hostile": suffix = "'; touch pwned #/amx"
        default: suffix = "Apps/awesoMux.app/Contents/MacOS/amx"
        }
        let executable = root.appending(path: suffix)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            #!/bin/sh
            printf '%s\\000' "$ZMX_DIR" "$ZMX_DIR_MODE" "$AMX_STATUS_FILE" "$AMX_STATUS_TOKEN" "$ZDOTDIR" "$GHOSTTY_ZSH_ZDOTDIR" "$GHOSTTY_SHELL_INTEGRATION_XDG_DIR" "$XDG_DATA_DIRS"
            /usr/bin/env > captured-env
            printf '%s\\000' "$@"
            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let id = try #require(TerminalSessionID(rawValue: "abc123-def"))
        let socketDirectory = scenario == "socket" ? "/weird dir/amx" : "/tmp/amx"
        let statusPath = "/tmp/weird dir/abc123-sp-aabb.status.jsonl"
        let status = scenario == "status" ? AmxStatusChannel(fileURL: URL(fileURLWithPath: statusPath), token: "aabbccdd") : nil
        let zsh = scenario == "zsh"
        let fish = scenario == "fish"
        let command = try #require(
            AmxBackend.attachCommand(
                executablePath: executable.path, sessionID: id, socketDirectory: socketDirectory,
                status: status, ghosttyResourcesDir: zsh || fish ? "/a'b/ghostty" : nil,
                inheritedZDOTDIR: zsh ? "/c'; touch pwned #" : nil,
                inheritedXDGDataDirs: fish ? "/c'; touch pwned #" : nil,
                shellPath: zsh ? "/bin/zsh" : fish ? "/usr/local/bin/fish" : nil
            ))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        let scrubbed = [
            "CLAUDE_CODE_CHILD_SESSION", "ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_LOG_MODE", "AMX_STATUS_FILE", "AMX_STATUS_TOKEN",
            "AWESOMUX_SSH_MOUSE_RECOVERY",
        ]
        process.environment = Dictionary(uniqueKeysWithValues: scrubbed.map { ($0, "inherited-sentinel") })
        let captured = try captureOutput(of: process)
        #expect(process.terminationStatus == 0, "\(captured.stderr)")
        let fields = captured.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let expected = [
            socketDirectory, "700", status == nil ? "" : statusPath, status == nil ? "" : "aabbccdd",
            zsh ? "/a'b/ghostty/shell-integration/zsh" : "", zsh ? "/c'; touch pwned #" : "",
            fish ? "/a'b/ghostty/shell-integration" : "", fish ? "/a'b/ghostty/shell-integration:/c'; touch pwned #" : "",
        ]
        #expect(Array(fields.prefix(8)) == expected)
        #expect(fields.dropFirst(8).first == "attach")
        #expect(fields.dropLast().last == id.rawValue)
        let environment = try String(contentsOf: root.appending(path: "captured-env"), encoding: .utf8)
        #expect(!environment.contains("inherited-sentinel"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "pwned").path))
    }

    enum ClaudeChildContextScrubCase: String, CaseIterable {
        case remoteStatusAttachScrubsClaudeChildContext
        case bridgeStatusAttachScrubsClaudeChildContext
    }

    @Test(arguments: ClaudeChildContextScrubCase.allCases)
    func claudeChildContextScrub(_ scenario: ClaudeChildContextScrubCase) throws {
        switch scenario {
        case .remoteStatusAttachScrubsClaudeChildContext:
            let id = try #require(TerminalSessionID(rawValue: "abc123-remote-status"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/opt/awesomux/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    status: AmxStatusChannel(
                        fileURL: URL(fileURLWithPath: "/tmp/amx/status.jsonl"),
                        token: "token"
                    ),
                    remote: RemoteTarget(user: "alice", host: "box")!
                )
            )

            #expect(command.contains("-u CLAUDE_CODE_CHILD_SESSION"))
            #expect(command.contains("-u AWESOMUX_AGENT_EVENT_FILE"))
        case .bridgeStatusAttachScrubsClaudeChildContext:
            let id = try #require(TerminalSessionID(rawValue: "abc123-bridge"))
            let command = try #require(
                AmxBackend.bridgeAttachCommand(
                    executablePath: "/opt/awesomux/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    status: AmxStatusChannel(
                        fileURL: URL(fileURLWithPath: "/tmp/amx/status.jsonl"),
                        token: "token"
                    ),
                    remote: RemoteTarget(user: "alice", host: "box")!,
                    stateFilePath: "/tmp/bridge-state.json",
                    helperPath: "/opt/awesomux/bridge"
                )
            )

            #expect(command.contains("-u CLAUDE_CODE_CHILD_SESSION"))
            #expect(command.contains("-u AWESOMUX_AGENT_EVENT_FILE"))
        }
    }

    enum ShellIntegrationEnvironmentCase: String, CaseIterable {
        case injectsShellIntegrationZDOTDIR
        case preservesInheritedZDOTDIR
        case omitsShellIntegrationWithoutResourcesDir
        case omitsShellIntegrationForUnsupportedShells
        case injectsFishShellIntegrationXDGDataDirs
        case prependsInheritedXDGDataDirs
        case distinguishesAbsentFromEmptyXDGDataDirs
        case omitsFishShellIntegrationWithoutResourcesDir
        case omitsFishShellIntegrationForRemote
        case omitsShellIntegrationForRemote
        case statusOverloadInjectsShellIntegration
    }

    @Test(arguments: ShellIntegrationEnvironmentCase.allCases)
    func shellIntegrationEnvironment(_ scenario: ShellIntegrationEnvironmentCase) throws {
        switch scenario {
        case .injectsShellIntegrationZDOTDIR:
            let id = try #require(TerminalSessionID(rawValue: "abc123-zdot"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "/Apps/awesoMux.app/Contents/Resources/ghostty",
                    shellPath: "/bin/zsh"
                ))
            #expect(
                command.contains(
                    "'ZDOTDIR=/Apps/awesoMux.app/Contents/Resources/ghostty/shell-integration/zsh'"
                ))
            // No pre-existing ZDOTDIR → the preserve token must be absent, so the
            // integration .zshenv unsets ZDOTDIR after chaining (ghostty parity).
            #expect(!command.contains("GHOSTTY_ZSH_ZDOTDIR"))
        case .preservesInheritedZDOTDIR:
            let id = try #require(TerminalSessionID(rawValue: "abc123-zdotkeep"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "/res/ghostty",
                    inheritedZDOTDIR: "/Users/me/.config/zsh",
                    shellPath: "/bin/zsh"
                ))
            #expect(command.contains("'ZDOTDIR=/res/ghostty/shell-integration/zsh'"))
            #expect(command.contains("'GHOSTTY_ZSH_ZDOTDIR=/Users/me/.config/zsh'"))
        case .omitsShellIntegrationWithoutResourcesDir:
            let id = try #require(TerminalSessionID(rawValue: "abc123-nores"))
            let missing = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    shellPath: "/bin/zsh"
                ))
            #expect(!missing.contains("ZDOTDIR"))
            let empty = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "",
                    shellPath: "/bin/zsh"
                ))
            #expect(!empty.contains("ZDOTDIR"))
        case .omitsShellIntegrationForUnsupportedShells:
            let id = try #require(TerminalSessionID(rawValue: "abc123-bash"))
            // bash/nu: zmx's execvpe($SHELL) spawn can't do the argv rewriting
            // (--posix+ENV / --execute) their integration needs. elvish: unlike
            // fish, it does not auto-source its integration file from
            // XDG_DATA_DIRS — ghostty's own docs say the user must explicitly
            // `use ghostty-integration` themselves, so env-only injection here
            // would neither activate it nor get cleaned up.
            for shell in ["/bin/bash", "/usr/bin/elvish", "/usr/local/bin/nu", nil] as [String?] {
                let command = try #require(
                    AmxBackend.attachCommand(
                        executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                        sessionID: id,
                        socketDirectory: "/tmp/amx",
                        ghosttyResourcesDir: "/res/ghostty",
                        shellPath: shell
                    ))
                #expect(!command.contains("ZDOTDIR"))
                #expect(!command.contains("XDG_DATA_DIRS"))
            }
        case .injectsFishShellIntegrationXDGDataDirs:
            let id = try #require(TerminalSessionID(rawValue: "abc123-fish"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "/Apps/awesoMux.app/Contents/Resources/ghostty",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(
                command.contains(
                    "'GHOSTTY_SHELL_INTEGRATION_XDG_DIR=/Apps/awesoMux.app/Contents/Resources/ghostty/shell-integration'"
                ))
            // No pre-existing XDG_DATA_DIRS → prepend ghostty's own freedesktop
            // fallback default, not an empty/missing value (ghostty parity).
            #expect(
                command.contains(
                    "'XDG_DATA_DIRS=/Apps/awesoMux.app/Contents/Resources/ghostty/shell-integration:/usr/local/share:/usr/share'"
                ))
        case .prependsInheritedXDGDataDirs:
            let id = try #require(TerminalSessionID(rawValue: "abc123-fishxdg"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "/res/ghostty",
                    inheritedXDGDataDirs: "/opt/share",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(command.contains("'XDG_DATA_DIRS=/res/ghostty/shell-integration:/opt/share'"))
        case .distinguishesAbsentFromEmptyXDGDataDirs:
            let id = try #require(TerminalSessionID(rawValue: "abc123-fishxdgempty"))
            // Explicitly empty (present but ""): ghostty's own internal_os.prependEnv
            // (vendor/ghostty/src/os/env.zig) special-cases a zero-length current
            // value as "nothing to prepend onto" and returns the new value alone
            // — no trailing delimiter, no default substituted. That only happens
            // for an ABSENT XDG_DATA_DIRS (where `orelse` substitutes the
            // freedesktop default before prependEnv ever sees it).
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "/res/ghostty",
                    inheritedXDGDataDirs: "",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(command.contains("'XDG_DATA_DIRS=/res/ghostty/shell-integration'"))
            #expect(!command.contains("shell-integration:"))
            #expect(!command.contains("/usr/local/share:/usr/share"))
        case .omitsFishShellIntegrationWithoutResourcesDir:
            let id = try #require(TerminalSessionID(rawValue: "abc123-fishnores"))
            let missing = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(!missing.contains("XDG_DATA_DIRS"))
            let empty = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    ghosttyResourcesDir: "",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(!empty.contains("XDG_DATA_DIRS"))
        case .omitsFishShellIntegrationForRemote:
            let id = try #require(TerminalSessionID(rawValue: "abc123-fishremote"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/opt/awesomux/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    remote: RemoteTarget(user: "alice", host: "box")!,
                    ghosttyResourcesDir: "/res/ghostty",
                    shellPath: "/usr/local/bin/fish"
                ))
            #expect(!command.contains("XDG_DATA_DIRS"))
        case .omitsShellIntegrationForRemote:
            let id = try #require(TerminalSessionID(rawValue: "abc123-zdotremote"))
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/opt/awesomux/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    remote: RemoteTarget(user: "alice", host: "box")!,
                    ghosttyResourcesDir: "/res/ghostty",
                    shellPath: "/bin/zsh"
                ))
            #expect(!command.contains("ZDOTDIR"))
        case .statusOverloadInjectsShellIntegration:
            let id = try #require(TerminalSessionID(rawValue: "abc123-zdotstatus"))
            let status = AmxStatusChannel(
                fileURL: URL(fileURLWithPath: "/tmp/amx/abc123-zdotstatus.status.jsonl"),
                token: "deadbeef01234567deadbeef01234567"
            )
            let command = try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                    sessionID: id,
                    socketDirectory: "/tmp/amx",
                    status: status,
                    ghosttyResourcesDir: "/res/ghostty",
                    shellPath: "/bin/zsh"
                ))
            #expect(command.contains("'ZDOTDIR=/res/ghostty/shell-integration/zsh'"))
        }
    }

}

// MARK: - AmxBackend.shellIntegrationInputs (env → attach-input resolution)

@Suite("AmxBackend shellIntegrationInputs")
struct AmxBackendShellIntegrationInputsTests {

    @Test(arguments: ["zsh-missing", "zsh", "fish"])
    func shellIntegrationInputsUseValidatedResources(scenario: String) {
        let shell = scenario == "fish" ? "/usr/local/bin/fish" : "/bin/zsh"
        let resources = scenario == "zsh-missing" ? "/Apps/awesoMux.app/Contents/Resources/ghostty" : "/res/ghostty"
        let inputs = AmxBackend.shellIntegrationInputs(
            from: ["GHOSTTY_RESOURCES_DIR": resources, "ZDOTDIR": "/Users/me/.config/zsh", "SHELL": shell],
            fileExists: { path in
                scenario != "zsh-missing" && path == resources + (scenario == "fish" ? "/shell-integration" : "/shell-integration/zsh")
            }
        )
        #expect(inputs.ghosttyResourcesDir == (scenario == "zsh-missing" ? nil : resources))
        #expect(inputs.inheritedZDOTDIR == "/Users/me/.config/zsh")
        #expect(inputs.shellPath == shell)
    }

    @Test("the default probe rejects a regular file squatting on the integration path")
    func defaultProbeRejectsRegularFile() throws {
        // Mirrors ghostty's own probes (setupZsh/setupXdgDataDirs both use
        // openDirAbsolute, not a plain existence check) — exercised against
        // the real FileManager-backed default, not a stub.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesoMuxShellIntegrationProbeTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeIntegrationFile = tempDir.appendingPathComponent("shell-integration")
        try Data().write(to: fakeIntegrationFile)

        let inputs = AmxBackend.shellIntegrationInputs(
            from: ["GHOSTTY_RESOURCES_DIR": tempDir.path, "SHELL": "/usr/local/bin/fish"]
        )
        #expect(inputs.ghosttyResourcesDir == nil)
    }
}

// MARK: - AmxStatusChannel + status-env attach overload (INT-572)

@Suite("AmxStatusChannel")
struct AmxStatusChannelTests {

    // MARK: - Pre-create the status file (M1)

    @Test("makeStatusChannel pre-creates the file with 0600 permissions")
    func preCreatesFileWith0600() throws {
        let id = try #require(TerminalSessionID(rawValue: "test-session-precreate"))
        let channel = try #require(AmxBackend.makeStatusChannel(for: id))
        defer { try? FileManager.default.removeItem(at: channel.fileURL) }

        // File must exist immediately (before any daemon writes), so the
        // O_EVTONLY watcher can arm against it.
        #expect(FileManager.default.fileExists(atPath: channel.fileURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: channel.fileURL.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.int16Value == 0o600)
    }
}

// MARK: - queryCwd output parsing (pure unit tests, no binary needed)

@Suite("AmxBackend queryCwd output parsing")
struct AmxBackendQueryCwdParsingTests {

    @Test(arguments: [
        ("/Users/alice/project\n", "/Users/alice/project" as String?),
        ("  /Users/alice  \n", "/Users/alice"),
        ("/Users/alice\n/extra/line\n", "/Users/alice"),
        ("", nil), ("   \n  \n", nil), ("\n\n", nil),
        ("\n\n/Users/alice/src\n", "/Users/alice/src"),
        ("relative/path\n", nil), ("error: no such session\n", nil),
        ("/Users/alice/\0evil\n", nil),
        ("/" + String(repeating: "a", count: 1024) + "\n", nil),
        ("/" + String(repeating: "a", count: 1023) + "\n", "/" + String(repeating: "a", count: 1023)),
        ("/tmp/e\u{202E}vil\n", nil),
    ])
    func cwdOutputTrustBoundary(input: String, expected: String?) {
        #expect(AmxBackend.parseCwdOutput(input) == expected)
    }

}

// MARK: - sshControlPath sockaddr_un budget

@Suite("AmxBackend sshControlPath")
struct AmxBackendSshControlPathTests {
    @Test("stays under the sockaddr_un limit including ssh's temp suffix, and doesn't crash")
    func fitsUnderSockaddrUnLimitIncludingTempSuffix() {
        // The budget must cover the path ssh actually binds: `muxserver_listen`
        // creates a TEMPORARY socket = ControlPath + "." + 16 random chars (17
        // bytes) before renaming to the final path, so a ControlPath that fits
        // 104 can still overflow during master setup (INT-766). The short
        // per-user dir keeps directory + "/" + 40-char %C + 17-byte temp suffix
        // + NUL well under 104, so this returns cleanly rather than tripping the
        // DEBUG assertion the guard adds.
        let path = AmxBackend.sshControlPath()
        #expect(path.hasSuffix("/%C"))
        let directory = AmxBackend.sshControlDirectory()
        #expect(directory.utf8.count + 1 + 40 + 17 + 1 <= 104)
    }
}

// A remote-owned pane's zmx lives on the far host, so its command is assembled
// WITHOUT the local-daemon apparatus every other attach carries. These assert the
// exact full string: the hard fence is that `ZMX_DIR`, `AMX_STATUS_*`, and the
// shell-integration env can never appear, and a substring check can't prove an
// absence the way a whole-string equality can.
@Suite("AmxBackend remote-owned attach-command assembly")
struct AmxBackendRemoteOwnedAttachCommandTests {
    private static let remote = RemoteTarget(user: "alice", host: "box")!
    private static let sessionName = RemoteSessionName(rawValue: "dev")!

    /// The scrubbed `env` prefix, up to the local shell that wraps the ssh run.
    private static var expectedPrefix: String {
        "'/usr/bin/env' "
            + "-u CLAUDE_CODE_CHILD_SESSION -u ZMX_SESSION -u ZMX_SESSION_PREFIX -u ZMX_LOG_MODE "
            + "-u AMX_STATUS_FILE -u AMX_STATUS_TOKEN -u AWESOMUX_SSH_MOUSE_RECOVERY "
            + "-u AWESOMUX_AGENT_EVENT_PROTOCOL -u AWESOMUX_SESSION_ID -u AWESOMUX_PANE_ID "
            + "-u AWESOMUX_AGENT_EVENT_FILE -u AWESOMUX_AGENT_HOOK "
            + "-u AWESOMUX_AGENT_ENABLED_SOURCES -u AWESOMUX_AMX -u AWESOMUX_PROFILE "
            + "'/bin/sh' '-c' "
    }

    /// The ssh invocation as it appears INSIDE the local shell's script, before
    /// that script is quoted into a single argument. The ControlPath embeds the
    /// invoking user's home directory, so it is interpolated rather than
    /// literal — the same accommodation the local-amx ssh-tail tests make.
    private static var expectedSSHTokens: String {
        "'/usr/bin/env' 'TERM=xterm-256color' 'ssh' '-o' 'ControlMaster=auto' "
            + "'-o' 'ControlPath=\(AmxBackend.sshControlPath())' "
            + "'-o' 'ControlPersist=60' '-o' 'ConnectTimeout=10' '-o' 'ServerAliveInterval=15' "
            + "'-t' '--' 'alice@box' "
    }

    private static let exitStatusFile = URL(fileURLWithPath: "/tmp/amx-test/session.exit")


    /// The whole of #235: nothing is asked for, and every place the backend can
    /// hide is checked on the far side. Asserted on the script rather than
    /// through both quoting layers, where it is an unreadable blob.

    @Test(arguments: ["amx", "zmx", "home-app", "system-app", "function", "missing"])
    func discoveryExecutesBackendFallbacks(scenario: String) throws {
        let directory = try TemporaryDirectory(prefix: "amx-discovery")
        let root = directory.url
        let bin = root.appending(path: "bin")
        let home = root.appending(path: "home")
        let systemApp = root.appending(path: "Applications/awesoMux.app/Contents/MacOS/amx")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: "grep"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/grep"))
        func executable(_ url: URL, _ body: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let shell = root.appending(path: "login-shell")
        try executable(shell, "[ \"$1\" = -lc ] || exit 91\nexec /bin/sh -c \"$2\"\n")
        let marker = "printf '%s:%s' \"$1\" \"$2\"\n"
        if scenario == "amx" || scenario == "zmx" { try executable(bin.appending(path: scenario), marker) }
        if scenario == "home-app" { try executable(home.appending(path: "Applications/awesoMux.app/Contents/MacOS/amx"), marker) }
        if scenario == "system-app" { try executable(systemApp, marker) }
        var script = AmxBackend.remoteBackendDiscoveryCommand(sessionName: Self.sessionName)
            .replacingOccurrences(of: "/Applications/awesoMux.app/Contents/MacOS/amx", with: systemApp.path)
        // Only the fixed system fallback is redirected; HOME's lookup remains literal.
        script = script.replacingOccurrences(of: "$HOME" + root.path, with: "$HOME")
        if scenario == "function" {
            try executable(shell, "[ \"$1\" = -lc ] || exit 91\nexec /bin/sh -c 'amx() { echo wrong; }; '" + "\"$2\"\n")
            try executable(bin.appending(path: "zmx"), marker)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["PATH": bin.path, "HOME": home.path, "SHELL": shell.path]
        let captured = try captureOutput(of: process)
        #expect(process.terminationStatus == (scenario == "missing" ? 127 : 0), "\(captured.stderr)")
        if scenario == "missing" {
            #expect(captured.stdout.isEmpty)
            #expect(captured.stderr.contains("no amx or zmx found"))
        } else {
            #expect(captured.stdout == "attach:dev")
        }
    }

    /// Minting can fail (squatted path, EACCES). The pane must still attach —
    /// losing the exit status is the pre-#237 behaviour, refusing to connect is
    /// a regression.
    @Test("a pane with no status file still attaches, without the shell wrapper")
    func attachesWithoutStatusFile() {
        let command = AmxBackend.remoteOwnedAttachCommand(
            remote: Self.remote,
            sessionName: Self.sessionName,
            exitStatusFile: nil
        )
        #expect(command.contains("'ssh'"))
        #expect(!command.contains("'/bin/sh'"))
        #expect(!command.contains("printf"))
        #expect(command.contains("-u CLAUDE_CODE_CHILD_SESSION"))
    }

    /// Round-trips the real file through the real shell command, which is the
    /// only way to prove the quoted redirect and the reader agree. Runs the
    /// wrapper's own reporting fragment rather than a hand-written echo.
    @Test("the wrapper's write and the reader agree, and the read consumes the file")
    func exitStatusFileRoundTrips() throws {
        let sessionID = try #require(TerminalSessionID(rawValue: "roundtrip-exit-status"))
        let url = try #require(AmxBackend.makeRemoteOwnedExitStatusFile(for: sessionID))
        defer { try? FileManager.default.removeItem(at: url) }

        // 0600 in a user-only directory, per the squatting guard it shares with
        // the amx status channel.
        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value == 0o600)

        let command = AmxBackend.remoteOwnedAttachCommand(
            remote: Self.remote,
            sessionName: Self.sessionName,
            exitStatusFile: url
        )
        // Take the wrapper's script exactly as assembled, and swap only the ssh
        // invocation for a stub that exits 42 — so the redirect under test is
        // the shipped one, through its real quoting.
        let script = try #require(command.components(separatedBy: "'-c' ").last)
        let unquoted = String(script.dropFirst().dropLast())
            .replacingOccurrences(of: "'\\''", with: "'")
        let stubbed = unquoted.replacingOccurrences(
            of: "'ssh'",
            with: "'/bin/sh' '-c' 'exit 42' ''",
            options: [],
            range: unquoted.range(of: "'ssh'")
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", stubbed]
        try process.run()
        try process.waitUntilExitEventually()

        #expect(AmxBackend.consumeRemoteOwnedExitStatus(at: url) == 42)
        // Consumed means gone: a second read must not resurrect a dead attach's
        // status for the next one.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(AmxBackend.consumeRemoteOwnedExitStatus(at: url) == nil)
    }

    @Test("carries no local-daemon state: no ZMX_DIR, no status channel, no shell integration")
    func carriesNoLocalDaemonState() {
        let command = AmxBackend.remoteOwnedAttachCommand(
            remote: Self.remote,
            sessionName: Self.sessionName,
            exitStatusFile: Self.exitStatusFile
        )
        #expect(command.contains("'\\''-t'\\'' "))
        // The local socket directory is meaningless to a zmx on another host.
        #expect(!command.contains("ZMX_DIR"))
        #expect(!command.contains("ZMX_DIR_MODE"))
        // The status channel writes to a local file no remote process can reach.
        // Assignments only — the `-u` scrub tokens legitimately name these.
        #expect(!command.contains("AMX_STATUS_FILE="))
        #expect(!command.contains("AMX_STATUS_TOKEN="))
        // The bundled ghostty resources dir does not exist on the far host.
        #expect(!command.contains("ZDOTDIR"))
        #expect(!command.contains("XDG_DATA_DIRS"))
        #expect(!command.contains("GHOSTTY_"))
        // Nothing local is bridged, so no bridge env crosses either.
        #expect(!command.contains("AWESOMUX_BRIDGE_"))
        // No assertion here about this app's own bundle path: under `swift test`
        // `Bundle.main` is the test runner, so such a check passes against any
        // implementation and proves nothing. The remote bundle paths this
        // command MAY name are pinned literally by
        // `discoveryScriptChecksEveryBackendLocation`.
    }
}
