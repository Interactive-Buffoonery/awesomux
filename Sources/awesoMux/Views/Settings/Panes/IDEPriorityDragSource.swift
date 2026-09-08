import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class IDEReorderSession {
    private(set) var draggingBundleID: String?
    private(set) var order: [String]?
    private var initialOrder: [String] = []
    private var initialPriority: [String] = []
    private var dragID: UUID?

    func begin(bundleID: String, order: [String], priority: [String]) -> UUID {
        let id = UUID()
        dragID = id
        draggingBundleID = bundleID
        initialOrder = order
        initialPriority = priority
        self.order = order
        return id
    }

    func move(over target: String) {
        guard let draggingBundleID, var order,
            let from = order.firstIndex(of: draggingBundleID),
            let to = order.firstIndex(of: target), from != to
        else { return }
        order.remove(at: from)
        order.insert(draggingBundleID, at: to)
        self.order = order
    }

    func end(id: UUID, currentPriority: [String], commit: ([String]) -> Void) {
        guard dragID == id else { return }
        let result = order
        let shouldCommit = currentPriority == initialPriority && result != initialOrder
        // Clear before calling out: no pending write survives reentrancy or teardown.
        cancel()
        if shouldCommit, let result { commit(result) }
    }

    func cancel() {
        dragID = nil
        draggingBundleID = nil
        order = nil
        initialOrder = []
        initialPriority = []
    }
}

/// Like PaneDragSource, use AppKit's end callback for Escape and off-window drops.
struct IDEPriorityDragSource: NSViewRepresentable {
    static let contentType = UTType(exportedAs: "com.interactivebuffoonery.awesomux.ide-priority")
    let bundleID: String
    let image: NSImage
    let begin: () -> (() -> Void)

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.bundleID = bundleID
        view.image = image
        view.begin = begin
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var bundleID = ""
        var image = NSImage()
        var begin: (() -> (() -> Void))?
        private var origin: NSPoint?
        private var finish: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            origin = event.locationInWindow
        }

        override func mouseUp(with event: NSEvent) { origin = nil }

        override func mouseDragged(with event: NSEvent) {
            guard let origin, finish == nil else { return }
            let point = event.locationInWindow
            guard pow(point.x - origin.x, 2) + pow(point.y - origin.y, 2) >= 9 else { return }
            self.origin = nil
            let item = NSPasteboardItem()
            item.setString(bundleID, forType: .init(IDEPriorityDragSource.contentType.identifier))
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let location = convert(point, from: nil)
            draggingItem.setDraggingFrame(
                NSRect(x: location.x - 16, y: location.y - 16, width: 32, height: 32), contents: image
            )
            // Capture this gesture's completion independently of representable updates.
            finish = begin?()
            beginDraggingSession(with: [draggingItem], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let completion = finish
            finish = nil
            origin = nil
            // Deliberately keep the last visible order even when AppKit reports cancellation.
            completion?()
        }
    }
}
