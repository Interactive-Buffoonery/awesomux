import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SidebarStatusFooter: View {
    let counts: [AwState: Int]
    let total: Int
    let displayMode: SidebarWidthMode
    let onOpenQuickSettings: () -> Void
    let onShowWelcomeTour: () -> Void
    let onSelectNextMatchingState: (AwState) -> Void
    /// nil switches sidebars; a state chip opens the full roster at that state.
    let onToggleActivityPanel: (AgentDisplayState?) -> Void
    /// Whether Agents is the primary sidebar.
    let activityPanelOpen: Bool
    let previewOpen: Bool
    let previewAvailable: Bool
    let onTogglePreview: () -> Void
    let focusRequestID: UUID
    let focusSwitch: Bool
    let accent: AwAccent
    let increasedContrast: Bool

    private enum Control: Hashable { case preview, sidebar }
    @FocusState private var focusedControl: Control?
    @AccessibilityFocusState private var accessibleControl: Control?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @Environment(\.openURL) private var openURL

    /// The footer's job is the global "what's still running anywhere" overview —
    /// the signal you'd otherwise have to expand every collapsed group to find.
    /// Display-only: it reports, it doesn't filter (the click-to-filter chips
    /// were removed; per-group attention rides on the collapsed-only header dot).
    private let visibleStates: [AwState] = [.thinking, .output, .needs]

    static func modeSwitchLabel(total: Int, activityPanelOpen: Bool) -> String {
        activityPanelOpen
            ? String(localized: "Workspaces", comment: "Workspace preview and sidebar destination")
            : LocalizedPluralStrings.footerAgentsTotal(count: total)
    }

    /// Public feedback is filed through the repository's issue templates so
    /// users have a stable intake path without depending on a maintainer's
    /// personal mailbox. Internal (not private) so the Help menu command
    /// (INT-324) opens the same URL instead of duplicating the literal.
    static let feedbackURL = URL(string: "https://github.com/Interactive-Buffoonery/awesomux/issues/new/choose")!

    var body: some View {
        if displayMode == .collapsed {
            collapsedFooter
        } else {
            expandedFooter
        }
    }

    private var expandedFooter: some View {
        HStack(spacing: 4) {
            settingsButton
            feedbackMenu

            ViewThatFits(in: .horizontal) {
                stateButtonCluster(compact: false)
                    .fixedSize(horizontal: true, vertical: false)
                stateButtonCluster(compact: true)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(-1)

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Text(Self.modeSwitchLabel(total: total, activityPanelOpen: activityPanelOpen))
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.railText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if previewAvailable {
                    Button(action: onTogglePreview) {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(previewOpen ? Color.aw.accentOnChrome(accent) : Color.aw.railText)
                    .background(
                        previewOpen ? Color.aw.accentOnChrome(accent).opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
                    .focusable()
                    .focused($focusedControl, equals: .preview)
                    .focusEffectDisabled()
                    .overlay { focusRing(.preview) }
                    .onKeyPress(keys: [.space, .return], phases: .down) { press in
                        guard press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                        onTogglePreview()
                        return .handled
                    }
                    .accessibilityFocused($accessibleControl, equals: .preview)
                    .accessibilityLabel(previewLabel)
                    .accessibilityValue(
                        previewOpen
                            ? String(localized: "Expanded", comment: "Preview disclosure state")
                            : String(localized: "Collapsed", comment: "Preview disclosure state")
                    )
                    .help(previewLabel)
                }
                Button {
                    onToggleActivityPanel(nil)
                } label: {
                    Image(systemName: "rectangle.2.swap")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.aw.railText)
                .focusable()
                .focused($focusedControl, equals: .sidebar)
                .focusEffectDisabled()
                .overlay { focusRing(.sidebar) }
                .onKeyPress(keys: [.space, .return], phases: .down) { press in
                    guard press.modifiers.subtracting(.capsLock).isEmpty else { return .ignored }
                    onToggleActivityPanel(nil)
                    return .handled
                }
                .accessibilityFocused($accessibleControl, equals: .sidebar)
                .accessibilityLabel(switchLabel)
                .help(switchLabel)
            }
            .layoutPriority(1)

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: AwSpacing.footerChrome)
        .onChange(of: focusRequestID) { _, _ in
            focusedControl = focusSwitch ? .sidebar : .preview
            if voiceOverEnabled { accessibleControl = focusedControl }
        }
    }

    private var switchLabel: String {
        activityPanelOpen
            ? String(localized: "Show Workspaces Sidebar", comment: "Switch sidebar destination")
            : String(localized: "Show Agents Sidebar", comment: "Switch sidebar destination")
    }

    @ViewBuilder
    private func focusRing(_ control: Control) -> some View {
        if focusedControl == control {
            RoundedRectangle(cornerRadius: 4)
                .inset(by: 1)
                .stroke(
                    Color.aw.accentOnChrome(accent),
                    lineWidth: AwFocusRing.lineWidth(increasedContrast: increasedContrast)
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var previewLabel: String {
        if activityPanelOpen {
            return previewOpen
                ? String(localized: "Hide workspace preview", comment: "Footer preview control")
                : String(localized: "Show workspace preview", comment: "Footer preview control")
        }
        return previewOpen
            ? String(localized: "Hide agent preview", comment: "Footer preview control")
            : String(localized: "Show agent preview", comment: "Footer preview control")
    }

    private var collapsedFooter: some View {
        VStack(spacing: 8) {
            settingsButton
            feedbackMenu

            ForEach(visibleStates, id: \.self) { state in
                if let count = counts[state], count > 0 {
                    Button {
                        // Collapsed rail has no room for the roster, so chips jump
                        // directly to the next matching agent pane instead of
                        // expanding the panel.
                        onSelectNextMatchingState(state)
                    } label: {
                        VStack(spacing: 3) {
                            StatusDot(state)
                            Text("\(count)")
                                .awFont(AwFont.Mono.meta)
                                .monospacedDigit()
                        }
                        .frame(width: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LocalizedPluralStrings.footerAgentsInState(
                        count: count,
                        stateLabel: state.label.lowercased()
                    ))
                    .accessibilityHint(String(localized: "Jumps to the next matching agent", comment: "Accessibility hint for a collapsed-rail footer chip that jumps to the next agent pane in that state"))
                    .help("\(state.label) — Jump to Next Agent")
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func stateButtonCluster(compact: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(visibleStates, id: \.self) { state in
                if let count = counts[state], count > 0 {
                    stateButton(state: state, count: count, compact: compact)
                }
            }
        }
    }

    private func stateButton(state: AwState, count: Int, compact: Bool) -> some View {
        Button {
            onToggleActivityPanel(state.agentDisplayState)
        } label: {
            if compact {
                StatusDot(state, animatesThinking: !activityPanelOpen)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 6) {
                    StatusDot(state, animatesThinking: !activityPanelOpen)
                    Text("\(count)")
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .awFont(AwFont.Mono.meta)
        .foregroundStyle(Color.aw.text3)
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            LocalizedPluralStrings.footerAgentsInState(
                count: count,
                stateLabel: state.label.lowercased()
            )
        )
        .accessibilityHint(
            String(
                localized: "Shows the Agents sidebar",
                comment: "Accessibility hint for a footer chip that opens the agent activity panel")
        )
        // The label leads because the dot+count chip carries no text of its
        // own — the tooltip is the only place a sighted user gets the state
        // by name.
        .help("\(state.label) — Show in Agents Sidebar")
    }

    private var settingsButton: some View {
        Button {
            onOpenQuickSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.aw.text3)
        .accessibilityLabel("Quick Settings")
        .help("Quick Settings")
    }

    private var feedbackMenu: some View {
        Menu {
            Button("Show Welcome Tour") {
                onShowWelcomeTour()
            }
            Divider()
            Button("Report a bug…") {
                openFeedbackForm()
            }
            Button("Suggest a feature…") {
                openFeedbackForm()
            }
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .regular))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // .borderlessButton menu labels render their glyph in the control's accent
        // tint and ignore the outer foregroundStyle — .tint is what actually reaches
        // the label's Image, matching the gear's Color.aw.text3.
        .tint(Color.aw.text3)
        .foregroundStyle(Color.aw.text3)
        .accessibilityLabel("Help and feedback")
        .accessibilityHint("Opens menu")
        .help("Help & Feedback")
    }

    private func openFeedbackForm() {
        openURL(Self.feedbackURL)
    }


}

struct EmptySidebarFilterView: View {
    let searchText: String
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(.needs)
                    .accessibilityHidden(true)

                Text("no matches")
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.aw.status.needs)
            }

            Text(filterDescription)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text3)
                .fixedSize(horizontal: false, vertical: true)

            Button("Clear search") {
                onClear()
            }
            .buttonStyle(.plain)
            .awFont(AwFont.Mono.pill)
            .foregroundStyle(Color.aw.status.onLoud)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.aw.status.needs, in: RoundedRectangle(cornerRadius: AwRadius.pill))
        }
        .padding(14)
        .background(Color.aw.status.needs.opacity(0.10), in: RoundedRectangle(cornerRadius: AwRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.panel)
                .stroke(Color.aw.status.needs.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [4, 4]))
        }
    }

    // SidebarSearchModePolicy limits this view to a non-empty expanded-mode
    // search. An unfiltered empty store is valid and uses the main welcome view.
    private var filterDescription: String {
        "Nothing matched \"\(searchText)\"."
    }
}
