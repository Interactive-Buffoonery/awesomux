import AppKit
import Testing
@testable import awesoMux

@Suite("Sidebar workspace native drag source")
@MainActor
struct SidebarWorkspaceDragSourceTests {

    @Test func cancelFinishesExactlyOnceUsingTheOriginalCallback() throws {
        let view = SidebarWorkspaceDragSource.DragSourceView()
        var ended = 0
        view.begin = { (Data("workspace".utf8), { ended += 1 }) }
        let item = try #require(view.prepareDrag(image: NSImage(size: NSSize(width: 200, height: 30))))
        #expect((item.item as? NSPasteboardItem)?.data(forType: .init("public.utf8-plain-text")) == Data("workspace".utf8))
        view.begin = { (Data(), { ended += 100 }) }
        view.finishDrag()
        view.finishDrag()
        #expect(ended == 1)
    }

    @Test func clickDoesNotStartOrFinishADrag() throws {
        let view = SidebarWorkspaceDragSource.DragSourceView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        var clicks = 0
        var starts = 0
        view.activate = { clicks += 1 }
        view.begin = {
            starts += 1; return (Data(), {})
        }
        let down = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        let up = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp, location: CGPoint(x: 10, y: 10), modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
            ))
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        #expect(clicks == 1)
        #expect(starts == 0)
    }
}
