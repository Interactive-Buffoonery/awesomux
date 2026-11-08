import AwesoMuxCore
import DesignSystem
import SwiftUI

struct NewWorkspaceMenuButton: View, Equatable {
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Resting background fill. Serves the collapsed rail and the expanded
    /// Agents header (the expanded Workspaces header uses
    /// `NewWorkspaceSplitButton`) — the rail passes
    /// `surface.elevated.opacity(0.6)` to match the search icon button
    /// stacked above it.
    let restFill: Color
    /// Groups available for the "New Workspace in…" submenu, in the order
    /// they appear in the sidebar.
    let otherGroups: [(id: SessionGroup.ID, name: String)]
    /// Creates a workspace targeting the caller's chosen default group
    /// (currently-selected workspace's group; see SidebarView.swift).
    let onNewWorkspace: () -> Void
    /// Creates a workspace inside a specific group identified by ID. The
    /// caller re-resolves the group at tap time so a rename / delete
    /// between menu render and tap doesn't recreate a phantom group via
    /// `addSession(groupName:)`'s create-if-missing fallback.
    let onNewWorkspaceInGroup: (SessionGroup.ID) -> Void
    let onNewWorkspaceGroup: () -> Void
    /// Agents mode has no workspace context to infer a group from, so the
    /// menu asks for one instead of offering a default "New Workspace".
    var forAgents = false

    // Same rationale and same bug class as NewWorkspaceSplitButton's gate
    // (see that file): this control sits in `collapsedSearchHeader`, outside
    // SidebarActivitySection's invalidation boundary, so every unrelated
    // SidebarView re-render reconstructed this Menu too — including while
    // its own nested "New Workspace in…" submenu might be open. Callbacks
    // excluded; same capture-stable rationale.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.restFill == rhs.restFill
            && lhs.forAgents == rhs.forAgents
            && lhs.otherGroups.count == rhs.otherGroups.count
            && zip(lhs.otherGroups, rhs.otherGroups).allSatisfy { $0.id == $1.id && $0.name == $1.name }
    }

    var body: some View {
        // The background lives in a ZStack sibling pinned to an outer
        // `.frame`, not as a `.background` on the Menu itself — a Menu's own
        // bounds don't reliably stretch to match its label's declared frame,
        // so this box was rendering smaller than `size` while the
        // plain-Button search button beside it rendered correctly.
        //
        // No border stroke — the search button this must match
        // (SidebarView.swift:664) has none either; adding one here would
        // make the two rail controls diverge again after eD's explicit
        // "match search exactly" direction.
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(restFill)
            Menu {
                if forAgents {
                    agentMenuItems
                } else {
                    workspaceMenuItems
                }
            } label: {
                // Matches the rail's search button glyph exactly (same font
                // size and weight) so the two rail controls read as one
                // family.
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            // SwiftUI draws a native disclosure chevron next to a Menu's
            // label by default — this was never hidden here, so the rail
            // has shown an unintended "+ ⌄" this whole time, not a plain
            // "+". Hiding it now matches the search button beside it, which
            // has no indicator at all.
            .menuIndicator(.hidden)
            // Menu labels render their glyph in the control's accent tint and
            // ignore foregroundStyle — .tint is what actually reaches the
            // label's Image. The "?" help menu uses the same treatment.
            .tint(Color.aw.text3)
            .foregroundStyle(Color.aw.text3)
            .accessibilityLabel(
                forAgents
                    ? String(
                        localized: "New Agent menu", comment: "Accessibility label for the sidebar menu that creates an agent")
                    : Self.workspaceMenuLabel
            )
            .accessibilityHint(
                forAgents
                    ? String(
                        localized: "Choose a group for the new agent",
                        comment: "Accessibility hint for the sidebar menu that creates an agent")
                    : String(
                        localized: "Opens workspace creation options",
                        comment: "Accessibility hint for the sidebar menu that creates a workspace")
            )
            .help(
                forAgents
                    ? String(localized: "New Agent", comment: "Tooltip for the sidebar menu that creates an agent")
                    : Self.workspaceMenuLabel)
        }
        .frame(width: size, height: size)
    }

    private static let workspaceMenuLabel = String(
        localized: "New Workspace menu",
        comment: "Accessibility label and tooltip for the sidebar menu that creates a workspace")

    @ViewBuilder private var workspaceMenuItems: some View {
        Button("New Workspace") {
            onNewWorkspace()
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

        Button("New Workspace Group…") {
            onNewWorkspaceGroup()
        }
    }

    @ViewBuilder private var agentMenuItems: some View {
        if !otherGroups.isEmpty {
            Section(
                String(
                    localized: "New Agent in",
                    comment: "Sidebar menu section header above the list of groups that can hold a new agent")
            ) {
                ForEach(otherGroups, id: \.id) { entry in
                    Button(entry.name) {
                        onNewWorkspaceInGroup(entry.id)
                    }
                }
            }
        }

        Button(
            String(
                localized: "New Agent in New Group…",
                comment: "Sidebar menu item that creates a group and starts a new agent in it")
        ) {
            onNewWorkspaceGroup()
        }
    }
}
