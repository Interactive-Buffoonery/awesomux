import AwesoMuxCore
import Foundation

struct PaletteResults {
    let mode: PaletteQueryMode
    let query: String
    let groups: [PaletteResultGroup]
    let defaultSelectionIndex: Int?

    var flattened: [PaletteResult] {
        groups.flatMap(\.results)
    }
}

struct PaletteResultGroup: Identifiable {
    let title: String
    let results: [PaletteResult]

    var id: String { title }
}

struct PaletteSessionResult: Identifiable {
    let sessionID: TerminalSession.ID
    let title: String
    let subtitle: String?
    let groupName: String
    let score: Int

    var id: String { "session.\(sessionID)" }
}

struct PaletteCommandResult: Identifiable {
    let commandID: PaletteCommand.ID
    let title: String
    let subtitle: String?
    let shortcut: KeyBinding?
    let score: Int

    var id: String { "command.\(commandID)" }
}

enum PaletteResult: Identifiable {
    case session(PaletteSessionResult)
    case command(PaletteCommandResult)
    case quickRun(PaletteQuickRunResult)

    var id: String {
        switch self {
        case .session(let result):
            result.id
        case .command(let result):
            result.id
        case .quickRun(let result):
            result.id
        }
    }
}

enum PaletteQueryMode: Equatable {
    case unified
    case actionsOnly
    case quickRun
}

enum PaletteSearch {
    static let defaultSessionLimit = 50

    static func mode(for raw: String) -> (mode: PaletteQueryMode, query: String) {
        // INT-252 claims `>` as an actions-only filter. INT-101 may extend
        // this single parser with quick-run disambiguation later; until that
        // ships, every leading `>` stays inside the command namespace.
        if raw.hasPrefix(">") {
            return (.actionsOnly, String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
        }
        return (.unified, raw.trimmingCharacters(in: .whitespaces))
    }

    static func score(_ needle: String, in haystack: String) -> Int? {
        FuzzyMatcher.match(query: needle, in: haystack)?.score
    }

    @MainActor
    static func results(
        groups: [SessionGroup],
        commands: [PaletteCommand],
        rawQuery: String,
        sessionLimit: Int = defaultSessionLimit,
        quickRunSearchPath: String = ProcessCommandRunner.defaultToolPath
    ) -> PaletteResults {
        let resolved = mode(for: rawQuery)
        let query = resolved.query
        var outputGroups: [PaletteResultGroup] = []

        if resolved.mode == .unified,
           let quickRun = PaletteQuickRunDetector.quickRun(
            for: rawQuery,
            searchPath: quickRunSearchPath
           ) {
            return PaletteResults(
                mode: .quickRun,
                query: query,
                groups: [
                    PaletteResultGroup(title: "Quick Run", results: [.quickRun(quickRun)])
                ],
                defaultSelectionIndex: 0
            )
        }

        if resolved.mode == .unified {
            let sessionResults = sessions(
                in: groups,
                query: query,
                limit: sessionLimit
            )
            if !sessionResults.isEmpty {
                outputGroups.append(PaletteResultGroup(title: "Sessions", results: sessionResults.map(PaletteResult.session)))
            }
        }

        let enabledCommands = commands.filter(\.isEnabled)
        let isUnifiedEmptyQuery = resolved.mode == .unified && query.isEmpty

        if isUnifiedEmptyQuery {
            // Onboarding: a bare palette is otherwise a dead-end for a fresh
            // install with no sessions. Surface a curated set of high-value
            // actions so "New Workspace" / "Open Settings" are one keystroke
            // away instead of hidden behind a typed query.
            let suggested = suggestedCommands(in: enabledCommands)
            if !suggested.isEmpty {
                outputGroups.append(PaletteResultGroup(title: "Suggested", results: suggested.map(PaletteResult.command)))
            }
        } else {
            let commandResults = commandResults(
                in: enabledCommands,
                query: query,
                includeAllWhenEmpty: resolved.mode == .actionsOnly
            )
            if !commandResults.isEmpty {
                outputGroups.append(PaletteResultGroup(title: "Actions", results: commandResults.map(PaletteResult.command)))
            }
        }

        let isBareUnifiedQuery = resolved.mode == .unified
            && rawQuery.trimmingCharacters(in: .whitespaces).isEmpty

        return PaletteResults(
            mode: resolved.mode,
            query: query,
            groups: outputGroups,
            // Product rule: bare Return on an empty palette should not jump
            // workspaces or execute the first action. The UI only gets an
            // implicit selection after the user types or moves explicitly.
            defaultSelectionIndex: isBareUnifiedQuery || outputGroups.isEmpty ? nil : 0
        )
    }

    private static func sessions(
        in groups: [SessionGroup],
        query: String,
        limit: Int
    ) -> [PaletteSessionResult] {
        let cappedLimit = max(0, limit)
        guard cappedLimit > 0 else { return [] }

        var candidates: [(result: PaletteSessionResult, order: Int)] = []
        var order = 0

        groupLoop: for group in groups {
            for session in group.sessions {
                defer { order += 1 }
                let subtitle = sessionSubtitle(for: session)

                if query.isEmpty {
                    candidates.append(
                        (
                            PaletteSessionResult(
                                sessionID: session.id,
                                title: session.title,
                                subtitle: subtitle,
                                groupName: group.name,
                                score: 0
                            ),
                            order
                        )
                    )
                    if candidates.count >= cappedLimit {
                        break groupLoop
                    }
                    continue
                }

                guard let score = bestSessionScore(
                    query: query,
                    title: session.title,
                    subtitle: subtitle,
                    searchLocation: session.sidebarLocation.searchText,
                    groupName: group.name
                ) else {
                    continue
                }

                candidates.append(
                    (
                        PaletteSessionResult(
                            sessionID: session.id,
                            title: session.title,
                            subtitle: subtitle,
                            groupName: group.name,
                            score: score
                        ),
                        order
                    )
                )
            }
        }

        if !query.isEmpty {
            candidates.sort { lhs, rhs in
                if lhs.result.score != rhs.result.score {
                    return lhs.result.score > rhs.result.score
                }
                return lhs.order < rhs.order
            }
        }

        return candidates.prefix(cappedLimit).map(\.result)
    }

    private static func commandResults(
        in commands: [PaletteCommand],
        query: String,
        includeAllWhenEmpty: Bool
    ) -> [PaletteCommandResult] {
        var candidates: [(result: PaletteCommandResult, order: Int)] = []

        for (order, command) in commands.enumerated() {
            if query.isEmpty {
                guard includeAllWhenEmpty else { continue }
                candidates.append((commandResult(command, score: 0), order))
                continue
            }

            guard let score = bestCommandScore(query: query, command: command) else {
                continue
            }
            candidates.append((commandResult(command, score: score), order))
        }

        if !query.isEmpty {
            candidates.sort { lhs, rhs in
                if lhs.result.score != rhs.result.score {
                    return lhs.result.score > rhs.result.score
                }
                return lhs.order < rhs.order
            }
        }

        return candidates.map(\.result)
    }

    /// Curated onboarding actions shown on the empty unified query, in priority
    /// order. Only the enabled ones surface (e.g. "Reopen Closed Workspace"
    /// stays hidden until there's something to reopen).
    @MainActor
    private static func suggestedCommands(in commands: [PaletteCommand]) -> [PaletteCommandResult] {
        let suggestedIDs = [
            KeyboardShortcutCatalog.newWorkspace.id,
            KeyboardShortcutCatalog.newWorkspaceInCurrentDirectory.id,
            KeyboardShortcutCatalog.reopenClosedWorkspace.id,
            KeyboardShortcutCatalog.toggleFloatingPanel.id,
            KeyboardShortcutCatalog.togglePopUpTerminal.id,
            "openSettings"
        ]
        return suggestedIDs.compactMap { id in
            commands.first { $0.id == id }
        }.map { commandResult($0, score: 0) }
    }

    private static func bestSessionScore(
        query: String,
        title: String,
        subtitle: String?,
        searchLocation: String,
        groupName: String
    ) -> Int? {
        // `subtitle` is the last-path-component the row displays; searching
        // only that (as this used to) misses parent-folder queries like
        // "dev" against `~/Development/awesomux` entirely, unlike the
        // sidebar's own inline search, which matches the full abbreviated
        // path. `searchLocation` restores that without changing what's shown.
        [
            title,
            subtitle,
            searchLocation,
            groupName
        ].compactMap { haystack in
            haystack.flatMap { score(query, in: $0) }
        }.max()
    }

    private static func bestCommandScore(query: String, command: PaletteCommand) -> Int? {
        ([command.title] + command.keywords)
            .compactMap { score(query, in: $0) }
            .max()
    }

    private static func commandResult(_ command: PaletteCommand, score: Int) -> PaletteCommandResult {
        PaletteCommandResult(
            commandID: command.id,
            title: command.title,
            subtitle: command.subtitle,
            shortcut: command.shortcut,
            score: score
        )
    }

    private static func sessionSubtitle(for session: TerminalSession) -> String? {
        let directory = session.workingDirectory
        guard !directory.isEmpty else { return nil }
        guard directory != "~" else { return "~" }
        let trimmed = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.split(separator: "/").last else {
            return directory
        }
        return String(last)
    }
}
