import DesignSystem
import SwiftUI

enum FeatureAtlasCopy {
    struct Card {
        let title: String
        let body: String
        let action: String
        let systemImage: String
    }

    static let agentOptOutNote = String(
        localized: "Not interested in agent features? Switch to the terminal-only guide below.",
        comment: "Feature Atlas note pointing to the terminal-only guidance preference")

    static func card(_ id: FeatureAtlasCardID) -> Card {
        switch id {
        case .commandPalette:
            Card(
                title: String(localized: "Command Palette", comment: "Feature Atlas card title"),
                body: String(
                    localized:
                        "The Command Palette gives you every awesoMux command in one searchable list, because you probably have better things to remember than random terminal commands (we sure do).",
                    comment: "Feature Atlas description of the Command Palette"),
                action: String(localized: "Open Command Palette", comment: "Feature Atlas card action"),
                systemImage: "command"
            )
        case .worktrees:
            Card(
                title: String(localized: "Git worktrees", comment: "Feature Atlas card title"),
                body: String(
                    localized: "Create and open Git worktrees without having to remember the right Git commands off the top of your head.",
                    comment: "Feature Atlas description of Worktree Manager"),
                action: String(localized: "Open Worktree Manager", comment: "Feature Atlas card action"),
                systemImage: "arrow.triangle.branch"
            )
        case .agentStatus:
            Card(
                title: String(localized: "Agent status", comment: "Feature Atlas card title"),
                body: String(
                    localized:
                        "awesoMux can tell when an agent is working, waiting for you, or finished - even when you're in another workspace.",
                    comment: "Feature Atlas description of agent status"),
                action: String(localized: "Set up agent tools", comment: "Feature Atlas card action"),
                systemImage: "person.2"
            )
        case .remoteWorkspaces:
            Card(
                title: String(localized: "Remote workspaces", comment: "Feature Atlas card title"),
                body: String(
                    localized: "Connect over SSH and keep your remote work organized too!",
                    comment: "Feature Atlas description of remote workspaces"),
                action: String(localized: "Set up a remote workspace", comment: "Feature Atlas card action"),
                systemImage: "network"
            )
        case .markdown:
            Card(
                title: String(localized: "Keep docs close", comment: "Feature Atlas card title"),
                body: String(
                    localized: "Keep READMEs, plans, and notes open next to your shell - no extra editor window required.",
                    comment: "Feature Atlas description of Markdown document panes"),
                action: String(localized: "Open a Markdown file", comment: "Feature Atlas card action"),
                systemImage: "doc.text"
            )
        case .updates:
            Card(
                title: String(localized: "More features coming soon!", comment: "Feature Atlas card title"),
                body: String(
                    localized:
                        "D.A.V.E. is still learning new tricks. Check for updates and he'll let you know when there's something new to try.",
                    comment: "Feature Atlas description of future awesoMux updates"),
                action: String(localized: "Check for Updates…", comment: "Feature Atlas card action"),
                systemImage: "sparkles"
            )
        }
    }
}

struct FeatureAtlasView: View {
    let controller: FeatureAtlasController
    let presentationToken: Int

    @AccessibilityFocusState private var headingFocused: Bool
    @AccessibilityFocusState private var preferenceFocused: Bool
    @FocusState private var focusedCard: FeatureAtlasCardID?
    @Environment(\.awAccent) private var accentResolver

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 240), spacing: AwSpacing.overlayGap)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AwSpacing.sectionGap) {
                header

                LazyVGrid(columns: columns, alignment: .leading, spacing: AwSpacing.overlayGap) {
                    ForEach(controller.visibleCardIDs) { id in
                        featureCard(id)
                    }
                }

                guidancePreference
            }
            .padding(AwSpacing.panelPadding)
            .padding(.top, AwSpacing.titlebar - AwSpacing.panelPadding)
        }
        .frame(width: 780, height: 650)
        .background(Color.aw.surface.window)
        .accessibilityElement(children: .contain)
        .onChange(of: presentationToken, initial: true) { _, _ in
            focusHeading()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AwSpacing.sectionGap) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Discover awesoMux")
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)

                Text("D.A.V.E. the goose is ready to help you discover everything awesoMux offers!")
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            DaveMark()
        }
    }

    private func featureCard(_ id: FeatureAtlasCardID) -> some View {
        let copy = FeatureAtlasCopy.card(id)
        let isAvailable = controller.isAvailable(id)
        let unavailableReason = isAvailable ? nil : controller.unavailableReason(id)
        let accessibleBody =
            id == .agentStatus
            ? "\(copy.body) \(FeatureAtlasCopy.agentOptOutNote)"
            : copy.body

        return Button {
            controller.activate(id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: copy.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.aw.peach)
                    .accessibilityHidden(true)

                Text(copy.title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)

                Text(copy.body)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text)
                    .fixedSize(horizontal: false, vertical: true)

                if id == .agentStatus {
                    Text(FeatureAtlasCopy.agentOptOutNote)
                        .awFont(AwFont.UI.meta)
                        .italic()
                        .foregroundStyle(Color.aw.text)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Text(copy.action)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(
                        isAvailable
                            ? Color.aw.accentOnChrome(accentResolver.accent)
                            : Color.aw.text)

                if let unavailableReason {
                    Label(unavailableReason, systemImage: "exclamationmark.circle")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .fill(Color.aw.surface.elevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.panel)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: AwRadius.panel))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedCard, equals: id)
        .focusEffectDisabled()
        .awFocusRing(focusedCard == id, cornerRadius: AwRadius.panel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(copy.title)
        .accessibilityValue(accessibleBody)
        .accessibilityHint(unavailableReason ?? copy.action)
    }

    private var guidancePreference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                controller.showsAgentFeatures
                    ? "Prefer a terminal-only guide?"
                    : "Want to include agent features?"
            )
            .awFont(AwFont.UI.label)
            .foregroundStyle(Color.aw.text)

            Text(
                controller.showsAgentFeatures
                    ? "Hide agent and AI-related guidance. This only changes what D.A.V.E. shows here - it won't disable terminal features or change integrations you've already configured."
                    : "Add agent status and setup back to this guide. This only changes what D.A.V.E. shows here."
            )
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text)
            .fixedSize(horizontal: false, vertical: true)

            Button(
                controller.showsAgentFeatures
                    ? "Show terminal features only"
                    : "Include agent features"
            ) {
                controller.setShowsAgentFeatures(!controller.showsAgentFeatures)
                focusPreference()
            }
            .buttonStyle(.bordered)
            .accessibilityFocused($preferenceFocused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .fill(Color.aw.peach.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .stroke(Color.aw.peach.opacity(0.35), lineWidth: 0.5)
        }
    }

    private func focusHeading() {
        headingFocused = false
        Task { @MainActor in
            await Task.yield()
            headingFocused = true
        }
    }

    private func focusPreference() {
        preferenceFocused = false
        Task { @MainActor in
            await Task.yield()
            preferenceFocused = true
        }
    }
}
