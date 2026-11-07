import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Persistent pane navigation; the hover peek card remains mouse-only.
struct SidebarWorkspacePreview: View {
    let groups: [SessionGroup]
    let selectedSessionID: TerminalSession.ID?
    let onSelectPane: (TerminalSession.ID, UUID) -> Void

    @FocusState private var focusedPaneID: UUID?
    @AccessibilityFocusState private var accessiblePaneID: UUID?

    private func navigate(sessionID: TerminalSession.ID, paneID: UUID) {
        focusedPaneID = nil
        accessiblePaneID = nil
        // Release the SwiftUI responder before terminal focus is requested.
        DispatchQueue.main.async { onSelectPane(sessionID, paneID) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if groups.allSatisfy({ $0.sessions.isEmpty }) {
                        Text(String(localized: "No workspaces to show", comment: "Empty workspace preview"))
                            .foregroundStyle(Color.aw.railText)
                    }
                    ForEach(groups) { group in
                        ForEach(group.sessions) { session in
                            LiveTitleScope(sessionID: session.id, reads: .everything) { titles in
                                let workspaceTitle = titles.workspaceTitle(for: session)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspaceTitle)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.aw.text)
                                        .lineLimit(2)
                                    Text(group.name)
                                        .foregroundStyle(Color.aw.railText)
                                        .lineLimit(1)
                                    ForEach(PanePeekItem.items(for: session, liveTitles: titles)) { item in
                                        Button {
                                            navigate(sessionID: session.id, paneID: item.id)
                                        } label: {
                                            HStack(spacing: 8) {
                                                Text(item.paneNumber.formatted())
                                                    .monospacedDigit()
                                                    .foregroundStyle(Color.aw.railText)
                                                    .frame(minWidth: 12)
                                                    .accessibilityHidden(true)
                                                AgentTile(agent: item.agent, state: item.state, size: 20)
                                                    .accessibilityHidden(true)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.title)
                                                        .foregroundStyle(Color.aw.text)
                                                        .lineLimit(2)
                                                    Text(item.agentShortName + " · " + item.state.label)
                                                        .foregroundStyle(Color.aw.railText)
                                                        .lineLimit(1)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .padding(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(
                                                selectedSessionID == session.id && item.isActive
                                                    ? Color.aw.surface.hover : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .focusable()
                                        .focused($focusedPaneID, equals: item.id)
                                        .onKeyPress(keys: [.space, .return], phases: .down) { press in
                                            guard press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                                            navigate(sessionID: session.id, paneID: item.id)
                                            return .handled
                                        }
                                        .accessibilityFocused($accessiblePaneID, equals: item.id)
                                        .accessibilityLabel(
                                            String(
                                                localized:
                                                    "\(workspaceTitle), \(group.name), \(item.agentShortName), pane \(item.paneNumber), \(item.title), \(item.state.label)",
                                                comment: "VoiceOver label: workspace, group, agent, pane number, title, state"
                                            )
                                        )
                                        .accessibilityValue(item.remoteHost ?? "")
                                        .accessibilityAddTraits(selectedSessionID == session.id && item.isActive ? .isSelected : [])
                                        .accessibilityHint(String(localized: "Jumps to this pane", comment: "Workspace preview navigation"))
                                        .id(item.id)
                                    }
                                }
                                .padding(.bottom, 6)
                            }
                        }
                    }
                }
                .awFont(AwFont.UI.meta)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .onMoveCommand { direction in
                guard let focusedPaneID, direction == .up || direction == .down else { return }
                let ids = groups.flatMap(\.sessions).flatMap { $0.layout.paneIDs }
                guard let index = ids.firstIndex(of: focusedPaneID) else { return }
                let next = ids[max(0, min(ids.count - 1, index + (direction == .down ? 1 : -1)))]
                self.focusedPaneID = next
                proxy.scrollTo(next)
            }
        }
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Workspace preview", comment: "Reciprocal sidebar preview"))
    }
}
