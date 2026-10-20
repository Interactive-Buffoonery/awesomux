import AwesoMuxCompanionProtocol
import AwesoMuxLocalAPI
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
    /// A synchronous native-state projection: filter before accessing a surface,
    /// without mounting panes, reading files, or acknowledging attention.
    func companionWorkspaces(
        scope: LocalAPITargetScope,
        terminalPreviewAllowed: Bool = false,
        preview: (UUID) -> String?
    ) -> [CompanionAPIResponse.Workspace] {
        localAPITracking = true
        reconcileLocalAPIAssignments()
        let titles = sidebarResolvedTitles()
        return groups.flatMap(\.sessions).compactMap { session in
            let panes = session.layout.leaves.compactMap { leaf -> CompanionAPIResponse.Pane? in
                let id: UUID
                switch leaf {
                case .terminal(let pane): id = pane.id
                case .documentGroup(let group): id = group.id
                }
                switch scope {
                case .allWorkspaces: break
                case .persistentWorkspaces(let ids):
                    guard ids.contains(session.id) else { return nil }
                case .persistentPanes(let ids):
                    guard ids.contains(id) else { return nil }
                case .exactTarget(let paneID, let version):
                    guard paneID == id, localAPITargets[id]?.version == version else { return nil }
                }
                let availability = PaneAvailability.of(leaf).rawValue
                switch leaf {
                case .terminal(let pane):
                    return .init(
                        paneID: id.uuidString, kind: "terminal", title: pane.title,
                        availability: availability, state: pane.agentSnapshot().state.rawValue,
                        lastOutputLine: terminalPreviewAllowed ? preview(id) : nil
                    )
                case .documentGroup(let group):
                    return .init(
                        paneID: id.uuidString, kind: "documentGroup",
                        title: group.selectedTab?.title ?? String(localized: "Files", comment: "Empty document pane title."),
                        availability: availability
                    )
                }
            }
            if panes.isEmpty {
                switch scope {
                case .allWorkspaces: break
                case .persistentWorkspaces(let ids):
                    guard ids.contains(session.id) else { return nil }
                case .persistentPanes, .exactTarget: return nil
                }
            }
            return .init(workspaceID: session.id.uuidString, name: titles[session.id] ?? session.title, panes: panes)
        }
    }
}
