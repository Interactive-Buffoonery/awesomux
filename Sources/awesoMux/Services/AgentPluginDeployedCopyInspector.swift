import Foundation

/// Inspects the plugin copy a provider CLI actually deploys — Claude's
/// version-keyed cache snapshot, Codex's registered plugin directory — against
/// what the running app would render today.
///
/// The install-record staleness gate can only see the installing app's own
/// bookkeeping; it is blind to whatever the provider CLI currently executes.
/// That blindness caused INT-882: an app replaced in place left Claude serving
/// a months-old snapshot while every record looked fresh, and Repair no-op'd
/// against the version-keyed cache. This inspector reads the deployed bytes so
/// status and the clean-reinstall gate act on provider-side reality instead.
enum AgentPluginDeployedCopyInspector {
    struct Finding: Equatable, Sendable {
        /// The deployed hook config differs from the freshly rendered one.
        var differsFromCurrentRender: Bool
        /// At least one resolution route survives: a runtime-resolution ladder
        /// is baked in (self-healing through Spotlight), or one of the baked
        /// helper paths still points at an executable.
        var helperReachable: Bool
        /// First baked absolute helper path found, for error copy.
        var firstBakedHelperPath: String?
    }

    /// Reads the deployed hook config at `deployedHooksURL` and compares it to
    /// the freshly rendered bytes. Returns `nil` when the deployed file is
    /// missing or unreadable — an undeployable check must never invent a
    /// failure, so callers fall back to their previous signal rather than flip
    /// a healthy install on a transient filesystem error.
    static func assess(
        deployedHooksURL: URL,
        renderedHooksData: Data,
        fileManager: FileManager = .default
    ) -> Finding? {
        guard let deployedData = try? Data(contentsOf: deployedHooksURL) else {
            return nil
        }
        return assess(deployedHooksData: deployedData, renderedHooksData: renderedHooksData, fileManager: fileManager)
    }

    static func assess(
        deployedHooksData: Data,
        renderedHooksData: Data,
        fileManager: FileManager = .default
    ) -> Finding? {
        let commands = hookCommands(in: deployedHooksData)
        guard !commands.isEmpty else {
            return nil
        }
        let bakedPaths = commands.flatMap { bakedHelperPaths(in: $0) }
        let usesLadder = commands.contains { $0.contains("mdfind") }
        let reachable =
            usesLadder
            || bakedPaths.contains { fileManager.isExecutableFile(atPath: $0) }
        return Finding(
            differsFromCurrentRender: deployedHooksData != renderedHooksData,
            helperReachable: reachable,
            firstBakedHelperPath: bakedPaths.first
        )
    }

    /// Hook command strings from a rendered/deployed `hooks.json` shape:
    /// `{ "hooks": { "<Event>": [ { "hooks": [ { "command": … } ] } ] } }`.
    static func hookCommands(in hooksJSON: Data) -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: hooksJSON),
            let hooks = root as? [String: Any],
            let events = hooks["hooks"] as? [String: Any]
        else {
            return []
        }
        var commands: [String] = []
        for event in events.values {
            guard let matchers = event as? [[String: Any]] else { continue }
            for matcher in matchers {
                guard let entries = matcher["hooks"] as? [[String: Any]] else { continue }
                for entry in entries {
                    if let command = entry["command"] as? String {
                        commands.append(command)
                    }
                }
            }
        }
        return commands
    }

    /// Absolute paths baked into a hook command that target the awesoMuxAgentHook
    /// executable. Commands are plain POSIX-sh text, so candidates are `/…` runs
    /// terminated by whitespace or a quote.
    static func bakedHelperPaths(in command: String) -> [String] {
        let name = AgentRuntimeEnvironment.hookExecutableName
        var paths: [String] = []
        var searchStart = command.startIndex
        while let nameRange = command.range(of: name, range: searchStart..<command.endIndex) {
            // Walk back to the start of the `/…` run containing the name:
            // advance while the previous character is not a terminator.
            var start = nameRange.lowerBound
            while start > command.startIndex {
                let previous = command.index(before: start)
                if isPathTerminator(command[previous]) {
                    break
                }
                start = previous
            }
            guard command[start] == "/" else {
                searchStart = nameRange.upperBound
                continue
            }
            var end = nameRange.upperBound
            while end < command.endIndex, !isPathTerminator(command[end]) {
                end = command.index(after: end)
            }
            // Rooted by the guard above, and containing `name` by construction.
            paths.append(String(command[start..<end]))
            searchStart = end
        }
        return paths
    }

    private static func isPathTerminator(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "'" || character == "\"" || character == "\n"
    }
}
