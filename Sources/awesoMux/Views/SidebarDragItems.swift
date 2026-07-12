import AwesoMuxCore
import Foundation
import UniformTypeIdentifiers

// MARK: - Drag payload (INT-330)
//
// macOS-specific gotcha: custom `UTType(exportedAs:)` identifiers — even
// with `conformingTo: .data` — don't reliably reach `.onDrop` hover events
// on macOS 15. Drag sources register data fine; drop targets never see it.
// `UTType.utf8PlainText` is the universally-registered fallback that
// always reaches drop targets. We discriminate workspace vs. group drags
// at the application layer via a `kind` field, not at the UTType layer.

/// On-the-wire kind discriminator. Embedded in every dragged payload so
/// drop targets can validate they're receiving the right kind of drag.
enum SidebarDragKind: String, Codable {
    case workspace
    case group
}

/// Drag payload for a single workspace (`TerminalSession`). `kind` is the
/// wire discriminator — drop targets reject mismatched kinds even though
/// both payloads ride the same UTType.
struct WorkspaceDragItem: Codable {
    let kind: SidebarDragKind
    let sessionID: TerminalSession.ID
    let dragID: UUID

    init(sessionID: TerminalSession.ID, dragID: UUID) {
        self.kind = .workspace
        self.sessionID = sessionID
        self.dragID = dragID
    }
}

struct WorkspaceGroupDragItem: Codable {
    let kind: SidebarDragKind
    let groupID: SessionGroup.ID
    let dragID: UUID

    init(groupID: SessionGroup.ID, dragID: UUID) {
        self.kind = .group
        self.groupID = groupID
        self.dragID = dragID
    }
}

// MARK: - NSItemProvider register/decode helpers

/// Register a Codable drag payload onto the provider under
/// `UTType.utf8PlainText`. Used by `.onDrag` callsites.
func registerSidebarDragPayload<T: Encodable>(
    _ value: T,
    on provider: NSItemProvider
) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.utf8PlainText.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
}

/// Decode a `WorkspaceDragItem` from an NSItemProvider. Validates the
/// payload's `kind` discriminator so a group drag can't be misinterpreted
/// as a workspace drag (both ride the same UTType wire format).
func decodeWorkspaceDragItem(
    from provider: NSItemProvider,
    completion: @MainActor @escaping (WorkspaceDragItem) -> Void
) {
    provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
        guard let data,
              let item = try? JSONDecoder().decode(WorkspaceDragItem.self, from: data),
              item.kind == .workspace else { return }
        Task { @MainActor in completion(item) }
    }
}

func decodeWorkspaceGroupDragItem(
    from provider: NSItemProvider,
    completion: @MainActor @escaping (WorkspaceGroupDragItem) -> Void
) {
    provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
        guard let data,
              let item = try? JSONDecoder().decode(WorkspaceGroupDragItem.self, from: data),
              item.kind == .group else { return }
        Task { @MainActor in completion(item) }
    }
}

