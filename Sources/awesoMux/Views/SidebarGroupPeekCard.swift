import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The collapsed-rail group-header hover peek card: lists every workspace
/// in the group, each row clickable to jump straight to it. Shares its
/// chrome (padding, corner radius, border, shadow, left tint stripe) with
/// `SidebarSessionPeekCard` so the two card types read as one visual
/// system — only the background differs, washed with the group's own tint
/// so it's legible at a glance which peek type is showing.
struct SidebarGroupPeekCard: View {
    let group: SessionGroup
    let tint: ProjectTint
    let items: [SessionPeekItem]
    let onSelectSession: (TerminalSession.ID) -> Void
    /// Pointer entered/left the card — same hover-handoff grace purpose as
    /// `SidebarSessionPeekCard.onHoverChanged`.
    let onHoverChanged: (Bool) -> Void

    private var executionPresentation: SessionGroupExecutionPresentation {
        SessionGroupExecutionPresentation(
            summary: SessionGroupExecutionSummary(group: group)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
                .overlay(tint.borderHue.opacity(0.4))
                .allowsHitTesting(false)
            rowList
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.aw.surface.elevated)
                .overlay {
                    // Tint wash: reads as "this card is about a group" at a
                    // glance without fighting the row content's own colors.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.hue.opacity(0.10))
                }
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
        .onHover { onHoverChanged($0) }
        // Transient floating overlay; VoiceOver reaches the same jump
        // targets via the group header's own accessibility actions
        // (Task 5), so the card stays out of the a11y tree — same
        // reasoning as SidebarSessionPeekCard.
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.hue)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)

                if let location = executionPresentation.visibleText {
                    Text(location)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            Text("\(items.count)")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rowList: some View {
        // An empty roster (every session pinned out, or — defensively — no
        // sessions at all) would otherwise render a blank card with no
        // explanation. "All pinned" is the project owner's own wording for
        // this state (2026-07-13): pinning is the only path that empties a
        // non-empty group's roster while the group itself still shows.
        if items.isEmpty {
            Text("All pinned")
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
        } else {
            let rows = VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    Button {
                        onSelectSession(item.id)
                    } label: {
                        SessionPeekRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }

            if items.count > SidebarPeekMetrics.maxVisibleRows {
                ScrollViewReader { proxy in
                    ScrollView {
                        rows
                    }
                    .frame(maxHeight: CGFloat(SidebarPeekMetrics.maxVisibleRows) * SidebarPeekMetrics.rowHeight)
                    .onAppear { scrollToActive(proxy) }
                    .onChange(of: items.first(where: \.isActive)?.id) { _, _ in
                        scrollToActive(proxy)
                    }
                }
            } else {
                rows
            }
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        guard let activeID = items.first(where: \.isActive)?.id else { return }
        proxy.scrollTo(activeID, anchor: .center)
    }
}

private struct SessionPeekRow: View {
    let item: SessionPeekItem

    var body: some View {
        HStack(spacing: 8) {
            AgentTile(agent: item.agent, state: item.state, size: 20)

            Text(item.title)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)

            if let locationText = item.locationText {
                Image(systemName: "network")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)

                Text(locationText)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
