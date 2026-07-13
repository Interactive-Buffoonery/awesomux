import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// Assembly-only coverage for INT-698 D1: the pure string builders that will
// feed the attach sequence's exec-channel writes and env injection. No live ssh here —
// these tests only assert on the assembled strings, mirroring
// `AmxBackendAttachCommandTests`'s injectable-seam style.
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
            for option in ["-o ControlMaster=auto", "-o ControlPersist=60",
                           "-o ServerAliveInterval=15", "-o ForwardAgent=no"] {
                let match = command.range(of: option)
                #expect(match != nil, "missing \(option): \(command)")
                if let match {
                    #expect(match.upperBound <= optionRegionEnd,
                            "\(option) landed after `--` (inert): \(command)")
                }
            }
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
        #expect(write.command.contains("cat > \"$tmp\""))
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
            try #require(AmxBackend.attachCommand(
                executablePath: "/Apps/amx", sessionID: Self.sessionID,
                socketDirectory: "/tmp/amx", status: status, remote: Self.remote
            ))
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
}
