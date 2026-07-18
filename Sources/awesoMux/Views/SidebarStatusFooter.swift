import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SidebarStatusFooter: View {
    let counts: [AwState: Int]
    let total: Int
    let displayMode: SidebarWidthMode
    let onOpenQuickSettings: () -> Void
    let onSelectNextMatchingState: (AwState) -> Void
    /// Toggle the roster panel (expanded mode). nil = opened via the total label
    /// (no scroll target); a state opens the panel scrolled to that group.
    let onToggleActivityPanel: (AgentDisplayState?) -> Void
    /// Whether the roster panel is open — flips the total label's disclosure
    /// chevron and tooltip so the label reads as clickable.
    let activityPanelOpen: Bool

    @Environment(\.openURL) private var openURL

    /// The footer's job is the global "what's still running anywhere" overview —
    /// the signal you'd otherwise have to expand every collapsed group to find.
    /// Display-only: it reports, it doesn't filter (the click-to-filter chips
    /// were removed; per-group attention rides on the collapsed-only header dot).
    private let visibleStates: [AwState] = [.thinking, .output, .needs]

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

            ForEach(visibleStates, id: \.self) { state in
                if let count = counts[state], count > 0 {
                    Button {
                        onToggleActivityPanel(state.agentDisplayState)
                    } label: {
                        HStack(spacing: 6) {
                            StatusDot(state)
                            Text("\(count)")
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LocalizedPluralStrings.footerAgentsInState(
                        count: count,
                        stateLabel: state.label.lowercased()
                    ))
                    .accessibilityHint(String(localized: "Shows the agent activity panel", comment: "Accessibility hint for a footer chip that opens the agent activity panel"))
                    // The label leads because the dot+count chip carries no
                    // text of its own — the tooltip is the only place a
                    // sighted user gets the state by name.
                    .help("\(state.label) — Show in Activity Panel")
                }
            }

            Spacer(minLength: 4)

            // Rendered even when total == 0: it is the panel's only entry point
            // once every chip is hidden.
            Button {
                onToggleActivityPanel(nil)
            } label: {
                HStack(spacing: 4) {
                    Text(LocalizedPluralStrings.footerAgentsTotal(count: total))
                        .monospacedDigit()
                    // The panel slides in directly above the footer, so the
                    // disclosure points up when closed and down when open.
                    Image(systemName: activityPanelOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.textFaint)
                // Match the chips' hit target — this is the panel's only
                // guaranteed entry point, so bare text height is too small
                // a target (WCAG 2.5.8).
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LocalizedPluralStrings.footerAgentsTotal(count: total))
            // State rides accessibilityValue, not just the hint — hints are
            // user-suppressible in VoiceOver verbosity settings.
            .accessibilityValue(activityPanelOpen
                ? String(localized: "Expanded", comment: "Accessibility value for the footer total button while the agent activity panel is open")
                : String(localized: "Collapsed", comment: "Accessibility value for the footer total button while the agent activity panel is closed"))
            .accessibilityHint(activityPanelOpen
                ? String(localized: "Hides the agent activity panel", comment: "Accessibility hint for the footer total button while the panel is open")
                : String(localized: "Shows the agent activity panel", comment: "Accessibility hint for the footer total button while the panel is closed"))
            .help(activityPanelOpen
                ? String(localized: "Hide Agent Activity", comment: "Tooltip for the footer total button while the agent activity panel is open")
                : String(localized: "Show Agent Activity", comment: "Tooltip for the footer total button while the agent activity panel is closed"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: AwSpacing.footerChrome)
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
