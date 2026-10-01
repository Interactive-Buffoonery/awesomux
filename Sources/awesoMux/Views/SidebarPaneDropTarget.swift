import AppKit
import AwesoMuxCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarPaneDropTarget: ViewModifier {
    let sessionID: TerminalSession.ID
    let displayMode: SidebarWidthMode
    @Environment(GhosttyRuntime.self) private var runtime: GhosttyRuntime?
    @Environment(SessionStore.self) private var sessionStore: SessionStore?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let runtime, let sessionStore {
            let coordinator = runtime.paneDragCoordinator
            let delegate = SidebarPaneDropDelegate(
                sessionID: sessionID, sessionStore: sessionStore, coordinator: coordinator,
                setTargeted: { isTargeted = $0 }
            )
            content
                // Keep tile identity stable as a pane drag begins and ends.
                .onDrop(of: coordinator.isDragging ? [UTType.utf8PlainText] : [], delegate: delegate)
                .overlay {
                    if isTargeted, delegate.canAcceptDrop {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                            .overlay {
                                if displayMode == .collapsed {
                                    Image(systemName: "plus")
                                        .padding(3)
                                        .background(.regularMaterial, in: Circle())
                                } else {
                                    Text(PaneTitleBarStrings.moveToNewWorkspace)
                                        .font(.caption)
                                        .padding(4)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onChange(of: coordinator.dragID) { _, _ in isTargeted = false }
        } else {
            content
        }
    }
}

struct SidebarPaneDropDelegate: DropDelegate {
    let sessionID: TerminalSession.ID
    let sessionStore: SessionStore
    let coordinator: PaneDragCoordinator
    let setTargeted: (Bool) -> Void

    var canAcceptDrop: Bool {
        guard coordinator.draggedSessionID == sessionID,
            coordinator.dragID != nil,
            let paneID = coordinator.draggedPaneID
        else { return false }
        return sessionStore.canMovePaneToNewWorkspace(id: paneID, in: sessionID)
    }

    func validateDrop(info: DropInfo) -> Bool {
        coordinator.isDragging && info.hasItemsConforming(to: [UTType.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        setTargeted(validateDrop(info: info) && canAcceptDrop)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            setTargeted(false)
            return nil
        }
        let allowed = canAcceptDrop
        setTargeted(allowed)
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { setTargeted(false) }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
            let provider = info.itemProviders(for: [UTType.utf8PlainText]).first
        else { return false }
        return performDrop(from: provider)
    }

    func performDrop(
        from provider: NSItemProvider,
        decode: (NSItemProvider, @escaping @MainActor (PaneDragItem?) -> Void) -> Void = decodePaneDragItem
    ) -> Bool {
        defer {
            setTargeted(false)
            coordinator.end()
        }
        guard canAcceptDrop,
            let paneID = coordinator.draggedPaneID,
            let dragID = coordinator.dragID
        else {
            reject()
            return false
        }
        let generation = coordinator.generation
        decode(provider) { item in
            // Ending retains generation; beginning another gesture invalidates this ticket.
            guard let item,
                item.sessionID == sessionID,
                item.paneID == paneID,
                item.dragID == dragID,
                coordinator.generation == generation,
                sessionStore.canMovePaneToNewWorkspace(id: paneID, in: sessionID),
                sessionStore.movePaneToNewWorkspace(id: paneID, in: sessionID) != nil
            else {
                reject()
                return
            }
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Moved pane to a new workspace",
                    comment: "VoiceOver announcement after moving the active pane out into a workspace of its own."
                )
            )
        }
        return true
    }

    private func reject() {
        NSSound.beep()
        TerminalAccessibilityAnnouncer.announce(
            String(
                localized: "Pane move not allowed",
                comment: "VoiceOver announcement when a pane drag drops on a zone that can't accept the move."
            )
        )
    }
}
