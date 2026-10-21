import AwesoMuxCore
import AwesoMuxLocalAPI
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
                Label(String(localized: "While you were away"), systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "Show activity by workspace and pane"))
            Button {
                store.dismissWhileAwaySummary()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Dismiss while you were away summary"))
        }
        .padding()
        .background(.regularMaterial)
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
            Text(String(localized: "While you were away"))
                .font(.title2)
            if summary.olderActivityUnavailable {
                Label(String(localized: "Older activity unavailable"), systemImage: "exclamationmark.triangle")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(workspaceIDs, id: \.self) { workspaceID in
                        Text(store.session(id: workspaceID)?.title ?? String(localized: "Deleted workspace"))
                            .font(.headline)
                        ForEach(panes.filter { $0.workspaceID == workspaceID }) { pane in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(store.session(id: workspaceID)?.layout.pane(id: pane.id)?.title ?? String(localized: "Deleted pane"))
                                    .font(.subheadline.bold())
                                ForEach(pane.events, id: \.attentionID) { event in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(Self.description(event))
                                        Spacer()
                                        if event.change == .resolved {
                                            Text(String(localized: "Resolved"))
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
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 300, idealHeight: 480)
    }

    private static func description(_ event: LocalAPIAttentionEvent) -> String {
        switch event.reason {
        case "bell": String(localized: "Terminal bell")
        case "desktopNotification": String(localized: "Desktop notification")
        case "permissionPrompt": String(localized: "Permission requested")
        case "userInputRequired", "waitingForInput": String(localized: "Input requested")
        case "processError", "agentError": String(localized: "Agent error")
        case "commandFailed": String(localized: "Command failed (exit \(event.exitCode ?? 0))")
        case "commandFinished": String(localized: "Command finished")
        default: String(localized: "Attention requested")
        }
    }
}
