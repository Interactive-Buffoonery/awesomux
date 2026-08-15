import AppKit
import AwesoMuxCore
import Observation

struct PaletteWorkspaceActionTarget: Equatable {
    let sessionID: TerminalSession.ID
    let activePaneID: TerminalPane.ID
    let isSinglePane: Bool
    let selectedDocumentTabID: DocumentPane.ID?
    let displayedTitle: String
}

struct PaletteCommandInvocation: Equatable {
    let commandID: PaletteCommand.ID
    let selectionScope: PaletteCommandSelectionScope
    let workspaceTarget: PaletteWorkspaceActionTarget?

    func canResolveAgainstCurrentSelection(
        sessionID: TerminalSession.ID?,
        paneID: TerminalPane.ID?,
        documentTabID: DocumentPane.ID?,
        isSinglePane: Bool? = nil
    ) -> Bool {
        switch selectionScope {
        case .none:
            return true
        case .workspace:
            return workspaceTarget?.sessionID == sessionID
        case .pane:
            return workspaceTarget?.sessionID == sessionID
                && workspaceTarget?.activePaneID == paneID
                && (commandID != KeyboardShortcutCatalog.closePane.id
                    || workspaceTarget?.isSinglePane == isSinglePane)
        case .documentTab:
            return workspaceTarget?.sessionID == sessionID
                && workspaceTarget?.selectedDocumentTabID == documentTabID
        }
    }
}

struct PaletteQuickRunInvocation: Equatable {
    let result: PaletteQuickRunResult
    let workspaceTarget: PaletteWorkspaceActionTarget?

    func canResolveAgainstCurrentSelection(
        sessionID: TerminalSession.ID?,
        paneID: TerminalPane.ID?
    ) -> Bool {
        workspaceTarget?.sessionID == sessionID
            && workspaceTarget?.activePaneID == paneID
    }
}

@MainActor
@Observable
final class PalettePresenter {
    private let sessionGroups: [SessionGroup]
    private let sessionTitles: [TerminalSession.ID: String]
    private let commands: [PaletteCommand]
    private let workspaceTarget: PaletteWorkspaceActionTarget?
    private let selectSession: @MainActor (TerminalSession.ID) -> Bool
    private let runCommand: @MainActor (PaletteCommandInvocation) -> Bool
    private let runQuickRun: @MainActor (PaletteQuickRunInvocation, PaletteQuickRunCommitSurface) -> Bool

    private(set) var currentResults: PaletteResults
    private(set) var flattenedResults: [PaletteResult]

    var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            refreshResults(resetSelection: true)
        }
    }

    private(set) var selectedIndex: Int?

    init(
        sessionGroups: [SessionGroup],
        sessionTitles: [TerminalSession.ID: String] = [:],
        commands: [PaletteCommand],
        workspaceTarget: PaletteWorkspaceActionTarget? = nil,
        selectSession: @escaping @MainActor (TerminalSession.ID) -> Bool,
        runCommand: @escaping @MainActor (PaletteCommandInvocation) -> Bool,
        runQuickRun: @escaping @MainActor (PaletteQuickRunInvocation, PaletteQuickRunCommitSurface) -> Bool = { _, _ in false }
    ) {
        self.sessionGroups = sessionGroups
        self.sessionTitles = sessionTitles
        self.commands = commands
        self.workspaceTarget = workspaceTarget
        self.selectSession = selectSession
        self.runCommand = runCommand
        self.runQuickRun = runQuickRun
        let initialResults = PaletteSearch.results(
            groups: sessionGroups,
            commands: commands,
            rawQuery: "",
            titles: sessionTitles
        )
        currentResults = initialResults
        flattenedResults = initialResults.flattened
        selectedIndex = currentResults.defaultSelectionIndex
    }

    private func refreshResults(resetSelection: Bool) {
        let results = PaletteSearch.results(
            groups: sessionGroups,
            commands: commands,
            rawQuery: query,
            titles: sessionTitles
        )
        currentResults = results
        flattenedResults = results.flattened
        if resetSelection {
            selectedIndex = results.defaultSelectionIndex
        }
    }

    var selectedResult: PaletteResult? {
        guard let selectedIndex,
              flattenedResults.indices.contains(selectedIndex) else {
            return nil
        }
        return flattenedResults[selectedIndex]
    }

    func moveSelection(delta: Int) {
        let results = flattenedResults
        guard !results.isEmpty else {
            selectedIndex = nil
            return
        }

        let startingIndex: Int
        if let selectedIndex {
            startingIndex = selectedIndex
        } else {
            startingIndex = delta < 0 ? results.count : -1
        }

        selectedIndex = min(max(startingIndex + delta, 0), results.count - 1)
    }

    func select(index: Int) {
        guard flattenedResults.indices.contains(index) else {
            return
        }
        selectedIndex = index
    }

    @discardableResult
    func submitSelection(surface: PaletteQuickRunCommitSurface = .toast) -> Bool {
        guard let result = selectedResult else {
            return false
        }
        return perform(result, surface: surface)
    }

    @discardableResult
    func perform(_ result: PaletteResult, surface: PaletteQuickRunCommitSurface = .toast) -> Bool {
        switch result {
        case .session(let session):
            return selectSession(session.sessionID)
        case .command(let command):
            guard let source = PaletteCommandRegistry.command(id: command.commandID, in: commands),
                source.isEnabled
            else {
                return false
            }
            return runCommand(
                PaletteCommandInvocation(
                    commandID: command.commandID,
                    selectionScope: source.selectionScope,
                    workspaceTarget: workspaceTarget
                ))
        case .quickRun(let quickRun):
            return runQuickRun(
                PaletteQuickRunInvocation(result: quickRun, workspaceTarget: workspaceTarget),
                surface
            )
        }
    }

    func canPerform(_ result: PaletteResult) -> Bool {
        switch result {
        case .session:
            return true
        case .command(let command):
            return PaletteCommandRegistry.command(id: command.commandID, in: commands)?.isEnabled == true
        case .quickRun:
            return true
        }
    }

    func accessibilityAnnouncement(for result: PaletteResult) -> String {
        switch result {
        case .session(let session):
            var parts = [
                "Workspace: \(session.title)",
                "Group: \(session.groupName)"
            ]
            if let subtitle = session.subtitle {
                parts.append("Directory: \(subtitle)")
            }
            return parts.joined(separator: ", ")
        case .command(let command):
            var parts = ["Action: \(command.title)"]
            if let subtitle = command.subtitle {
                parts.append(subtitle)
            }
            if let shortcut = command.shortcut {
                parts.append(shortcut.spokenForm)
            }
            return parts.joined(separator: ", ")
        case .quickRun(let quickRun):
            return "Quick run: \(quickRun.command)"
        }
    }
}
