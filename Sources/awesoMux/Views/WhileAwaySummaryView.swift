import AwesoMuxCore
import AwesoMuxLocalAPI
import DesignSystem
import SwiftUI

struct WhileAwaySummaryView: View {
    let store: SessionStore
    let summary: LocalAPIWhileAwaySummary
    @State private var showingDetails = false

    var body: some View {
        HStack {
            Button {
                showingDetails = true
            } label: {
                Label(
                    String(
                        localized: "While you were away",
                        comment: "Title of the companion away activity summary banner and details, also announced when the banner appears."),
                    systemImage: "clock.arrow.circlepath"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                String(
                    localized: "Show activity by workspace and pane",
                    comment: "Accessibility hint for opening companion away activity summary details."))
            Button {
                store.dismissWhileAwaySummary()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                String(
                    localized: "Dismiss while you were away summary",
                    comment: "Accessibility label for dismissing the companion away activity summary banner."))
        }
        .padding(AwSpacing.panelPadding)
        .background(.regularMaterial)
        .onChange(of: summary.events.map(\.id), initial: true) { _, _ in
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "While you were away",
                    comment: "Title of the companion away activity summary banner and details, also announced when the banner appears."))
        }
        .sheet(isPresented: $showingDetails) {
            WhileAwayDetailsView(store: store, summary: summary)
        }
    }
}

private struct WhileAwayDetailsView: View {
    private struct PaneActivity: Identifiable {
        let id: UUID
        let workspaceID: UUID
        let events: [LocalAPIAttentionEvent]
    }

    let store: SessionStore
    let summary: LocalAPIWhileAwaySummary
    private let panes: [PaneActivity]
    private let workspaceIDs: [UUID]
    @Environment(\.dismiss) private var dismiss

    init(store: SessionStore, summary: LocalAPIWhileAwaySummary) {
        self.store = store
        self.summary = summary
        var workspaceIDs: [UUID] = []
        var panes: [PaneActivity] = []
        for event in summary.events where !workspaceIDs.contains(event.workspaceID) {
            workspaceIDs.append(event.workspaceID)
        }
        for workspaceID in workspaceIDs {
            var paneIDs = Set<UUID>()
            for event in summary.events where event.workspaceID == workspaceID && paneIDs.insert(event.paneID).inserted {
                let changes = summary.events.filter { $0.workspaceID == workspaceID && $0.paneID == event.paneID }
                var attentionIDs: [UUID] = []
                var latest: [UUID: LocalAPIAttentionEvent] = [:]
                for change in changes {
                    if latest[change.attentionID] == nil { attentionIDs.append(change.attentionID) }
                    latest[change.attentionID] = change
                }
                let events = attentionIDs.compactMap { latest[$0] }
                panes.append(PaneActivity(id: event.paneID, workspaceID: workspaceID, events: events))
            }
        }
        self.workspaceIDs = workspaceIDs
        self.panes = panes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                String(
                    localized: "While you were away",
                    comment: "Title of the companion away activity summary banner and details, also announced when the banner appears.")
            )
            .font(.title2)
            .accessibilityAddTraits(.isHeader)
            if summary.olderActivityUnavailable {
                Label(
                    String(
                        localized: "Older activity unavailable",
                        comment: "Warning in the companion away summary that older activity exceeded the retained history."),
                    systemImage: "exclamationmark.triangle")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(workspaceIDs, id: \.self) { workspaceID in
                        LiveTitleScope(sessionID: workspaceID, reads: .workspaceTitle) { titles in
                            Text(
                                store.session(id: workspaceID).map { titles.workspaceTitle(for: $0) }
                                    ?? String(
                                        localized: "Deleted workspace",
                                        comment:
                                            "Workspace heading fallback in the companion away summary when the original workspace no longer exists."
                                    )
                            )
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(panes.filter { $0.workspaceID == workspaceID }) { pane in
                            VStack(alignment: .leading, spacing: 8) {
                                paneHeading(pane.id)
                                ForEach(pane.events, id: \.attentionID) { event in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(Self.description(event))
                                        Spacer()
                                        if event.change == .resolved {
                                            Text(
                                                String(
                                                    localized: "Resolved",
                                                    comment:
                                                        "Status of an attention request that was resolved during the companion away interval."
                                                ))
                                        }
                                        Text(event.occurredAt, style: .time)
                                            .foregroundStyle(.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                }
                            }
                            .padding(.leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(String(localized: "Done", comment: "Button that closes the companion away activity summary details.")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onExitCommand { dismiss() }
        .padding(AwSpacing.panelPadding)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 300, idealHeight: 480)
    }

    @ViewBuilder
    private func paneHeading(_ paneID: UUID) -> some View {
        if let session = store.groups.lazy.flatMap(\.sessions).first(where: { $0.layout.pane(id: paneID) != nil }),
            let pane = session.layout.pane(id: paneID)
        {
            LiveTitleScope(sessionID: session.id, reads: .paneTitle(paneID)) { titles in
                Text(titles.paneTitle(for: pane))
                    .font(.subheadline.bold())
                    .accessibilityAddTraits(.isHeader)
            }
        } else {
            Text(
                String(
                    localized: "Deleted pane",
                    comment: "Pane heading fallback in the companion away summary when the pane no longer exists.")
            )
            .font(.subheadline.bold())
            .accessibilityAddTraits(.isHeader)
        }
    }

    private static func description(_ event: LocalAPIAttentionEvent) -> String {
        switch event.reason {
        case "bell": String(localized: "Terminal bell", comment: "Terminal bell event in the companion away activity summary.")
        case "desktopNotification":
            String(localized: "Desktop notification", comment: "Desktop notification event in the companion away activity summary.")
        case "permissionPrompt":
            String(localized: "Permission requested", comment: "Permission request event in the companion away activity summary.")
        case "userInputRequired", "waitingForInput":
            String(localized: "Input requested", comment: "Event requesting user input in the companion away activity summary.")
        case "processError", "agentError":
            String(localized: "Agent error", comment: "Agent error event in the companion away activity summary.")
        case "commandFailed":
            String(
                localized: "Command failed (exit \(event.exitCode ?? 0))",
                comment: "Failed command in the companion away activity summary; the number is the process exit code.")
        case "commandFinished":
            String(localized: "Command finished", comment: "Completed command event in the companion away activity summary.")
        default: String(localized: "Attention requested", comment: "Fallback event description in the companion away activity summary.")
        }
    }
}
