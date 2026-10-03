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
    /// Resolves a Spotlight bundle identifier baked into a runtime-resolution
    /// ladder to whether an executable hook helper currently sits behind it —
    /// the same `mdfind "kMDItemCFBundleIdentifier == '<id>'" | while … [ -x … ]`
    /// resolution the baked hook performs at invocation time. Returning `nil`
    /// means the lookup itself could not be performed; callers must treat an
    /// unknown ladder as still viable rather than invent a failure.
    typealias LadderProbe = @Sendable (_ bundleIdentifier: String) async -> Bool?

    typealias ResolvedProbe = @Sendable (_ bundleIdentifier: String) -> Bool?

    struct Finding: Equatable, Sendable {
        /// The deployed hook config differs from the freshly rendered one.
        var differsFromCurrentRender: Bool
        /// At least one resolution route survives right now: one of the baked
        /// helper paths is an executable, or every baked runtime-resolution
        /// ladder resolves through Spotlight to an executable helper (or its
        /// resolution cannot be determined).
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
        fileManager: FileManager = .default,
        ladderProbe: LadderProbe? = nil
    ) async -> Finding? {
        guard let deployedData = try? Data(contentsOf: deployedHooksURL) else {
            return nil
        }
        return await assess(
            deployedHooksData: deployedData,
            renderedHooksData: renderedHooksData,
            fileManager: fileManager,
            ladderProbe: ladderProbe
        )
    }

    static func assess(
        deployedHooksData: Data,
        renderedHooksData: Data,
        fileManager: FileManager = .default,
        ladderProbe: LadderProbe? = nil
    ) async -> Finding? {
        let commands = hookCommands(in: deployedHooksData)
        guard !commands.isEmpty else {
            return nil
        }
        let ladderProbe = await resolveLadders(
            deployed: deployedHooksData, rendered: renderedHooksData,
            fileManager: fileManager, ladderProbe: ladderProbe
        )
        guard !Task.isCancelled else { return nil }
        let reachability = helperReachability(
            ofCommands: commands,
            fileManager: fileManager,
            ladderProbe: ladderProbe
        )
        return Finding(
            differsFromCurrentRender: contentDrift(
                deployed: deployedHooksData,
                rendered: renderedHooksData,
                ladderProbe: ladderProbe
            ),
            helperReachable: reachability.reachable,
            firstBakedHelperPath: reachability.firstBakedHelperPath
        )
    }

    /// Whether the deployed hooks differ from this build's render in *content*.
    /// Rendering bakes environment-specific values — the installing app's
    /// helper path and Spotlight bundle identifier — that a dev↔release switch
    /// re-bakes without changing hook behavior. Comparing raw bytes would make
    /// whichever build did not install last show a permanent update offer that
    /// Repair can only flip to the other build, so helper paths are always
    /// masked before comparing.
    ///
    /// Bundle identifiers are masked *conditionally*: a side's id is masked
    /// only when its own ladder can still resolve an executable helper (or the
    /// resolution cannot be determined). A dead ladder — removed build folder,
    /// obsolete bundle id — is precisely the INT-882 breakage status must
    /// surface, so masking its id would hide Needs-Repair behind a fake
    /// "environment-only" match.
    static func contentDrift(
        deployed: Data,
        rendered: Data,
        ladderProbe: ResolvedProbe? = nil
    ) -> Bool {
        guard let deployedJSON = canonicalHookObject(deployed),
            let renderedJSON = canonicalHookObject(rendered)
        else { return true }
        let deployedBase = String(decoding: deployedJSON, as: UTF8.self)
        let renderedBase = String(decoding: renderedJSON, as: UTF8.self)
        // Identical after path-masking — including identical bundle ids — is
        // drift-free without probing anything (the common healthy case).
        if deployedBase == renderedBase {
            return false
        }
        return maskBundleIDsIfResolvable(deployedBase, data: deployed, ladderProbe: ladderProbe)
            != maskBundleIDsIfResolvable(renderedBase, data: rendered, ladderProbe: ladderProbe)
    }

    // JSON object order and formatting are not hook behavior. Normalize before
    // masking environment-specific strings; preserve array order and command text.
    private static func canonicalHookObject(_ data: Data, maskBundleIDs: Bool = false) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            var events = root["hooks"] as? [String: Any]
        else { return nil }
        for (event, value) in events {
            guard var matchers = value as? [[String: Any]] else { continue }
            for index in matchers.indices {
                guard var entries = matchers[index]["hooks"] as? [[String: Any]] else { continue }
                for entry in entries.indices {
                    guard var command = entries[entry]["command"] as? String else { continue }
                    for literal in helperLiterals(in: command).reversed() {
                        command.replaceSubrange(literal.range, with: "'<HELPER PATH>'")
                    }
                    if maskBundleIDs {
                        command = replacingMatches(
                            of: "kMDItemCFBundleIdentifier == '[^']*'", in: command,
                            with: "kMDItemCFBundleIdentifier == '<BUNDLE ID>'"
                        )
                    }
                    entries[entry]["command"] = command
                }
                matchers[index]["hooks"] = entries
            }
            events[event] = matchers
        }
        root["hooks"] = events
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Masks Spotlight bundle ids in already-path-masked hook text, but only
    /// when the copy's own runtime-resolution ladders still resolve (or cannot
    /// be checked). Copies whose ladders are provably dead keep their ids so
    /// content comparison reads them as drifted from any live render.
    private static func maskBundleIDsIfResolvable(
        _ maskedText: String,
        data: Data,
        ladderProbe: ResolvedProbe?
    ) -> String {
        guard ladderResolves(hookCommands(in: data), ladderProbe: ladderProbe) else {
            return maskedText
        }
        guard let canonical = canonicalHookObject(data, maskBundleIDs: true) else { return maskedText }
        return String(decoding: canonical, as: UTF8.self)
    }

    /// Whether every route a set of hook commands has through the
    /// runtime-resolution ladder still counts as viable: no ladder at all, an
    /// unperformable probe, or at least one baked bundle id resolving to an
    /// executable helper right now. Only a performed lookup that resolves
    /// nothing reads as false — uncertainty never breaks reachability.
    private static func ladderResolves(_ commands: [String], ladderProbe: ResolvedProbe?) -> Bool {
        let bundleIdentifiers = ladderBundleIdentifiers(in: commands)
        if bundleIdentifiers.isEmpty {
            return true
        }
        guard let ladderProbe else {
            return true
        }
        return bundleIdentifiers.contains { ladderProbe($0) ?? true }
    }

    private static func resolveLadders(
        deployed: Data, rendered: Data?, fileManager: FileManager, ladderProbe: LadderProbe?
    ) async -> ResolvedProbe? {
        guard let ladderProbe else { return nil }
        let commands = hookCommands(in: deployed)
        let livePath = commands.flatMap { bakedHelperPaths(in: $0) }
            .contains { fileManager.isExecutableFile(atPath: $0) }
        let needsComparison = rendered.map { canonicalHookObject(deployed) != canonicalHookObject($0) } ?? false
        guard !livePath || needsComparison else { return nil }
        let renderedCommands = needsComparison ? rendered.map { hookCommands(in: $0) } ?? [] : []
        var results: [String: Bool] = [:]
        for identifier in ladderBundleIdentifiers(in: commands + renderedCommands) {
            guard !Task.isCancelled else { return nil }
            if let result = await ladderProbe(identifier) { results[identifier] = result }
        }
        let resolved = results
        return { resolved[$0] }
    }

    /// Bundle identifiers referenced by the runtime-resolution ladders in hook
    /// commands — the `mdfind "kMDItemCFBundleIdentifier == '<id>'"` fallback
    /// routes — in first-appearance order, deduplicated.
    static func ladderBundleIdentifiers(in commands: [String]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "kMDItemCFBundleIdentifier\\s*==\\s*'([^']*)'") else {
            return []
        }
        var identifiers: [String] = []
        for command in commands {
            let range = NSRange(command.startIndex..., in: command)
            for match in regex.matches(in: command, options: [], range: range) {
                guard let capture = Range(match.range(at: 1), in: command) else { continue }
                let identifier = String(command[capture])
                if !identifiers.contains(identifier) {
                    identifiers.append(identifier)
                }
            }
        }
        return identifiers
    }

    /// Unknown subprocess outcomes never establish that a ladder is dead.
    static func systemLadderProbe(_ bundleIdentifier: String) async -> Bool? {
        guard !bundleIdentifier.isEmpty,
            let result = try? await ProcessCommandRunner(timeout: .seconds(5)).run(
                executable: "/usr/bin/mdfind",
                args: ["kMDItemCFBundleIdentifier == '\(bundleIdentifier)'"], env: [:], cwd: nil
            ), result.isSuccess
        else { return nil }
        return result.stdout.split(separator: "\n").contains { appPath in
            FileManager.default.isExecutableFile(
                atPath: "\(appPath)/Contents/MacOS/\(AgentRuntimeEnvironment.hookExecutableName)"
            )
        }
    }

    /// Reads the deployed hook config at the standard `hooks/hooks.json` layout
    /// under `installPath` alongside a freshly rendered one and returns the full
    /// assessment. Returns `nil` when either side is unreadable — an
    /// undeployable check must never invent a failure.
    static func deployedCopyFinding(
        installPath: String,
        renderedHooksURL: URL?,
        fileManager: FileManager = .default,
        ladderProbe: LadderProbe? = nil
    ) async -> Finding? {
        guard let renderedHooksURL else {
            return nil
        }
        let deployedURL = URL(fileURLWithPath: installPath)
            .appending(path: "hooks", directoryHint: .isDirectory)
            .appending(path: "hooks.json")
        guard
            let deployedData = try? Data(contentsOf: deployedURL),
            let renderedData = try? Data(contentsOf: renderedHooksURL)
        else {
            return nil
        }
        return await assess(
            deployedHooksData: deployedData,
            renderedHooksData: renderedData,
            fileManager: fileManager,
            ladderProbe: ladderProbe
        )
    }

    private static func replacingMatches(of pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Reachability-only probe for callers that never compare against a render:
    /// does the deployed hook config still resolve to a runnable helper?
    /// Returns `nil` when the file is missing/unreadable or carries no hook
    /// commands — an undeployable check must never invent a failure.
    static func helperReachability(
        deployedHooksURL: URL,
        fileManager: FileManager = .default,
        ladderProbe: LadderProbe? = nil
    ) async -> Finding? {
        guard let data = try? Data(contentsOf: deployedHooksURL) else {
            return nil
        }
        let commands = hookCommands(in: data)
        guard !commands.isEmpty else {
            return nil
        }
        let ladderProbe = await resolveLadders(
            deployed: data, rendered: nil, fileManager: fileManager, ladderProbe: ladderProbe
        )
        guard !Task.isCancelled else { return nil }
        let reachability = helperReachability(
            ofCommands: commands,
            fileManager: fileManager,
            ladderProbe: ladderProbe
        )
        return Finding(
            differsFromCurrentRender: false,
            helperReachable: reachability.reachable,
            firstBakedHelperPath: reachability.firstBakedHelperPath
        )
    }

    private static func helperReachability(
        ofCommands commands: [String],
        fileManager: FileManager,
        ladderProbe: ResolvedProbe?
    ) -> (reachable: Bool, firstBakedHelperPath: String?) {
        let bakedPaths = commands.flatMap { bakedHelperPaths(in: $0) }
        if bakedPaths.contains(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return (true, bakedPaths.first)
        }
        // A baked absolute path is only the ladder's second rung; once it is
        // dead, reachability rides entirely on the Spotlight fallback resolving
        // to an executable helper right now. Merely *containing* an mdfind
        // query proves nothing — a stale dev deploy can bake a removed build
        // folder and an obsolete bundle id, a ladder that resolves nothing at
        // runtime — so resolve it, and a copy with no ladder at all is simply
        // out of routes.
        let bundleIdentifiers = ladderBundleIdentifiers(in: commands)
        guard !bundleIdentifiers.isEmpty else {
            return (false, bakedPaths.first)
        }
        guard let ladderProbe else {
            // An unperformable lookup never breaks reachability.
            return (true, bakedPaths.first)
        }
        let reachable = bundleIdentifiers.contains { ladderProbe($0) ?? true }
        return (reachable, bakedPaths.first)
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

    /// Reads the renderer's single-quoted literals and escaped apostrophes.
    private static func helperLiterals(in command: String) -> [(range: Range<String.Index>, path: String)] {
        let pattern = "'(?:[^']|'\\\\'')*'"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap { match in
            guard let range = Range(match.range, in: command) else { return nil }
            if range.lowerBound > command.startIndex {
                let previous = command[command.index(before: range.lowerBound)]
                guard previous.isWhitespace || "=([;".contains(previous) else { return nil }
            }
            if range.upperBound < command.endIndex {
                let next = command[range.upperBound]
                guard next.isWhitespace || ";)]|&".contains(next) else { return nil }
            }
            let path = command[range].dropFirst().dropLast().replacingOccurrences(of: "'\\''", with: "'")
            guard path.hasPrefix("/"), path.hasSuffix("/" + AgentRuntimeEnvironment.hookExecutableName) else { return nil }
            return (range, path)
        }
    }

    static func bakedHelperPaths(in command: String) -> [String] {
        helperLiterals(in: command).map(\.path)
    }
}
