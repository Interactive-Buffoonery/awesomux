import AwesoMuxCore
import DesignSystem
import SwiftUI

struct SidebarSessionPeekCard: View {
    let session: TerminalSession
    let location: SidebarSessionLocation
    let tint: ProjectTint
    /// Pre-walked rows for the multi-pane list. Empty on the single-pane path.
    let paneItems: [PanePeekItem]
    /// Click-to-jump for a pane row. No-op closure on the single-pane path
    /// (that card stays non-interactive).
    let onSelectPane: (TerminalPane.ID) -> Void
    /// Pointer entered/left the card — drives the hover-handoff grace so the
    /// card doesn't vanish under a cursor reaching for a row (538 R5). Wired
    /// only on the multi-pane path.
    let onHoverChanged: (Bool) -> Void

    private var isMultiPane: Bool { session.layout.paneCount > 1 }

    var body: some View {
        // One rollup walk for the whole card — `chromeAwState` and the unread
        // total each re-walk the panes otherwise.
        let rollup = session.agentRollup()
        let awState = rollup.state.awState
        return VStack(alignment: .leading, spacing: 8) {
            header(rollup: rollup, awState: awState)
            locationRow

            if isMultiPane {
                Divider()
                    .overlay(tint.borderHue.opacity(0.4))
                    .allowsHitTesting(false)
                paneList
            } else {
                summaryPills(paneCount: session.layout.paneCount, unread: rollup.unreadTotal)
            }
        }
        .padding(12)
        .background {
            // Visual chrome only — never a click target, so the card's padding
            // and header never eat a terminal/divider click behind it (538 R4).
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.aw.surface.elevated)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.hue)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.borderHue.opacity(0.85), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(0.20), radius: 16, y: 8)
                .allowsHitTesting(false)
        }
        .ifMultiPane(isMultiPane) { card in
            card.onHover { onHoverChanged($0) }
        }
        // The card is a transient floating overlay; the keyboard/VoiceOver jump
        // path lives on the focusable sidebar tile (per-pane accessibility
        // actions), so the card itself stays out of the a11y tree to avoid a
        // mouse-only element competing for VoiceOver focus.
        .accessibilityHidden(true)
    }

    private func header(rollup: SessionAgentRollup, awState: AwState) -> some View {
        HStack(spacing: 8) {
            AgentTile(
                agent: rollup.winningAgentKind.awAgentIcon,
                state: awState,
                size: 28
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(2)

                Text(awState.label)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
            }
        }
        .allowsHitTesting(false)
    }

    private var locationRow: some View {
        HStack(spacing: 6) {
            if location.kind == .remote {
                Image(systemName: "network")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .accessibilityHidden(true)
            }

            Text(location.displayText)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(1)
        }
        .allowsHitTesting(false)
    }

    private func summaryPills(paneCount: Int, unread: Int) -> some View {
        Group {
            if paneCount > 1 || unread > 0 {
                HStack(spacing: 8) {
                    if paneCount > 1 {
                        AwPill("\(paneCount) panes")
                    }
                    if unread > 0 {
                        AwPill("\(unread) unread", state: .needs)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var paneList: some View {
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach(paneItems) { item in
                Button {
                    onSelectPane(item.id)
                } label: {
                    PanePeekRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }

        if paneItems.count > SidebarPeekMetrics.maxVisibleRows {
            // Scroll the active pane into view on open, so the highlighted row
            // isn't stranded below the fold for a many-pane workspace whose
            // active pane sorts past the visible cap (INT-538 review).
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                }
                .frame(maxHeight: CGFloat(SidebarPeekMetrics.maxVisibleRows) * SidebarPeekMetrics.rowHeight)
                .onAppear { scrollToActive(proxy) }
                // Re-scroll if the active pane changes while the card stays open
                // (a refresh swaps in new paneItems), so the highlight never sits
                // off-screen in an overflow list.
                .onChange(of: paneItems.first(where: \.isActive)?.id) { _, _ in
                    scrollToActive(proxy)
                }
            }
        } else {
            rows
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        guard let activeID = paneItems.first(where: \.isActive)?.id else { return }
        proxy.scrollTo(activeID, anchor: .center)
    }
}

private struct PanePeekRow: View {
    let item: PanePeekItem

    var body: some View {
        HStack(spacing: 8) {
            Text("\(item.paneNumber)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.aw.text2)
                .frame(width: 12)

            AgentTile(agent: item.agent, state: item.state, size: 20)

            Text(item.title)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)

            if let remoteHost = item.remoteHost {
                Label(remoteHost, systemImage: "network")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
            }

            Spacer(minLength: 6)

            if item.unread > 0 {
                AwPill(
                    "\(item.unread)",
                    state: .needs,
                    baseSurface: pillBaseSurface
                )
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            item.isActive
                ? Color.aw.surface.hover
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        // Whole row is the hit target, so a click between the icon and the
        // pill still jumps.
        .contentShape(Rectangle())
    }

    private var pillBaseSurface: Color {
        guard item.isActive else { return Color.aw.surface.elevated }
        return Color.aw.composited(
            Color.aw.surface.hover,
            over: Color.aw.surface.elevated
        )
    }
}

private extension View {
    /// Applies `transform` only when `condition` holds, so the single-pane card
    /// never installs the multi-pane hover tracker.
    @ViewBuilder
    func ifMultiPane(
        _ condition: Bool,
        transform: (Self) -> some View
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
