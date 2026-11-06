import AwesoMuxCompanionProtocol
import Foundation
import UnicodeHygiene

public enum CompanionPanePreview {
    public static let maximumBytes = 512

    public static func lastLine(in viewport: String?) -> String? {
        guard let viewport else { return nil }
        for line in viewport.split(whereSeparator: \.isNewline).reversed() {
            let sanitized = UnicodeHygiene.sanitize(String(line), maxLength: maximumBytes)
            guard !sanitized.isEmpty else { continue }
            var result = ""
            var bytes = 0
            for character in sanitized {
                let count = String(character).utf8.count
                guard bytes + count <= maximumBytes else { break }
                result.append(character)
                bytes += count
            }
            guard UnicodeHygiene.containsVisibleScalar(result) else { continue }
            return result
        }
        return nil
    }
}

public extension SessionStore {
    /// A synchronous native-state projection across every workspace,
    /// without mounting panes, reading files, or acknowledging attention.
    func companionWorkspaces(
        terminalPreviewAllowed: Bool = false,
        preview: (UUID) -> String?
    ) -> [CompanionAPIResponse.Workspace] {
        // Binding and native mutations maintain targets after initialization.
        if !localAPITracking {
            localAPITracking = true
            reconcileLocalAPIAssignments()
        }
        let titles = sidebarResolvedTitles()
        return groups.flatMap(\.sessions).map { session in
            let panes = session.layout.leaves.map { leaf -> CompanionAPIResponse.Pane in
                let id: UUID
                switch leaf {
                case .terminal(let pane): id = pane.id
                case .documentGroup(let group): id = group.id
                }
                let availability = PaneAvailability.of(leaf).rawValue
                switch leaf {
                case .terminal(let pane):
                    return .init(
                        paneID: id.uuidString, kind: "terminal", title: pane.title,
                        availability: availability, state: pane.agentSnapshot().state.rawValue,
                        lastOutputLine: terminalPreviewAllowed ? preview(id) : nil,
                        targetVersion: localAPITargets[id]?.version.uuidString.lowercased()
                    )
                case .documentGroup(let group):
                    return .init(
                        paneID: id.uuidString, kind: "documentGroup",
                        title: group.selectedTab?.title ?? String(localized: "Files", comment: "Empty document pane title."),
                        availability: availability
                    )
                }
            }
            return .init(workspaceID: session.id.uuidString, name: titles[session.id] ?? session.title, panes: panes)
        }
    }
}
