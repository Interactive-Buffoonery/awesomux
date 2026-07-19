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
            // Matches the rail's search button glyph exactly (same font size
            // and weight) so the two rail controls read as one family.
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        // Neutral, matching the search icon button above it on the rail —
        // not the accent color, which reads as too prominent for a chrome
        // control at this size.
        .foregroundStyle(Color.aw.text3)
        // Static box, no hover brightening — the search button above it has
        // no hover state either, and this control should read as the same
        // simple chip, not a more "interactive-looking" one.
        .background(restFill, in: RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityLabel("New Workspace menu")
        .accessibilityHint("Opens a menu with New Workspace, New Workspace in a chosen group, and New Workspace Group")
        .help("New Workspace menu")
    }
}
