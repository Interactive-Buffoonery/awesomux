import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

struct AgentSetup: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var provider: AgentKind
    var executablePath: String
    var arguments: [String] = []
    var enabled = true

    static let providers: [AgentKind] = [.claudeCode, .codex, .openCode, .pi, .grok]

    static func supportsShell(_ command: String) -> Bool {
        ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(ShellRecognition.basename(command))
    }

    static func canSubmit(foreground: String?, promptIsAway: Bool?) -> Bool {
        foreground.map(supportsShell) == true && promptIsAway == false
    }

    static func launchDirectory(session: TerminalSession?, groups: [SessionGroup], defaultGroup: String) throws -> String {
        guard let session, let pane = session.activePane, pane.executionPlan.remoteTarget == nil, !pane.hasManagedSSHObservation,
            !groups.contains(where: {
                SessionStore.groupLookupKey($0.name).caseInsensitiveCompare(SessionStore.groupLookupKey(defaultGroup)) == .orderedSame
                    && $0.remote != nil
            })
        else {
            throw LaunchError(
                message: String(
                    localized: "Agent setups launch local executables. Select a local pane and a local default workspace group."))
        }
        let directory = session.activePane?.workingDirectory ?? session.workingDirectory
        guard let validated = WorkingDirectoryValidator.validatedStartupDirectory(directory) else {
            throw LaunchError(
                message: String(
                    localized:
                        "The current directory cannot be used to launch an agent setup. Choose an accessible directory owned by your user.",
                    comment: "Agent setup launch rejected by the shared startup directory safety check"))
        }
        return validated
    }

    var validationError: String? {
        guard !CustomCommandStore.sanitizedName(name).isEmpty else {
            return String(localized: "Enter a name for this agent setup.")
        }
        guard Self.providers.contains(provider), executablePath.hasPrefix("/") else {
            return String(localized: "Choose an agent provider and an absolute executable path.")
        }
        let tokens = [executablePath] + arguments
        guard
            tokens.allSatisfy({ token in
                !token.unicodeScalars.contains { $0.properties.generalCategory == .control }
                    && !token.contains(where: \.isNewline)
                    && !CustomCommandStore.commandHasDisallowedScalar(token)
            }), shellCommand.utf8.count <= CustomCommandStore.maxCommandUTF8Bytes
        else {
            return String(localized: "Use a single-line executable path and arguments without control characters, up to 4096 bytes total.")
        }
        return nil
    }

    var shellCommand: String {
        ([executablePath] + arguments).map { token in
            // Closing the single-quoted span around backslashes also preserves
            // them in fish, whose single quotes interpret backslash escapes.
            "'"
                + token.unicodeScalars.map { scalar -> String in
                    switch scalar.value {
                    case 0x27: "'\"'\"'"
                    case 0x5C: "'\"\\\\\"'"
                    default: String(scalar)
                    }
                }.joined() + "'"
        }.joined(separator: " ")
    }

    func launchCommand() throws -> String {
        if let validationError { throw LaunchError(message: validationError) }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executablePath, isDirectory: &directory),
            !directory.boolValue, FileManager.default.isExecutableFile(atPath: executablePath)
        else {
            throw LaunchError(
                message: String(
                    format: String(
                        localized: "The executable for %@ is missing or is not executable: %@",
                        comment: "Setup launch error with name and path"), name, executablePath))
        }
        return shellCommand
    }

    struct LaunchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

@Observable
@MainActor
final class AgentSetupStore {
    static let defaultsKey = "awesomux.agentSetups"
    private(set) var setups: [AgentSetup]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<UUID>()
        let rows =
            defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
        setups = rows.compactMap { row in
            guard JSONSerialization.isValidJSONObject(row),
                let data = try? JSONSerialization.data(withJSONObject: row),
                var setup = try? JSONDecoder().decode(AgentSetup.self, from: data),
                setup.validationError == nil, seen.insert(setup.id).inserted
            else { return nil }
            setup.name = CustomCommandStore.sanitizedName(setup.name)
            return setup
        }
    }

    func setup(id: UUID) -> AgentSetup? { setups.first { $0.id == id } }

    @discardableResult
    func save(_ setup: AgentSetup) -> Bool {
        guard setup.validationError == nil else { return false }
        var setup = setup
        setup.name = CustomCommandStore.sanitizedName(setup.name)
        if let index = setups.firstIndex(where: { $0.id == setup.id }) {
            setups[index] = setup
        } else {
            setups.append(setup)
        }
        persist()
        return true
    }

    func remove(id: UUID) {
        setups.removeAll { $0.id == id }
        persist()
    }

    func move(id: UUID, offset: Int) {
        guard let index = setups.firstIndex(where: { $0.id == id }),
            setups.indices.contains(index + offset)
        else { return }
        setups.swapAt(index, index + offset)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(setups) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
