import AwesoMuxCore
import DesignSystem
import SwiftUI

struct AgentProjectTranscriptBrowser: View {
    let projectDirectory: URL
    let roots: [AgentProjectTranscripts.Root]
    let onCancel: () -> Void
    let onOpen: (AgentProjectTranscriptEntry) -> Void

    @State private var listing: AgentProjectTranscriptListing?
    @State private var selection: AgentTranscriptIdentity?
    @State private var generation = 0
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(
                String(
                    localized: "Browse Project Transcripts",
                    comment: "Heading of the current-project agent transcript browser"
                )
            )
            .awFont(AwFont.UI.title)
            .accessibilityAddTraits(.isHeader)

            Text(verbatim: projectDirectory.path)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            Text(
                String(
                    localized: "Recent Claude Code and Codex sessions in this directory. Child runs are hidden.",
                    comment: "Scope explanation in the current-project transcript browser"
                )
            )
            .awFont(AwFont.UI.body)

            if let listing {
                if listing.isIncomplete {
                    Text(Self.limitationNotice)
                        .awFont(AwFont.UI.body)
                        .foregroundStyle(.secondary)
                }
                if listing.entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(
                                String(
                                    localized: "No project transcripts found", comment: "Empty transcript browser title"
                                )
                            )
                            .awFont(AwFont.UI.title)
                        } icon: {
                            Image(systemName: "doc.text.magnifyingglass")
                        }
                    } description: {
                        Text(
                            String(
                                localized:
                                    "Check the agents' Config home in Settings, or try Refresh after a session records a conversation.",
                                comment: "Empty project transcript browser explanation"
                            )
                        )
                        .awFont(AwFont.UI.body)
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(listing.entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(verbatim: entry.identity.agentKind.displayName)
                                        .awFont(AwFont.UI.title)
                                    Spacer()
                                    Text(entry.modified, style: .date)
                                        .awFont(AwFont.UI.meta)
                                    Text(entry.modified, style: .time)
                                        .awFont(AwFont.UI.meta)
                                }
                                Text(verbatim: entry.identity.sessionID)
                                    .awFont(AwFont.Mono.meta)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(entry.identity)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .focused($isListFocused)
                    .accessibilityLabel(
                        String(
                            localized: "Project transcripts", comment: "Accessible name of the project transcript list"
                        )
                    )
                    .onTapGesture(count: 2) { openSelection() }
                }
            } else {
                ProgressView(
                    String(
                        localized: "Looking for project transcripts…", comment: "Project transcript scan progress"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button(String(localized: "Refresh", comment: "Refresh project transcript metadata")) {
                    generation += 1
                }
                Spacer()
                Button(String(localized: "Cancel", comment: "Close project transcript browser"), role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "Open", comment: "Open the selected project transcript")) {
                    openSelection()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
        }
        .awFont(AwFont.UI.body)
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 400, idealHeight: 480)
        .task(id: generation) { await load() }
    }

    private static var limitationNotice: String {
        String(
            localized: "Results are limited. Some session files could not be inspected or exceeded the scan limit.",
            comment: "Notice when project transcript enumeration cannot show a complete list"
        )
    }

    private var selectedEntry: AgentProjectTranscriptEntry? {
        listing?.entries.first { $0.identity == selection }
    }

    private func openSelection() {
        guard let entry = selectedEntry else { return }
        onOpen(entry)
    }

    @MainActor
    private func load() async {
        listing = nil
        selection = nil
        let worker = Task.detached(priority: .userInitiated) { [projectDirectory, roots] in
            AgentProjectTranscripts.list(projectDirectory: projectDirectory, roots: roots)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        listing = result
        selection = result.entries.first?.identity
        isListFocused = !result.entries.isEmpty
        let completion =
            result.entries.isEmpty
            ? String(localized: "No project transcripts found", comment: "Empty transcript browser title")
            : String(localized: "Project transcripts loaded.", comment: "VoiceOver announcement after project transcript discovery")
        TerminalAccessibilityAnnouncer.announce(
            result.isIncomplete ? completion + " " + Self.limitationNotice : completion
        )
    }
}
