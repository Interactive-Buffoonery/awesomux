import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Display-resolved roster row: Core row + the display strings the panel
/// renders. Resolved by SidebarView (which owns the session lookup) so this
/// view stays a dumb list. `title` is the row's pane title in a split, else
/// the session title — matching whichever title bar the user actually sees.
struct AgentActivityPanelItem: Identifiable {
    let row: AgentActivityRoster.Row
    let title: String
    let locationText: String

    var id: UUID { row.paneID }
}

/// INT-722 roster panel: agent panes grouped by state, most urgent first.
/// Transient triage index — owns no state, jump handled by the caller.
struct AgentActivityPanel: View {
    let groups: [(state: AgentDisplayState, items: [AgentActivityPanelItem])]
    /// State group to scroll into view when opened from a footer chip.
    let scrollTarget: AgentDisplayState?
    let onSelect: (AgentActivityRoster.Row) -> Void
    /// Spec §5: the panel has its own close affordance (chips/total also
    /// toggle, but a keyboard/AT user inside the panel needs an exit).
    let onClose: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(localized: "Agents", comment: "Header for the sidebar agent activity panel"))
                            .awFont(AwFont.Mono.kicker)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.aw.textFaint)
                        Spacer()
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .regular))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.aw.text3)
                        .accessibilityLabel(String(localized: "Close agent activity panel", comment: "Accessibility label for the agent activity panel's close button"))
                        .help(String(localized: "Close", comment: "Tooltip for the agent activity panel's close button"))
                    }
                    if groups.isEmpty {
                        Text(String(localized: "No agents running", comment: "Empty state for the sidebar agent activity panel"))
                            .awFont(AwFont.Mono.meta)
                            .foregroundStyle(Color.aw.textFaint)
                            .padding(.top, 6)
                    }
                    ForEach(groups, id: \.state) { group in
                        groupHeader(group.state, count: group.items.count)
                        ForEach(group.items) { item in
                            rowButton(item)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // Slide rows on acks/state changes instead of teleporting when the
                // list reflows. Keyed on the flattened row IDs so an insert/remove/
                // reorder animates; a pure state relabel (same IDs) doesn't churn.
                // ponytail: full position-freeze deferred until live triage shows misclicks.
                .animation(.default, value: groups.flatMap { $0.items.map(\.id) })
            }
            .onAppear {
                if let scrollTarget {
                    proxy.scrollTo(scrollTarget, anchor: .top)
                }
            }
            // Re-scroll when an already-open panel is retargeted by another
            // chip click — onAppear alone would ignore it (review finding).
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
        // ponytail: fixed cap, not %-of-sidebar — needs/error sorts first so
        // actionable rows are never below the fold; revisit if fleets make
        // the internal scroll annoying.
        .frame(maxHeight: 280)
        .accessibilityLabel(String(localized: "Agent activity", comment: "Accessibility label for the sidebar agent activity panel"))
    }

    private func groupHeader(_ state: AgentDisplayState, count: Int) -> some View {
        HStack(spacing: 6) {
            StatusDot(state.awState)
            Text("\(state.label) · \(count)")
                .awFont(AwFont.Mono.kicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.text3)
        }
        .padding(.top, 6)
        .id(state)
        // Combine so the StatusDot isn't a bare "xmark"/"checkmark" VO stop.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rowButton(_ item: AgentActivityPanelItem) -> some View {
        // why: interpolating a String literal into Text("…") / .accessibilityLabel("…")
        // binds the LocalizedStringKey overload, which Markdown-parses the
        // terminal-controlled session title. Bind a plain String first and use
        // Text(verbatim:) / the StringProtocol label overload so titles are never
        // treated as markup.
        let titleLine = "\(item.row.agentKind.shortName) — \(item.title)"
        let a11yLabel = "\(item.row.agentKind.spokenName), \(item.row.state.label), \(item.title), \(item.locationText)"
        return Button {
            onSelect(item.row)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: titleLine)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
                Text(item.locationText)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint(String(localized: "Jumps to this agent's pane", comment: "Accessibility hint for an agent activity panel row"))
    }
}
