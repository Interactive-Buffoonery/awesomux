import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    @Entry var isSidebarWorkspaceDragActive = false
    @Entry var isNativeSidebarRow = false
    @Entry var sidebarWorkspaceRotorNamespace: Namespace.ID? = nil
}

/// Uses the same native end callback as PaneDragSource, including Escape and off-window drops.
struct SidebarWorkspaceDragSource: NSViewRepresentable {
    @Environment(\.isSidebarWorkspaceDragActive) private var isWorkspaceDragActive
    @Environment(\.isNativeSidebarRow) private var isNativeSidebarRow
    let activate: () -> Void
    let begin: () -> (Data, () -> Void)?

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.activate = activate
        view.begin = begin
        view.isHitTestingDisabled = isWorkspaceDragActive || isNativeSidebarRow
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var activate: (() -> Void)?
        var begin: (() -> (Data, () -> Void)?)?
        var isHitTestingDisabled = false
        private var origin: NSPoint?
        private var finish: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Native tile overlays must not cover the list's destination during preview motion.
            guard !isHitTestingDisabled else { return nil }
            // Leave right-clicks to the existing SwiftUI context menu.
            guard NSApp.currentEvent?.type != .rightMouseDown,
                NSApp.currentEvent?.modifierFlags.contains(.control) != true
            else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) {
            if origin != nil { activate?() }
            origin = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin, finish == nil else { return }
            let point = event.locationInWindow
            guard pow(point.x - origin.x, 2) + pow(point.y - origin.y, 2) >= 9,
                let host = window?.contentView
            else { return }
            let rect = convert(bounds, to: host)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { return }
            host.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            // Snapshot before begin hides the source row for its gap preview.
            guard let item = prepareDrag(image: image) else { return }
            self.origin = nil
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func prepareDrag(image: NSImage) -> NSDraggingItem? {
            guard finish == nil, let (data, completion) = begin?() else { return nil }
            let payload = NSPasteboardItem()
            payload.setData(data, forType: .init(UTType.utf8PlainText.identifier))
            let item = NSDraggingItem(pasteboardWriter: payload)
            item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
            finish = completion
            return item
        }

        func finishDrag() {
            let completion = finish
            finish = nil
            origin = nil
            completion?()
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            finishDrag()
        }
    }
}
