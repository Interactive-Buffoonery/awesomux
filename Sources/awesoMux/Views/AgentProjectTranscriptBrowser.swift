import AwesoMuxCore
import DesignSystem
import SwiftUI

struct AgentProjectTranscriptBrowser: View {
    let projectDirectory: URL
    let roots: [AgentProjectTranscripts.Root]
    let onCancel: () -> Void
    let onOpen: (AgentProjectTranscriptEntry) -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    @State private var listing: AgentProjectTranscriptListing?
    @State private var selection: AgentTranscriptIdentity?
    @State private var generation = 0
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            browserContent
            footer
        }
        .palettePanelStyle(isKeyWindow: controlActiveState != .inactive)
        .frame(
            minWidth: 560, idealWidth: CommandPaletteLayout.defaultSize.width,
            minHeight: 400, idealHeight: CommandPaletteLayout.defaultSize.height
        )
        .presentationBackground(.clear)
        .task(id: generation) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("›")
                .awFont(AwFont.Mono.body)
                .fontWeight(.bold)
                .foregroundStyle(Color.aw.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Browse Project Transcripts", comment: "Heading of the current-project agent transcript browser"))
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: projectDirectory.path)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(projectDirectory.path)
            }
            Spacer(minLength: 10)
            Button(action: onCancel) {
                KBD("esc")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(String(localized: "Cancel", comment: "Close project transcript browser"))
        }
        .paletteHeaderStyle()
    }

    private var browserContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(
                String(
                    localized: "Recent Claude Code and Codex sessions in this directory. Child runs are hidden.",
                    comment: "Scope explanation in the current-project transcript browser")
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text3)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            if let listing {
                if listing.isIncomplete {
                    Text(Self.limitationNotice)
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text2)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if listing.entries.isEmpty {
                    emptyState
                } else {
                    transcriptList(listing.entries)
                }
            } else {
                ProgressView(String(localized: "Looking for project transcripts…", comment: "Project transcript scan progress"))
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(String(localized: "No project transcripts found", comment: "Empty transcript browser title"))
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text2)
            Text(
                String(
                    localized: "Check the agents' Config home in Settings, or try Refresh after a session records a conversation.",
                    comment: "Empty project transcript browser explanation")
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text3)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func transcriptList(_ entries: [AgentProjectTranscriptEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.identity) { index, entry in
                        Button {
                            selection = entry.identity
                            isListFocused = true
                        } label: {
                            transcriptRow(entry)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(entry) })
                        .id(entry.identity)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selection == entry.identity ? .isSelected : [])
                        .accessibilityValue("\(index + 1) of \(entries.count)")
                    }
                }
                .padding(.vertical, 6)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isListFocused)
            .onMoveCommand { direction in
                if direction == .up { moveSelection(-1) }
                if direction == .down { moveSelection(1) }
            }
            .onChange(of: selection) { _, identity in
                if let identity { proxy.scrollTo(identity) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Project transcripts", comment: "Accessible name of the project transcript list"))
        }
    }

    private func transcriptRow(_ entry: AgentProjectTranscriptEntry) -> some View {
        let isSelected = selection == entry.identity
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "▸")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(isSelected ? Color.aw.accent : Color.aw.text3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.identity.agentKind.displayName)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(isSelected ? Color.aw.accent : Color.aw.text)
                Text(verbatim: entry.identity.sessionID)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.modified, style: .date)
                    .awFont(AwFont.Mono.meta)
                Text(entry.modified, style: .time)
                    .awFont(AwFont.Mono.meta)
            }
            .foregroundStyle(Color.aw.text3)
        }
        .paletteRowStyle(isSelected: isSelected)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                KBD("↑↓")
                Text("navigate")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up and Down arrow keys to navigate")
            Button(action: openSelection) {
                HStack(spacing: 14) {
                    KBD("↵")
                    Text("open")
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedEntry == nil)
            .accessibilityLabel(String(localized: "Open", comment: "Open the selected project transcript"))
            Spacer()
            Button(String(localized: "Refresh", comment: "Refresh project transcript metadata")) {
                generation += 1
            }
            .buttonStyle(.plain)
            if let listing {
                Text(LocalizedPluralStrings.commandPaletteResults(count: listing.entries.count))
                    .foregroundStyle(Color.aw.textFaint)
                    .accessibilityHidden(true)
            }
        }
        .paletteFooterStyle()
    }

    private func moveSelection(_ delta: Int) {
        guard let entries = listing?.entries, !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.identity == selection } ?? 0
        selection = entries[min(max(index + delta, 0), entries.count - 1)].identity
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
