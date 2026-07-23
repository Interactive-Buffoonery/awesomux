import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// Coverage for INT-698 D1's pure command builders and the local execution of
// their state-file scripts. No live SSH or remote host is involved.
@Suite("Bridge attach command assembly")
struct BridgeAttachAssemblyTests {
    private static let sessionID = TerminalSessionID(rawValue: "abc123-bridge")!
    private static let remote = RemoteTarget(user: "alice", host: "box")!

    /// Every pane-scoped agent key plus the status pair — the exact-name
    /// expansion of the spec's `AWESOMUX_AGENT_*` / `AMX_STATUS_*` scrub
    /// (env -u cannot glob, so each must appear literally).
    private static let sshCrossingScrubKeys =
        Set(AgentRuntimeEnvironmentKey.paneScopedKeys + ["AMX_STATUS_FILE", "AMX_STATUS_TOKEN"])

    // MARK: - BridgeChannel.mint

    @Test("mint produces a token of the same shape as the status channel's forgery token")
    func mintTokenShape() throws {
        let channel = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/awesomux-bridge-local/bridge.sock",
            remoteHome: "/Users/example"
        ))
        // 32 lowercase hex chars, same shape as `AmxBackend.makeStatusChannel`.
        #expect(channel.token.count == 32)
        #expect(channel.token.allSatisfy { $0.isHexDigit })
        #expect(channel.token == channel.token.lowercased())
    }

    @Test("mint's remote socket path stays under the 104-byte sockaddr_un budget")
    func mintRemoteSocketPathBudget() throws {
        let channel = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/example"
        ))
        #expect(channel.remoteSocketPath.hasPrefix("/tmp/awesomux-bridge-"))
        #expect(channel.remoteSocketPath.hasSuffix(".sock"))
        #expect(channel.remoteSocketPath.utf8.count < BridgeChannel.sockaddrUnPathLimit)
    }

    @Test("gen increments per mint")
    func genIncrementsPerMint() throws {
        let first = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/example"
        ))
        #expect(first.gen == 1)

        let second = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: first.gen,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/example"
        ))
        #expect(second.gen == 2)
        #expect(second.token != first.token)
        #expect(second.remoteSocketPath != first.remoteSocketPath)
    }

    @Test(
        "mint rejects an unusable remoteHome",
        arguments: ["relative/home", "", "~", "/Users/ed\0", "/Users/\u{202E}de"]
    )
    func mintRejectsUnusableHome(remoteHome: String) {
        #expect(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: remoteHome
        ) == nil)
    }

    @Test("stateFilePath resolves under the given remoteHome")
    func stateFilePathResolvesUnderHome() throws {
        let channel = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/example"
        ))
        #expect(channel.stateFilePath == "/Users/example/.awesomux/bridge/abc123-bridge.json")
    }

    @Test("stateFilePath never carries a double slash for trailing-slash or root homes")
    func stateFilePathNormalizesTrailingSlash() throws {
        let trailing = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/example/"
        ))
        #expect(trailing.stateFilePath == "/Users/example/.awesomux/bridge/abc123-bridge.json")

        let rootHome = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/"
        ))
        #expect(rootHome.stateFilePath == "/.awesomux/bridge/abc123-bridge.json")
    }

    // MARK: - $HOME resolution — one-time exec channel

    @Test("$HOME resolution command yields an absolute-path-ready capture over the shared master")
    func homeResolutionCommandShape() {
        let command = AmxBackend.bridgeHomeResolutionCommand(
            controlPath: "/tmp/awesomux-ssh-XXXXXX/%C",
            remote: Self.remote
        )
        #expect(command.hasPrefix("ssh -S "))
        #expect(command.contains("/tmp/awesomux-ssh-XXXXXX/%C"))
        // `--` must terminate option parsing before the destination so a
        // `-`-prefixed host can never be read as an ssh option.
        #expect(command.contains(" -- 'alice@box'"))
        #expect(!command.contains("mkdir"))
        // The remote script is itself single-quoted as one ssh argument, so
        // its own embedded quotes come out POSIX-escaped (`'\''`) rather
        // than literal — assert on the surviving unescaped fragments.
        #expect(command.contains("printf"))
        #expect(command.contains(#""$HOME""#))
        assertNoGlobDeletion(in: command)
    }

    @Test("exec-channel commands establish the master; -O control commands require it")
    func execCommandsEstablishMasterControlCommandsDoNot() throws {
        // Live-smoke gate-9 regression: an attach that begins with NO live
        // master (reconnect after master death) must not permanently degrade.
        // Exec commands carry ControlMaster=auto so the first of them (the
        // $HOME resolution) establishes the shared master; the -O forward that
        // follows then finds it. The -O commands themselves stay bare: `-O`
        // against a missing master fails by design (that's the step-5 no-op
        // shape), and ControlMaster=auto on a -O command is meaningless.
        let channel = BridgeChannel(
            token: "4f3c00000000000000000000000000a19b",
            gen: 1,
            localSocketPath: "/tmp/local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-deadbeefdeadbeef.sock",
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID
        )
        let execCommands: [String] = [
            AmxBackend.bridgeHomeResolutionCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote
            ),
            AmxBackend.bridgeStateFileWriteCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote, channel: channel
            )!.command,
            AmxBackend.bridgeRemoteSocketAdmissionCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                remoteSocketPath: channel.remoteSocketPath
            ),
            AmxBackend.bridgeRemoteSocketRemoveCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                remoteSocketPath: channel.remoteSocketPath
            ),
            AmxBackend.bridgeHelperVersionCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                helperPath: "/home/ed/.awesomux/bin/awesomux-bridge-helper"
            ),
            AmxBackend.bridgeHelperSelfCheckCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                helperPath: "/home/ed/.awesomux/bin/awesomux-bridge-helper",
                stateFilePath: "/home/ed/.awesomux/bridge/abc.json",
                session: Self.sessionID
            ),
            AmxBackend.bridgeStateFileRemoveCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                stateFilePath: "/home/ed/.awesomux/bridge/abc.json",
                remoteSocketPath: channel.remoteSocketPath
            )
        ]
        for command in execCommands {
            // Options must sit in ssh's option region — BEFORE the `--` that
            // ends option parsing. A match after `--` would be inert text
            // inside the remote command, not an ssh flag.
            let optionRegionEnd = try #require(command.range(of: " -- ")).lowerBound
            for option in ["-o ControlMaster=auto", "-o ControlPersist=60", "-o ServerAliveInterval=15"] {
                let match = command.range(of: option)
                #expect(match != nil, "missing \(option): \(command)")
                if let match {
                    #expect(match.upperBound <= optionRegionEnd,
                            "\(option) landed after `--` (inert): \(command)")
                }
            }
            let timeout = try #require(command.range(of: "-o ConnectTimeout=10"))
            #expect(timeout.upperBound <= optionRegionEnd)
            #expect(
                !command.contains("ForwardAgent"),
                "the user's SSH config must control agent forwarding: \(command)"
            )
        }
        let controlCommands: [String] = [
            AmxBackend.bridgeReverseForwardCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote, channel: channel
            ),
            AmxBackend.bridgeReverseForwardCancelCommand(
                controlPath: "/tmp/c/%C", remote: Self.remote,
                remoteSocketPath: channel.remoteSocketPath,
                localSocketPath: channel.localSocketPath
            )
        ]
        for command in controlCommands {
            #expect(!command.contains("ControlMaster"), "-O command must not claim master establishment: \(command)")
        }
    }

    // MARK: - State-file write — the exec-channel command

    @Test("state-file write command: exact string, secrets on stdin not argv")
    func stateFileWriteExactString() throws {
        let channel = BridgeChannel(
            token: "4f3c00000000000000000000000000a19b",
            gen: 3,
            localSocketPath: "/tmp/local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-deadbeefdeadbeef.sock",
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID
        )
        let write = try #require(AmxBackend.bridgeStateFileWriteCommand(
            controlPath: "/tmp/awesomux-ssh-XXXXXX/%C",
            remote: Self.remote,
            channel: channel
        ))

        // Secrets (token, socket) are in the JSON payload, which rides stdin —
        // never the command string itself.
        #expect(!write.command.contains(channel.token))
        #expect(!write.command.contains(channel.remoteSocketPath))

        let decoded = try JSONDecoder().decode(BridgeStateFile.self, from: write.stdinData)
        #expect(decoded == BridgeStateFile(
            proto: "awesomux-bridge-v1", gen: 3,
            socket: channel.remoteSocketPath, token: channel.token
        ))

        #expect(write.command.hasPrefix("ssh -S "))
        #expect(write.command.contains("/tmp/awesomux-ssh-XXXXXX/%C"))
        #expect(write.command.contains(" -- 'alice@box'"))
        // mkdir targets the state file's own (absolute, quoted) parent — the
        // captured home, never a remote-side `~` re-expansion of it.
        #expect(write.command.contains("umask 077; mkdir -p '\\''/Users/example/.awesomux/bridge'\\''"))
        #expect(write.command.contains("stat -f"))
        #expect(write.command.contains("mktemp"))
        #expect(write.command.contains("cat > \"$bridge_state_lock_tmp\""))
        #expect(write.command.contains(" && mv "))
        #expect(write.command.contains(channel.stateFilePath))
        assertNoGlobDeletion(in: write.command)
    }

    @Test("state-file write command uses an exclusive mktemp template")
    func stateFileWriteUsesExclusiveTempName() throws {
        let channel = BridgeChannel(
            token: "token", gen: 1,
            localSocketPath: "/tmp/local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock",
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID
        )
        let first = try #require(AmxBackend.bridgeStateFileWriteCommand(
            controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: channel
        ))
        #expect(first.command.contains(".bridge-state.XXXXXXXX"))
        #expect(!first.command.contains(".json.tmp"))
    }

    @Test("state-file write command rejects a non-absolute stateFilePath")
    func stateFileWriteRejectsNonAbsolutePath() {
        let channel = BridgeChannel(
            token: "token", gen: 1,
            localSocketPath: "/tmp/local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock",
            stateFilePath: "relative/bridge.json",
            session: Self.sessionID
        )
        #expect(AmxBackend.bridgeStateFileWriteCommand(
            controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: channel
        ) == nil)
    }

    @Test("a single quote in the captured home survives quoting without a shell break-out")
    func stateFileWriteQuotesHostileHome() throws {
        let channel = try #require(BridgeChannel.mint(
            session: Self.sessionID,
            previousGeneration: 0,
            localSocketPath: "/tmp/local.sock",
            remoteHome: "/Users/e'd"
        ))
        let write = try #require(AmxBackend.bridgeStateFileWriteCommand(
            controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: channel
        ))
        // The path's own quote must always appear in its POSIX-escaped form,
        // never as a bare `'` that would terminate the enclosing quoting.
        #expect(!write.command.contains("/Users/e'd"))
        #expect(write.command.contains("/Users/e'\\''"))
    }

    @Test("state write cannot interleave with an identity-checked stale delete")
    func stateWriteSerializesWithStaleDelete() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-state-race-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        let wrapperDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let enteredURL = root.appendingPathComponent("delete-entered")
        let releaseURL = root.appendingPathComponent("delete-release")
        let oldChannel = BridgeChannel(
            token: "old-token",
            gen: 1,
            localSocketPath: "/tmp/old-local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-old.sock",
            stateFilePath: stateURL.path,
            session: Self.sessionID
        )
        let successor = BridgeChannel(
            token: "successor-token",
            gen: 2,
            localSocketPath: "/tmp/successor-local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-successor.sock",
            stateFilePath: stateURL.path,
            session: Self.sessionID
        )
        let oldWrite = try #require(
            AmxBackend.bridgeStateFileWriteCommand(
                controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: oldChannel
            )
        )
        let successorWrite = try #require(
            AmxBackend.bridgeStateFileWriteCommand(
                controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: successor
            )
        )
        try Self.runShell(
            try #require(AmxBackend.bridgeStateFileWriteRemoteScript(channel: oldChannel)),
            stdin: oldWrite.stdinData
        )

        let rmWrapper = wrapperDirectory.appendingPathComponent("rm")
        let wrapper = """
            #!/bin/sh
            for argument in "$@"; do
                if [ "$argument" = "$RACE_TARGET" ]; then
                    : > "$RACE_ENTERED"
                    while [ ! -e "$RACE_RELEASE" ]; do sleep 0.01; done
                    break
                fi
            done
            exec /bin/rm "$@"
            """
        try Data(wrapper.utf8).write(to: rmWrapper)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rmWrapper.path)
        let environment = [
            "PATH": wrapperDirectory.path + ":/usr/bin:/bin",
            "RACE_TARGET": stateURL.path,
            "RACE_ENTERED": enteredURL.path,
            "RACE_RELEASE": releaseURL.path,
        ]
        let staleDelete = try Self.startShell(
            AmxBackend.bridgeStateFileRemoveRemoteScript(
                stateFilePath: stateURL.path,
                remoteSocketPath: oldChannel.remoteSocketPath
            ),
            environment: environment
        )
        try #require(await Self.waitForFile(enteredURL))

        let successorCompletion = ProcessCompletionSignal()
        let successorWriteProcess = try Self.startShell(
            try #require(AmxBackend.bridgeStateFileWriteRemoteScript(channel: successor)),
            stdin: successorWrite.stdinData,
            completion: successorCompletion,
        )
        let successorFinishedBeforeDelete = successorCompletion.wait(timeout: 0.3)
        try Data().write(to: releaseURL)
        staleDelete.waitUntilExit()
        successorWriteProcess.waitUntilExit()

        #expect(!successorFinishedBeforeDelete)
        #expect(staleDelete.terminationStatus == 0)
        #expect(successorWriteProcess.terminationStatus == 0)
        let finalState = try JSONDecoder().decode(
            BridgeStateFile.self,
            from: Data(contentsOf: stateURL)
        )
        #expect(finalState.socket == successor.remoteSocketPath)
        #expect(finalState.token == successor.token)
    }

    @Test("a signalled holder cannot remove its successor's lease")
    func signalledHolderCannotRemoveSuccessorLease() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-lock-signal-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let lockURL = URL(fileURLWithPath: stateURL.path + ".lock", isDirectory: true)
        let firstEnteredURL = root.appendingPathComponent("first-entered")
        let secondEnteredURL = root.appendingPathComponent("second-entered")
        let secondReleaseURL = root.appendingPathComponent("second-release")
        let first = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(firstEnteredURL.path));"
                    + " while [ ! -e \(Self.shellQuote(root.appendingPathComponent("never-release").path)) ];"
                    + " do sleep 0.01; done"
            )
        )
        try #require(await Self.waitForFile(firstEnteredURL))
        let second = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(secondEnteredURL.path));"
                    + " while [ ! -e \(Self.shellQuote(secondReleaseURL.path)) ];"
                    + " do sleep 0.01; done"
            )
        )

        first.terminate()
        try #require(await Self.waitForFile(secondEnteredURL))
        first.waitUntilExit()
        #expect(first.terminationStatus != 0)
        #expect(fileManager.fileExists(atPath: lockURL.path))
        #expect(second.isRunning)

        try Data().write(to: secondReleaseURL)
        second.waitUntilExit()
        #expect(second.terminationStatus == 0)
        #expect(!fileManager.fileExists(atPath: lockURL.path))
    }

    @Test("an owner publishing its lease cannot have its empty lock parent stolen")
    func publishingLeaseCannotHaveParentStolen() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-lock-publish-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        let wrapperDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let lockURL = URL(fileURLWithPath: stateURL.path + ".lock", isDirectory: true)
        let parentPublishedURL = root.appendingPathComponent("parent-published")
        let releasePublisherURL = root.appendingPathComponent("release-publisher")
        let firstEnteredURL = root.appendingPathComponent("first-entered")
        let secondEnteredURL = root.appendingPathComponent("second-entered")
        let mkdirWrapper = wrapperDirectory.appendingPathComponent("mkdir")
        let wrapper = """
            #!/bin/sh
            /bin/mkdir "$@"
            status=$?
            if [ "$status" -eq 0 ]; then
                for argument in "$@"; do
                    if [ "$argument" = "$RACE_LOCK" ]; then
                        : > "$RACE_PARENT_PUBLISHED"
                        while [ ! -e "$RACE_RELEASE_PUBLISHER" ]; do sleep 0.01; done
                        break
                    fi
                done
            fi
            exit "$status"
            """
        try Data(wrapper.utf8).write(to: mkdirWrapper)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mkdirWrapper.path)
        let first = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(firstEnteredURL.path))"
            ),
            environment: [
                "PATH": wrapperDirectory.path + ":/usr/bin:/bin",
                "RACE_LOCK": lockURL.path,
                "RACE_PARENT_PUBLISHED": parentPublishedURL.path,
                "RACE_RELEASE_PUBLISHER": releasePublisherURL.path,
            ]
        )
        let parentPublished = await Self.waitForFile(parentPublishedURL)
        if !parentPublished {
            try Data().write(to: releasePublisherURL)
            first.waitUntilExit()
        }
        try #require(parentPublished)

        let secondCompletion = ProcessCompletionSignal()
        let second = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(secondEnteredURL.path))"
            ),
            completion: secondCompletion
        )
        let secondFinishedBeforePublication = secondCompletion.wait(timeout: 0.3)
        let secondEnteredBeforePublication = fileManager.fileExists(atPath: secondEnteredURL.path)
        try Data().write(to: releasePublisherURL)
        first.waitUntilExit()
        second.waitUntilExit()

        #expect(!secondFinishedBeforePublication)
        #expect(!secondEnteredBeforePublication)
        #expect(first.terminationStatus == 0)
        #expect(second.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: firstEnteredURL.path))
        #expect(fileManager.fileExists(atPath: secondEnteredURL.path))
        #expect(!fileManager.fileExists(atPath: lockURL.path))
    }

    @Test("an abandoned empty lock parent fails closed after the bounded wait")
    func abandonedEmptyParentFailsClosed() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-lock-abandoned-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let lockURL = URL(fileURLWithPath: stateURL.path + ".lock", isDirectory: true)
        let enteredURL = root.appendingPathComponent("entered")
        try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)

        let completion = ProcessCompletionSignal()
        let process = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(enteredURL.path))"
            ),
            completion: completion
        )
        let finishedWithinBound = completion.wait(timeout: 45)
        if !finishedWithinBound { process.terminate() }
        process.waitUntilExit()

        #expect(finishedWithinBound)
        #expect(process.terminationStatus != 0)
        #expect(!fileManager.fileExists(atPath: enteredURL.path))
        #expect(fileManager.fileExists(atPath: lockURL.path))
    }

    @Test("an unknown identity for a live incumbent cannot reclaim its lease")
    func unknownLiveIncumbentIdentityRetainsLease() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-lock-identity-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        let wrapperDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.createDirectory(at: wrapperDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let firstEnteredURL = root.appendingPathComponent("first-entered")
        let releaseFirstURL = root.appendingPathComponent("release-first")
        let lookupAttemptedURL = root.appendingPathComponent("lookup-attempted")
        let secondEnteredURL = root.appendingPathComponent("second-entered")
        let first = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(firstEnteredURL.path));"
                    + " while [ ! -e \(Self.shellQuote(releaseFirstURL.path)) ];"
                    + " do sleep 0.01; done"
            )
        )
        let firstEntered = await Self.waitForFile(firstEnteredURL)
        if !firstEntered {
            try Data().write(to: releaseFirstURL)
            first.waitUntilExit()
        }
        try #require(firstEntered)

        let psWrapper = wrapperDirectory.appendingPathComponent("ps")
        let wrapper = """
            #!/bin/sh
            for argument in "$@"; do
                if [ "$argument" = "$RACE_INCUMBENT_PID" ]; then
                    : > "$RACE_LOOKUP_ATTEMPTED"
                    exit 0
                fi
            done
            exec /bin/ps "$@"
            """
        try Data(wrapper.utf8).write(to: psWrapper)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: psWrapper.path)
        let second = try Self.startShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(secondEnteredURL.path))"
            ),
            environment: [
                "PATH": wrapperDirectory.path + ":/usr/bin:/bin",
                "RACE_INCUMBENT_PID": String(first.processIdentifier),
                "RACE_LOOKUP_ATTEMPTED": lookupAttemptedURL.path,
            ]
        )
        let lookupAttempted = await Self.waitForFile(lookupAttemptedURL)
        let secondEnteredWhileFirstHeldLease = fileManager.fileExists(atPath: secondEnteredURL.path)
        try Data().write(to: releaseFirstURL)
        first.waitUntilExit()
        second.waitUntilExit()

        #expect(lookupAttempted)
        #expect(!secondEnteredWhileFirstHeldLease)
        #expect(first.terminationStatus == 0)
        #expect(second.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: secondEnteredURL.path))
    }

    @Test("a reused live PID with a different process identity is stale")
    func reusedPIDLeaseIsRecovered() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-lock-pid-reuse-\(UUID().uuidString)", isDirectory: true)
        let bridgeDirectory = root.appendingPathComponent("bridge", isDirectory: true)
        try fileManager.createDirectory(
            at: bridgeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: root) }

        let stateURL = bridgeDirectory.appendingPathComponent("abc123-bridge.json")
        let lockURL = URL(fileURLWithPath: stateURL.path + ".lock", isDirectory: true)
        try fileManager.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let staleLeaseURL = lockURL.appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier).deadbeef",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staleLeaseURL, withIntermediateDirectories: false)
        let acquiredURL = root.appendingPathComponent("acquired")

        try Self.runShell(
            AmxBackend.bridgeStateFileLockedRemoteScript(
                stateFilePath: stateURL.path,
                criticalSection: ": > \(Self.shellQuote(acquiredURL.path))"
            )
        )

        #expect(fileManager.fileExists(atPath: acquiredURL.path))
        #expect(!fileManager.fileExists(atPath: lockURL.path))
    }

    // MARK: - Remote-command env prefix

    @Test("env prefix carries EXACTLY three AWESOMUX_BRIDGE_* vars")
    func envPrefixExactlyThreeVars() {
        let command = AmxBackend.bridgeEnvironmentPrefixedRemoteCommand(
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID,
            helperPath: "/usr/local/bin/awesomux-remote-helper",
            remoteCommand: "zmx attach remote-id"
        )
        let bridgeVarCount = command.components(separatedBy: "AWESOMUX_BRIDGE_").count - 1
        #expect(bridgeVarCount == 3)
        #expect(command.contains("'AWESOMUX_BRIDGE_STATE=/Users/example/.awesomux/bridge/abc123-bridge.json'"))
        #expect(command.contains("'AWESOMUX_BRIDGE_SESSION=abc123-bridge'"))
        #expect(command.contains("'AWESOMUX_BRIDGE_HELPER=/usr/local/bin/awesomux-remote-helper'"))
        #expect(command.hasSuffix("zmx attach remote-id"))
        // No secret (token/socket) ever rides this env prefix.
        #expect(!command.contains("token"))
        #expect(!command.contains(".sock"))
    }

    @Test("env prefix belt-and-braces -u-scrubs the local status pair before its assignments")
    func envPrefixScrubsStatusPair() {
        let command = AmxBackend.bridgeEnvironmentPrefixedRemoteCommand(
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID,
            helperPath: "/usr/local/bin/awesomux-remote-helper",
            remoteCommand: "zmx attach remote-id"
        )
        // Defense-in-depth against a promiscuous `SendEnv AMX_STATUS_*` +
        // `AcceptEnv` leaking the LOCAL status channel into the remote session.
        #expect(command.contains("-u AMX_STATUS_FILE"))
        #expect(command.contains("-u AMX_STATUS_TOKEN"))
        // `env` honors `-u` before NAME=VALUE only in argv order — the scrub
        // must precede the bridge assignments.
        if let scrubIndex = command.range(of: "-u AMX_STATUS_FILE")?.lowerBound,
           let assignIndex = command.range(of: "'AWESOMUX_BRIDGE_STATE=")?.lowerBound {
            #expect(scrubIndex < assignIndex)
        } else {
            Issue.record("expected both the status scrub and the bridge assignment")
        }
        // The status pair is scrubbed, never re-assigned on the bridge prefix.
        #expect(!command.contains("'AMX_STATUS_FILE="))
        #expect(!command.contains("'AMX_STATUS_TOKEN="))
    }

    @Test("bridge attach injects its environment on the managed target")
    func bridgeAttachInjectsEnvironmentAfterSSHDestination() throws {
        let status = AmxStatusChannel(
            fileURL: URL(fileURLWithPath: "/tmp/amx/abc123.status.jsonl"),
            token: "aabbccddeeff0011aabbccddeeff0011"
        )
        let command = try #require(AmxBackend.bridgeAttachCommand(
            executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
            sessionID: Self.sessionID,
            socketDirectory: "/tmp/amx",
            status: status,
            remote: Self.remote,
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            helperPath: "/Users/example/.awesomux/bin/awesomux-bridge-helper"
        ))

        let destination = try #require(command.range(of: "'alice@box'"))
        let stateAssignment = try #require(command.range(
            of: "AWESOMUX_BRIDGE_STATE=/Users/example/.awesomux/bridge/abc123-bridge.json"
        ))
        #expect(destination.lowerBound < stateAssignment.lowerBound)
        #expect(command.contains("'ssh'"))
        #expect(command.contains("'-t'"))
        #expect(command.contains("\"$SHELL\" -l"))
        #expect(!command.contains("exec \"$SHELL\""))
        #expect(command.contains("'AMX_STATUS_FILE=/tmp/amx/abc123.status.jsonl'"))
    }

    @Test("bridgeAttachCommand never carries shell-integration tokens")
    func bridgeAttachCommandStaysClean() throws {
        // Remote-only by construction: the far host doesn't have the bundled
        // ghostty resources dir, so this overload never threads the Task 1
        // shell-integration params through at all — assert the output stays
        // byte-identical to the pre-Task-2 shape.
        let status = AmxStatusChannel(
            fileURL: URL(fileURLWithPath: "/tmp/amx/abc123.status.jsonl"),
            token: "aabbccddeeff0011aabbccddeeff0011"
        )
        let command = try #require(
            AmxBackend.bridgeAttachCommand(
                executablePath: "/Apps/awesoMux.app/Contents/MacOS/amx",
                sessionID: Self.sessionID,
                socketDirectory: "/tmp/amx",
                status: status,
                remote: Self.remote,
                stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
                helperPath: "/Users/example/.awesomux/bin/awesomux-bridge-helper"
            ))
        #expect(!command.contains("ZDOTDIR"))
    }

    // MARK: - Scrub anchor: exact-name -u tokens, no globs

    /// Extracts the value following each `-u` flag — exact names only, never
    /// a glob (`env -u` can't glob `AWESOMUX_AGENT_*`).
    private func scrubbedNames(in command: String) -> Set<String> {
        let parts = command.components(separatedBy: " ")
        var names: Set<String> = []
        for (index, part) in parts.enumerated() where part == "-u" {
            guard index + 1 < parts.count else { continue }
            names.insert(parts[index + 1])
        }
        return names
    }

    @Test("remote attach explicitly -u-scrubs every pane-scoped agent key and the status pair")
    func remoteAttachScrubsAgentAndStatusKeys() throws {
        let command = try #require(AmxBackend.attachCommand(
            executablePath: "/Apps/amx",
            sessionID: Self.sessionID,
            socketDirectory: "/tmp/amx",
            remote: Self.remote
        ))
        let names = scrubbedNames(in: command)
        #expect(names.isSuperset(of: Self.sshCrossingScrubKeys))
        #expect(names.isSuperset(of: ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_LOG_MODE"]))
        // Sanity: the enumerated set really includes the three keys the spec
        // names verbatim.
        #expect(names.contains("AWESOMUX_AGENT_EVENT_FILE"))
        #expect(names.contains("AMX_STATUS_FILE"))
        #expect(names.contains("AMX_STATUS_TOKEN"))
    }

    @Test("local attach never scrubs the pane-scoped agent keys the local hook depends on")
    func localAttachPreservesAgentKeys() throws {
        // The pane shell the daemon spawns inherits its env through this
        // command; the local agent hook reads AWESOMUX_AGENT_EVENT_FILE from
        // that inherited environment, so a local scrub would sever the local
        // agent side channel.
        let command = try #require(AmxBackend.attachCommand(
            executablePath: "/Apps/amx",
            sessionID: Self.sessionID,
            socketDirectory: "/tmp/amx"
        ))
        let names = scrubbedNames(in: command)
        for key in AgentRuntimeEnvironmentKey.paneScopedKeys {
            #expect(!names.contains(key), "local attach must not scrub \(key)")
        }
        // The stale-status defense stays on for local attaches: a nested
        // awesoMux launch inherits the parent's status file AND its matching
        // token, which would validate against the wrong instance.
        #expect(names.isSuperset(of: ["AMX_STATUS_FILE", "AMX_STATUS_TOKEN"]))
    }

    @Test("status overload re-assigns the fresh status pair after the -u scrub in argv order")
    func statusOverloadScrubThenAssignOrder() throws {
        let channel = AmxStatusChannel(
            fileURL: URL(fileURLWithPath: "/tmp/amx/abc123-bridge-deadbeef.status.jsonl"),
            token: "deadbeef01234567deadbeef01234567"
        )
        let command = try #require(AmxBackend.attachCommand(
            executablePath: "/Apps/amx",
            sessionID: Self.sessionID,
            socketDirectory: "/tmp/amx",
            status: channel,
            remote: Self.remote
        ))
        // `env` applies `-u` flags before NAME=VALUE arguments, but only in
        // argv order — the fresh assignment must come after the scrub or the
        // daemon starts with no status channel at all.
        let scrubIndex = try #require(command.range(of: "-u AMX_STATUS_FILE")?.lowerBound)
        let assignIndex = try #require(command.range(of: "'AMX_STATUS_FILE=")?.lowerBound)
        #expect(scrubIndex < assignIndex)
        #expect(command.contains("'AMX_STATUS_TOKEN=deadbeef01234567deadbeef01234567'"))
        // Remote + status still scrubs the agent keys.
        #expect(scrubbedNames(in: command).isSuperset(of: Self.sshCrossingScrubKeys))
    }

    @Test("scrubbed agent vars are never assigned in the emitted command")
    func scrubbedVarsAbsentFromInjectedEnv() throws {
        let command = try #require(AmxBackend.attachCommand(
            executablePath: "/Apps/amx",
            sessionID: Self.sessionID,
            socketDirectory: "/tmp/amx",
            remote: Self.remote
        ))
        // The attach command never assigns agent keys — only ZMX_DIR /
        // ZMX_DIR_MODE (and, in the status overload, the fresh status pair).
        for key in AgentRuntimeEnvironmentKey.paneScopedKeys {
            #expect(!command.contains("'\(key)="))
        }
    }

    @Test("no glob deletion anywhere in any emitted bridge command")
    func noGlobDeletionAnywhere() throws {
        let channel = BridgeChannel(
            token: "token", gen: 1,
            localSocketPath: "/tmp/local.sock",
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock",
            stateFilePath: "/Users/example/.awesomux/bridge/abc123-bridge.json",
            session: Self.sessionID
        )
        let status = AmxStatusChannel(
            fileURL: URL(fileURLWithPath: "/tmp/amx/abc123-bridge-aabb.status.jsonl"),
            token: "aabbccddeeff0011aabbccddeeff0011"
        )
        let commands = [
            AmxBackend.bridgeHomeResolutionCommand(controlPath: "/tmp/ctl/%C", remote: Self.remote),
            try #require(AmxBackend.bridgeStateFileWriteCommand(
                controlPath: "/tmp/ctl/%C", remote: Self.remote, channel: channel
            )).command,
            AmxBackend.bridgeEnvironmentPrefixedRemoteCommand(
                stateFilePath: channel.stateFilePath,
                session: Self.sessionID,
                helperPath: "/usr/local/bin/awesomux-remote-helper",
                remoteCommand: "zmx attach remote-id"
            ),
            try #require(AmxBackend.attachCommand(
                executablePath: "/Apps/amx", sessionID: Self.sessionID, socketDirectory: "/tmp/amx"
            )),
            try #require(
                AmxBackend.attachCommand(
                    executablePath: "/Apps/amx", sessionID: Self.sessionID,
                    socketDirectory: "/tmp/amx", status: status, remote: Self.remote
                )),
        ]
        for command in commands {
            assertNoGlobDeletion(in: command)
        }
    }

    private func assertNoGlobDeletion(in command: String) {
        #expect(!command.contains("rm -f *"))
        #expect(!command.contains("rm -rf *"))
        #expect(!command.contains("bridge/*"))
        #expect(!command.contains("find "))
    }

    private static func runShell(_ script: String, stdin: Data? = nil) throws {
        let process = try startShell(script, stdin: stdin)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShellRaceError.failed(process.terminationStatus)
        }
    }

    private static func startShell(
        _ script: String,
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        completion: ProcessCompletionSignal? = nil,
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let completion {
            process.terminationHandler = { _ in completion.signal() }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            try pipe.fileHandleForWriting.write(contentsOf: stdin)
            try pipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        return process
    }

    private static func waitForFile(_ url: URL) async -> Bool {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum ShellRaceError: Error {
    case failed(Int32)
}

private final class ProcessCompletionSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
