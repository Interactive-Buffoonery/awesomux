import AwesoMuxCore
import DesignSystem
import SwiftUI

struct NewWorkspaceMenuButton: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Resting background fill. This component now serves the collapsed rail
    /// only (the expanded header uses `NewWorkspaceSplitButton`) — the rail
    /// passes `surface.elevated.opacity(0.6)` to match the search icon
    /// button stacked above it.
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

    var body: some View {
        // The background/border live in a ZStack sibling pinned to an outer
        // `.frame`, not as a `.background`/`.overlay` on the Menu itself —
        // a Menu's own bounds don't reliably stretch to match its label's
        // declared frame, so this box was rendering smaller than `size`
        // while the plain-Button search button beside it rendered correctly.
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(restFill)
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.aw.border2, lineWidth: 0.5)
            Menu {
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
            } label: {
                // Matches the rail's search button glyph exactly (same font
                // size and weight) so the two rail controls read as one
                // family.
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            // SwiftUI draws a native disclosure chevron next to a Menu's
            // label by default — this was never hidden here, so the rail
            // has shown an unintended "+ ⌄" this whole time, not a plain
            // "+". Hiding it now matches the search button beside it, which
            // has no indicator at all.
            .menuIndicator(.hidden)
            // .borderlessButton menu labels render their glyph in the
            // control's accent tint and ignore foregroundStyle entirely —
            // .tint is what actually reaches the label's Image. Same fix
            // already established for the "?" help menu (SidebarStatusFooter
            // .swift's feedbackMenu) — this hit the identical bug before.
            .tint(Color.aw.text3)
            .foregroundStyle(Color.aw.text3)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("New Workspace menu")
        .accessibilityHint("Opens a menu with New Workspace, New Workspace in a chosen group, and New Workspace Group")
        .help("New Workspace menu")
    }
}
