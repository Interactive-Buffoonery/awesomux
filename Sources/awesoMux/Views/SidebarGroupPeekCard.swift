import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The collapsed-rail group-header hover peek card: lists every workspace
/// in the group, each row clickable to jump straight to it. Shares its
/// chrome (padding, corner radius, border, shadow, left tint stripe) with
/// `SidebarSessionPeekCard` so the two card types read as one visual
/// system — only the background differs, washed with the group's own tint
/// so it's legible at a glance which peek type is showing.
///
/// Every label on this card draws in `Color.aw.text`, including the ones that
/// read as secondary. The tint wash spends most of the card's contrast budget,
/// and on Latte no dimmer token survives it: at the worst tint (red) `text2`
/// measures 2.84:1 and `railText` 3.59:1, both under the WCAG 1.4.3 AA floor
/// of 4.5:1, and `railText`'s own doc notes it was tuned for mantle rather
/// than this surface. Mocha is not exempt either — at the 10% wash this card
/// used before #287, `text2` fell to 4.32:1 on the yellow tint there. Reach for
/// `text` when adding a label here; hierarchy has to come from size and
/// position instead of colour.
struct SidebarGroupPeekCard: View {
    /// Alpha of the group-tint wash over `surface.elevated`.
    ///
    /// Latte's `surface.elevated` is `surface0` (#ccd0da), which leaves the
    /// card barely enough contrast budget for `Color.aw.text` — the darkest
    /// token in the palette — before the wash is applied at all. At 0.10 the
    /// red tint pushed it to 4.45:1, under the WCAG 1.4.3 AA floor; 0.08 puts
    /// the worst tint at 4.58:1 with every other tint above it. The wash is
    /// still what makes a group peek distinguishable from a session peek at a
    /// glance, so this is the largest value that keeps the card's own text
    /// legible rather than the smallest that reads as tinted.
    ///
    /// `SidebarGroupPeekCardContrastTests` measures this constant directly —
    /// raising it needs a palette with more headroom, not just a nicer look.
    static let tintWashOpacity = 0.08

    let group: SessionGroup
    let tint: ProjectTint
    let items: [SessionPeekItem]
    let onSelectSession: (TerminalSession.ID) -> Void
    let onNewWorkspace: () -> Void

    /// Same guard, and the same reason, as `NewWorkspaceSplitButton`: a plain
    /// `Button` has no natural debounce, and this card stays hittable through
    /// its removal transition after the first click hides it — so a double
    /// click otherwise creates two workspaces and selects only the second.
    private let doubleClickGuardInterval: Duration = .milliseconds(400)
    @State private var lastCreateAt: ContinuousClock.Instant?
    /// Pointer entered/left the card — same hover-handoff grace purpose as
    /// `SidebarSessionPeekCard.onHoverChanged`.
    let onHoverChanged: (Bool) -> Void

    private func guardedNewWorkspace() {
        // ContinuousClock, not wall-clock: a backward step (NTP correction,
        // wake-from-sleep RTC resync) would make the difference negative —
        // always under the interval — and silently block every later click.
        let now = ContinuousClock.now
        if let lastCreateAt, now - lastCreateAt < doubleClickGuardInterval {
            return
        }
        lastCreateAt = now
        onNewWorkspace()
    }

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
                        .fill(tint.hue.opacity(Self.tintWashOpacity))
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
                        .foregroundStyle(Color.aw.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            Text("\(items.count)")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rowList: some View {
        // An empty roster would otherwise render a blank card with no
        // explanation, but it has two causes that need different copy. "All
        // pinned" is the project owner's own wording (2026-07-13) for a group
        // whose sessions have all been pinned OUT of the roster — it stays
        // accurate only while the group actually has sessions. `items` is the
        // pin-filtered projection; `group.sessions` is the full roster, so the
        // two states are distinguishable.
        if items.isEmpty {
            if group.sessions.isEmpty {
                // A genuinely empty group's card is otherwise a dead end, so
                // this one state earns an action. Deliberately NOT offered
                // when the card lists rows: every row there is a jump target,
                // and a create button among them invites the wrong click.
                // VoiceOver reaches the same action through the group header's
                // existing "New Workspace in Group" (the card itself is
                // `accessibilityHidden`), so this adds no unreachable control.
                //
                // Shaped after `NewWorkspaceInGroupRow`, the same action in the
                // expanded sidebar — same label, same pointer-target floor.
                //
                // NOT its `textFaint` foreground, though: that row sits on plain
                // sidebar surface, and on Latte `textFaint` measures 1.49:1 over
                // this card's washed surface. See the type's own doc comment for
                // why every label here draws in `text`. The group tint itself is
                // a fill colour — teal reads 2.23:1 — so it stays out entirely.
                VStack(alignment: .leading, spacing: 8) {
                    Text("No workspaces")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text)

                    Button(action: guardedNewWorkspace) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 14)

                            Text("new workspace")
                                .awFont(AwFont.Mono.pill)

                            Spacer(minLength: 4)
                        }
                        .foregroundStyle(Color.aw.text)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: NewWorkspaceInGroupRow.minimumPointerTargetHeight,
                            alignment: .leading
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Workspace in Group")
                }
            } else {
                Text("All pinned")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text)
            }
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
                    .foregroundStyle(Color.aw.text)

                Text(locationText)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text)
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
