import AwesoMuxCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Pane drag payload (INT-223)
//
// Mirrors the sidebar drag idiom (`SidebarDragItems.swift`): a Codable payload
// JSON-encoded onto an NSItemProvider under `UTType.utf8PlainText`. The same
// macOS-15 gotcha applies — a custom `UTType(exportedAs:)` identifier never
// reaches `.onDrop` hover events, so we ride the universally-registered
// plain-text type and discriminate by a `kind` field at the app layer.

/// Drag payload for a single terminal pane. `kind` is the wire discriminator so
/// a pane drag can't be mistaken for a sidebar workspace/group drag even though
/// all three ride the same UTType wire format.
struct PaneDragItem: Codable {
    /// Reuses the sidebar discriminator namespace by adding a `pane` case there;
    /// a dedicated wire kind keeps every plain-text drag self-describing.
    let kind: PaneDragKind
    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
    let dragID: UUID

    init(sessionID: TerminalSession.ID, paneID: TerminalPane.ID, dragID: UUID) {
        self.kind = .pane
        self.sessionID = sessionID
        self.paneID = paneID
        self.dragID = dragID
    }
}

/// Wire discriminator for pane drags. Kept separate from `SidebarDragKind` so a
/// future sidebar payload change can't silently re-route a pane drag.
enum PaneDragKind: String, Codable {
    case pane
}

// MARK: - NSItemProvider register/decode helpers

/// Decode a `PaneDragItem` from an NSItemProvider, validating the `kind`
/// discriminator so a sidebar drag can't be misinterpreted as a pane drag.
///
/// The completion receives `nil` on any decode failure (no data, bad JSON, or a
/// non-pane `kind`) so the caller can surface a swallowed-but-accepted drop —
/// `performDrop` returned `true`, so a silent decode failure would otherwise be
/// an invisible no-op.
func decodePaneDragItem(
    from provider: NSItemProvider,
    completion: @MainActor @escaping (PaneDragItem?) -> Void
) {
    provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
        let item: PaneDragItem? = {
            guard let data,
                  let decoded = try? JSONDecoder().decode(PaneDragItem.self, from: data),
                  decoded.kind == .pane else { return nil }
            return decoded
        }()
        Task { @MainActor in completion(item) }
    }
}
