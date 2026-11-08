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
    /// Groups available for "New Workspace in…", in the order
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

    // Keep presentation stable during unrelated sidebar activity updates.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size
            && lhs.cornerRadius == rhs.cornerRadius
            && lhs.restFill == rhs.restFill
            && lhs.forAgents == rhs.forAgents
            && lhs.otherGroups.count == rhs.otherGroups.count
            && zip(lhs.otherGroups, rhs.otherGroups).allSatisfy { $0.id == $1.id && $0.name == $1.name }
    }

    var body: some View {
        // The rail shares its resting fill and hit target with the search button.
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(restFill)
            AppDropdown(items: menuItems, menuTitle: forAgents ? String(localized: "New Agent menu") : Self.workspaceMenuLabel) {
                // Matches the rail's search button glyph exactly (same font
                // size and weight) so the two rail controls read as one
                // family.
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: size, height: size)
                    .contentShape(Rectangle())
            }
            .frame(width: size, height: size)
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

    private var menuItems: [AppDropdownItem] {
        var items: [AppDropdownItem] = []
        if !forAgents {
            items.append(AppDropdownItem(title: String(localized: "New Workspace"), action: onNewWorkspace))
        }
        if !otherGroups.isEmpty {
            items.append(.heading(forAgents ? String(localized: "New Agent in") : String(localized: "New Workspace in…")))
            items += otherGroups.map { entry in
                AppDropdownItem(title: entry.name, id: entry.id) { onNewWorkspaceInGroup(entry.id) }
            }
        }
        items.append(
            AppDropdownItem(
                title: forAgents ? String(localized: "New Agent in New Group…") : String(localized: "New Workspace Group…"),
                action: onNewWorkspaceGroup))
        return items
    }
}
