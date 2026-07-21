import AwesoMuxCore
import DesignSystem
import SwiftUI

/// Split-button replacement for `NewWorkspaceMenuButton` at the expanded
/// sidebar header only — the collapsed rail keeps the original single-`Menu`
/// control unchanged, since 60pt of rail width has no room for a second,
/// honestly-sized hit target next to a 40pt primary segment.
struct NewWorkspaceSplitButton: View {
    /// Resting background fill. Matches the search field's own fill it sits
    /// beside — a bordered pill (see the `.overlay` stroke in `body`), not
    /// blended into the sidebar.
    let restFill: Color
    /// Groups available for the "New Workspace in…" submenu, in the order
    /// they appear in the sidebar. Unfiltered — includes the current group,
    /// same as `NewWorkspaceMenuButton`'s existing behavior.
    let otherGroups: [(id: SessionGroup.ID, name: String)]
    /// Creates a workspace targeting the caller's chosen default group.
    /// Wired to the primary segment's plain click — no menu involved, no
    /// dropdown opens.
    let onNewWorkspace: () -> Void
    /// Creates a workspace inside a specific group identified by ID. The
    /// caller re-resolves the group at tap time so a rename / delete
    /// between menu render and tap doesn't recreate a phantom group via
    /// `addSession(groupName:)`'s create-if-missing fallback.
    let onNewWorkspaceInGroup: (SessionGroup.ID) -> Void
    let onNewWorkspaceGroup: () -> Void

    /// Matches the search field chip's height so the two chips on the
    /// expanded header's row read as one size.
    private let primarySize: CGFloat = AwSpacing.searchFieldHeight
    private let cornerRadius: CGFloat = 7
    /// The 296pt-wide expanded row has room for a comfortable hit target —
    /// this doesn't also need to fit the 60pt collapsed rail. 24pt is the
    /// WCAG 2.5.8 minimum pointer target size; 22pt fell 2pt short.
    private let chevronWidth: CGFloat = 24
    /// Rapid double-clicks used to be impossible: the old `Menu`-gated
    /// control consumed the first click opening the menu. A plain `Button`
    /// doesn't have that natural debounce, so this guards it explicitly.
    private let doubleClickGuardInterval: Duration = .milliseconds(400)

    @State private var isPrimaryHovering = false
    @State private var isChevronHovering = false
    @State private var lastCreateAt: ContinuousClock.Instant?

    var body: some View {
        HStack(spacing: 0) {
            primaryButton
            Rectangle()
                .fill(Color.aw.border2)
                .frame(width: 0.5, height: primarySize * 0.6)
                // Purely decorative — without this, VoiceOver announces an
                // unlabeled element between "New Workspace" and "New
                // Workspace Options".
                .accessibilityHidden(true)
            chevronButton
        }
        // Filled pill + hairline border, matching the search field's own
        // treatment right beside it (SidebarView.swift's expandedSearchHeader)
        // rather than a flat, borderless box — reads as more "button-y".
        .background(restFill, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
    }

    private var primaryButton: some View {
        // The hover fill is a ZStack sibling of the Button, both pinned to
        // the same outer `.frame`, rather than the fill living inside the
        // Button's own `.background` — this guarantees the highlight spans
        // the full declared segment regardless of how the interactive
        // control inside sizes its own content. Same structure as
        // `chevronButton` below, where a `Menu`'s internal sizing made a
        // `.background` on the Menu itself hug just the glyph instead of
        // filling the segment.
        ZStack {
            // Zero radius on the trailing (divider-facing) side so the
            // highlight sits flush against the divider instead of leaving a
            // rounded gap there — a symmetric RoundedRectangle curved away
            // from the divider on that inner edge.
            UnevenRoundedRectangle(
                topLeadingRadius: cornerRadius - 2,
                bottomLeadingRadius: cornerRadius - 2,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(isPrimaryHovering ? Color.aw.surface.hover : Color.clear)
            Button(action: guardedNewWorkspace) {
                Image(systemName: "plus")
                    // Matches the expanded search icon's exact size/weight
                    // (SidebarView.swift:697) — .semibold at a larger size
                    // rasterizes with more opaque pixels than .medium, so it
                    // read as a brighter color even at the identical RGB
                    // value (diagnosed via Codex, not a color bug).
                    .font(.system(size: 12.5, weight: .medium))
                    // Applied directly on the glyph, not inherited from an
                    // ancestor .foregroundStyle — Menu (below) doesn't
                    // reliably pass that down to its label, so both glyphs
                    // set their own color explicitly to actually match.
                    .foregroundStyle(Color.aw.text3)
                    .frame(width: primarySize, height: primarySize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: primarySize, height: primarySize)
        .onHover { isPrimaryHovering = $0 }
        // `.onHover(false)` isn't guaranteed when the view is torn down
        // mid-hover (see TerminalPaneView / SidebarSessionTile) — reset so a
        // rebuild over the old frame doesn't keep a stale hover fill. Same
        // reasoning applies to the chevron segment below.
        .onDisappear { isPrimaryHovering = false }
        // Without this, the decorative hover-fill shape can surface as its
        // own unlabeled VoiceOver element alongside the Button — same class
        // of bug already found and fixed for the divider between segments,
        // and the established codebase fix (SidebarStatusFooter.swift).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Workspace")
        .accessibilityHint("Creates a new workspace in the current group.")
        .help("New Workspace")
    }

    private var chevronButton: some View {
        ZStack {
            // Zero radius on the leading (divider-facing) side — mirror of
            // primaryButton's shape above, same reasoning.
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: cornerRadius - 2,
                topTrailingRadius: cornerRadius - 2
            )
            .fill(isChevronHovering ? Color.aw.surface.hover : Color.clear)
            Menu {
                Button("New Workspace Group…") {
                    onNewWorkspaceGroup()
                }

                if !otherGroups.isEmpty {
                    Menu("New Workspace in…") {
                        ForEach(otherGroups, id: \.id) { entry in
                            Button(entry.name) {
                                onNewWorkspaceInGroup(entry.id)
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    // Kept compact for the narrower segment, but matches the
                    // search icon's .medium weight — see the primary
                    // segment's comment above for why weight (not color)
                    // was the actual mismatch.
                    .font(.system(size: 9, weight: .medium))
                    .frame(width: chevronWidth, height: primarySize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // .borderlessButton menu labels render their glyph in the
            // control's accent tint and ignore foregroundStyle entirely —
            // .tint is what actually reaches the label's Image. Same fix
            // already established for the "?" help menu (SidebarStatusFooter
            // .swift's feedbackMenu) — this hit the identical bug before.
            .tint(Color.aw.text3)
            .foregroundStyle(Color.aw.text3)
        }
        .frame(width: chevronWidth, height: primarySize)
        .onHover { isChevronHovering = $0 }
        .onDisappear { isChevronHovering = false }
        // Same reasoning as primaryButton above.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Workspace Options")
        .accessibilityHint("Opens a menu to create a new workspace group or a workspace in a specific group.")
        .help("New Workspace Options")
    }

    private func guardedNewWorkspace() {
        let now = ContinuousClock.now
        // ContinuousClock, not Date/wall-clock: a wall-clock step backward
        // (NTP correction, wake-from-sleep RTC resync, manual clock change)
        // would make timeIntervalSince negative — always < the guard
        // interval — silently blocking every future click. Same reasoning
        // as ColdStartSurfaceCreationPolicy.swift and
        // WindowFrameSettlePolicy.swift, which hit this exact class of bug.
        if let lastCreateAt, now - lastCreateAt < doubleClickGuardInterval {
            return
        }
        lastCreateAt = now
        onNewWorkspace()
    }
}
