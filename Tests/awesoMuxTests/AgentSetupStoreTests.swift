import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite("Agent setups")
@MainActor
struct AgentSetupStoreTests {
    @Test func submissionWaitsForTheShellPrompt() {
        #expect(!AgentSetup.canSubmit(foreground: "zsh", promptIsAway: true))
        #expect(!AgentSetup.canSubmit(foreground: "zsh", promptIsAway: nil))
        #expect(!AgentSetup.canSubmit(foreground: nil, promptIsAway: false))
        #expect(!AgentSetup.canSubmit(foreground: "fastfetch", promptIsAway: false))
        #expect(AgentSetup.canSubmit(foreground: "zsh", promptIsAway: false))
    }

    @Test func launchContextUsesActivePaneAndRejectsRemoteDestination() throws {
        let store = SessionStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-setup-cwd-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonicalDirectory = WorkingDirectoryValidator.canonicalizedPath(directory.path)
        let id = store.addSession(workingDirectory: directory.path)
        let session = try #require(store.session(id: id))
        #expect(try AgentSetup.launchDirectory(session: session, groups: store.groups, defaultGroup: "awesoMux") == canonicalDirectory)
        var split = session
        split.workingDirectory = "/different-session-directory"
        #expect(try AgentSetup.launchDirectory(session: split, groups: store.groups, defaultGroup: "awesoMux") == canonicalDirectory)
        let rootOwnedSession = TerminalSession(title: "System directory", workingDirectory: "/tmp")
        #expect(throws: (any Error).self) {
            try AgentSetup.launchDirectory(session: rootOwnedSession, groups: [], defaultGroup: "local")
        }
        let target = try #require(RemoteTarget(user: "ed", host: "example.com"))
        let remote = SessionGroup(name: "Remote", remote: target, sessions: [])
        let remoteSession = TerminalSession(title: "Remote", workingDirectory: "/tmp", executionPlan: .ssh(SSHExecution(target: target)))
        #expect(throws: (any Error).self) {
            try AgentSetup.launchDirectory(session: remoteSession, groups: [], defaultGroup: "local")
        }
        #expect(throws: (any Error).self) {
            try AgentSetup.launchDirectory(session: session, groups: [remote], defaultGroup: " remote ")
        }
        #expect(AgentSetup.supportsShell("/bin/zsh"))
        #expect(AgentSetup.supportsShell("-fish"))
        #expect(!AgentSetup.supportsShell("nu"))
        #expect(!AgentSetup.supportsShell("claude"))
    }

    @Test func paletteIdentitySurvivesRenameAndUsesFullListPosition() {
        var setup = AgentSetup(name: "First", provider: .codex, executablePath: "/bin/echo")
        let first = PaletteCommand.agentSetup(setup, position: 3) {}
        setup.name = "Renamed"
        let second = PaletteCommand.agentSetup(setup, position: 3) {}
        #expect(first.id == second.id)
        #expect(PaletteCommand.agentSetupUUID(fromID: second.id) == setup.id)
        #expect(second.title.contains("3"))
        #expect(second.subtitle == "Codex")
    }

    @Test func persistenceAndIndependentIdentity() throws {
        let suite = "AgentSetupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentSetupStore(defaults: defaults)
        var first = AgentSetup(name: "Claude", provider: .claudeCode, executablePath: "/bin/echo")
        let second = AgentSetup(name: "Claude", provider: .claudeCode, executablePath: "/bin/echo")
        #expect(store.save(first))
        #expect(store.save(second))
        first.enabled = false
        first.arguments = ["", "two words"]
        #expect(store.save(first))
        store.move(id: second.id, offset: -1)
        #expect(AgentSetupStore(defaults: defaults).setups == [second, first])
        store.remove(id: second.id)
        #expect(AgentSetupStore(defaults: defaults).setups == [first])
    }

    @Test func invalidRowsDoNotEraseNeighborsOrClaimIDs() throws {
        let suite = "AgentSetupTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = AgentSetup(name: "Keep", provider: .codex, executablePath: "/bin/echo")
        var invalid = valid
        invalid.executablePath = "alias"
        let rows = try [invalid, valid, valid].map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        let payload = try JSONSerialization.data(withJSONObject: [["bad": true]] + rows)
        defaults.set(payload, forKey: AgentSetupStore.defaultsKey)
        #expect(AgentSetupStore(defaults: defaults).setups == [valid])
        #expect(defaults.data(forKey: AgentSetupStore.defaultsKey) == payload)
    }

    @Test func validatesPathsAndLiteralArguments() throws {
        var setup = AgentSetup(name: "Run", provider: .codex, executablePath: "/bin/echo")
        setup.arguments = ["", " two words ", "a'b", #"a\b"#, "$(touch forbidden)"]
        #expect(setup.validationError == nil)
        for path in ["echo", "~/bin/echo", "/bin/echo\nwhoami"] {
            setup.executablePath = path
            #expect(setup.validationError != nil)
        }
        setup.executablePath = "/bin/echo"
        setup.arguments = ["bad\nargument"]
        #expect(setup.validationError != nil)
        for control in ["\u{1B}[2J", "\0", "\t", "\u{7F}"] {
            setup.arguments = [control]
            #expect(setup.validationError != nil)
        }
        setup.arguments = []
        setup.provider = .shell
        #expect(setup.validationError != nil)
    }

    @Test func quotedTokensRoundTrip() throws {
        let arguments = [
            "", "two words", "a'b", #"a\b"#, #"a\'b"#, "$HOME; echo bad", "`whoami`", "'\u{301}; printf INJECTED; #", "\\\u{301}'",
        ]
        let setup = AgentSetup(name: "Print", provider: .codex, executablePath: "/usr/bin/printf", arguments: ["%s\\0"] + arguments)
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish"].filter({
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            let process = Process()
            defer { if process.isRunning { process.terminate() } }
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-c", try setup.launchCommand()]
            let output = try captureOutput(of: process)
            #expect(process.terminationStatus == 0)
            #expect(output.stdout.components(separatedBy: "\0") == arguments + [""])
        }
    }

    @Test func unavailableExecutablesFailBeforeLaunch() {
        for path in ["/no-such-agent-555", "/tmp", "/etc/hosts"] {
            let setup = AgentSetup(name: "Missing", provider: .codex, executablePath: path)
            #expect(throws: (any Error).self) { try setup.launchCommand() }
        }
    }
}
