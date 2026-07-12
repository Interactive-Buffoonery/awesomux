import AwesoMuxCore
import DesignSystem
import SwiftUI

struct NewWorkspaceMenuButton: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Resting background fill. The expanded header passes `surface.sidebar`
    /// (mantle) so the glyph blends into the sidebar next to the search field;
    /// the collapsed rail passes `surface.hover` to keep its boxed look,
    /// matching the disabled command-palette button stacked above it.
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

    @State private var isHovering = false
    @Environment(\.awAccent) private var accentResolver

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
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(Color.aw.accent(accentResolver.accent))
        // `restFill` decides whether the button blends into the sidebar
        // (expanded header) or keeps a box (collapsed rail). On hover it always
        // surfaces the `surface.hover` highlight so it reads as a button — for
        // the rail that fill equals its rest state, so hover is a no-op there.
        .background(
            isHovering ? Color.aw.surface.hover : restFill,
            in: RoundedRectangle(cornerRadius: cornerRadius)
        )
        .onHover { isHovering = $0 }
        // `.onHover(false)` isn't guaranteed when the view is torn down mid-hover
        // (see TerminalPaneView / SidebarSessionTile) — reset so a rebuild over
        // the old frame doesn't keep a stale hover fill.
        .onDisappear { isHovering = false }
        .accessibilityLabel("New Workspace menu")
        .accessibilityHint("Opens a menu with New Workspace, New Workspace in a chosen group, and New Workspace Group")
        .help("New Workspace menu")
    }
}
