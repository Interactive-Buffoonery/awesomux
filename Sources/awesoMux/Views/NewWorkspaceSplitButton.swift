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
    /// this doesn't also need to fit the 60pt collapsed rail.
    private let chevronWidth: CGFloat = 22
    /// Rapid double-clicks used to be impossible: the old `Menu`-gated
    /// control consumed the first click opening the menu. A plain `Button`
    /// doesn't have that natural debounce, so this guards it explicitly.
    private let doubleClickGuardInterval: TimeInterval = 0.4

    @State private var isPrimaryHovering = false
    @State private var isChevronHovering = false
    @State private var lastCreateAt: Date?

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
        // Neutral, matching the search icon beside it (SidebarView.swift) —
        // not the accent color, which reads as too prominent for a chrome
        // control at this size.
        .foregroundStyle(Color.aw.text3)
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
            RoundedRectangle(cornerRadius: cornerRadius - 2)
                .fill(isPrimaryHovering ? Color.aw.surface.hover : Color.clear)
            Button(action: guardedNewWorkspace) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
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
        .accessibilityLabel("New Workspace")
        .accessibilityHint("Creates a new workspace in the current group.")
        .help("New Workspace")
    }

    private var chevronButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius - 2)
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
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: chevronWidth, height: primarySize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .frame(width: chevronWidth, height: primarySize)
        .onHover { isChevronHovering = $0 }
        .onDisappear { isChevronHovering = false }
        .accessibilityLabel("New Workspace Options")
        .accessibilityHint("Opens a menu to create a new workspace group or a workspace in a specific group.")
        .help("New Workspace Options")
    }

    private func guardedNewWorkspace() {
        let now = Date()
        if let lastCreateAt, now.timeIntervalSince(lastCreateAt) < doubleClickGuardInterval {
            return
        }
        lastCreateAt = now
        onNewWorkspace()
    }
}
