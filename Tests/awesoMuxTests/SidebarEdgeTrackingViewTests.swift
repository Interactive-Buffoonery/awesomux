import AppKit
import AwesoMuxConfig
import Testing
@testable import awesoMux

@MainActor
@Suite("SidebarEdgeTrackingView")
struct SidebarEdgeTrackingViewTests {
    @Test("hit testing always passes through")
    func passThroughHitTesting() {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        #expect(view.hitTest(CGPoint(x: 10, y: 10)) == nil)
    }

    @Test("distance mirrors across current local bounds")
    func mirroredDistance() {
        #expect(SidebarEdgeTrackingView.distance(x: 12, width: 40, position: .left) == 12)
        #expect(SidebarEdgeTrackingView.distance(x: 28, width: 40, position: .right) == 12)
        #expect(SidebarEdgeTrackingView.distance(x: 20, width: 80, position: .right) == 60)
        #expect(SidebarEdgeTrackingView.distance(x: -1, width: 40, position: .left) == 0)
        #expect(SidebarEdgeTrackingView.distance(x: .infinity, width: 40, position: .left) == 0)
        #expect(SidebarEdgeTrackingView.distance(x: 20, width: .nan, position: .right) == 0)
    }

    @Test("entry and movement report identical local coordinates immediately")
    func entryAndMovementReportCoordinates() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        var reports: [(CGFloat, CGFloat)] = []
        view.onPointerMove = { reports.append(($0, $1)) }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: CGPoint(x: 12, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )

        view.mouseEntered(with: event)
        view.mouseMoved(with: event)

        #expect(reports.count == 2)
        #expect(reports[0].0 == reports[1].0)
        #expect(reports[0].1 == reports[1].1)
        #expect(reports[0].1 == 40)
    }

    @Test("movement after resize reports current local bounds")
    func resizeUsesCurrentLocalBounds() throws {
        let view = SidebarEdgeTrackingView(position: .right)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        var reports: [(CGFloat, CGFloat)] = []
        view.onPointerMove = { reports.append(($0, $1)) }
        view.frame.size.width = 24
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved,
                location: CGPoint(x: 8, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )

        view.mouseMoved(with: event)

        #expect(reports.count == 1)
        #expect(reports[0].1 == 24)
        #expect(SidebarEdgeTrackingView.distance(x: reports[0].0, width: reports[0].1, position: .right) == 16)
    }

    @Test("detaching and key loss invalidate availability")
    func availabilityLoss() {
        let view = SidebarEdgeTrackingView(position: .left)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        var lossCount = 0
        view.onAvailabilityLost = { lossCount += 1 }

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.contentView = NSView()

        #expect(lossCount == 2)
    }

    @Test("tracking-area refresh and exit do not duplicate callbacks")
    func trackingAreaAndExitAreSingular() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.filter { $0.owner === view }.count == 1)
        var exits = 0
        view.onExit = { exits += 1 }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseExited(with: event)
        #expect(exits == 1)
        #expect(view.accessibilityIsIgnored())
    }
}
