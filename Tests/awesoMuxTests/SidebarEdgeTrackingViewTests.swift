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

    @Test("entry and monitored movement report identical local coordinates immediately")
    func entryAndMonitoredMovementReportCoordinates() throws {
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
        view.synchronizePointer(locationInWindow: event.locationInWindow)

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

        view.synchronizePointer(locationInWindow: event.locationInWindow)

        #expect(reports.count == 1)
        #expect(reports[0].1 == 24)
        #expect(SidebarEdgeTrackingView.distance(x: reports[0].0, width: reports[0].1, position: .right) == 16)
    }

    @Test("tracking stays active while its window is not key")
    func trackingStaysActiveOutsideKeyWindow() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        var lossCount = 0
        view.onAvailabilityLost = { lossCount += 1 }

        view.updateTrackingAreas()
        let area = try #require(view.trackingAreas.first { $0.owner === view })
        #expect(area.options.contains(.activeAlways))
        #expect(!area.options.contains(.activeInKeyWindow))

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(lossCount == 0)

        window.contentView = NSView()
        #expect(lossCount == 1)
    }

    @Test("exit inside current bounds republishes without clearing")
    func staleExitInsideCurrentBoundsRepublishes() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 12, y: 10) }
        var reports: [(CGFloat, CGFloat)] = []
        view.onPointerMove = { reports.append(($0, $1)) }
        var exits = 0
        view.onExit = { exits += 1 }
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 12, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.mouseExited(with: event)

        let report = try #require(reports.first)
        #expect(report.0 == 12)
        #expect(report.1 == 40)
        #expect(exits == 0)
    }

    @Test("exit event inside but current pointer outside clears")
    func staleInsideEventWithCurrentPointerOutsideClears() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 60, y: 10) }
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 12, y: 10))
        reports = 0
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 12, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.mouseExited(with: event)

        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("exit event outside but current pointer inside republishes current position")
    func staleOutsideEventWithCurrentPointerInsideRepublishes() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 12, y: 10) }
        var reports: [(CGFloat, CGFloat)] = []
        view.onPointerMove = { reports.append(($0, $1)) }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 12, y: 10))
        reports.removeAll()
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 60, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.mouseExited(with: event)

        let report = try #require(reports.first)
        #expect(report.0 == 12)
        #expect(report.1 == 40)
        #expect(exits == 0)
    }

    @Test("tracking refresh followed by a true exit clears once")
    func refreshedTrackingTrueExitIsSingular() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 60, y: 10) }
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.filter { $0.owner === view }.count == 1)
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 12, y: 10))
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 60, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseExited(with: event)
        #expect(exits == 1)
        #expect(view.accessibilityIsIgnored())
    }

    @Test("monitor exit followed by tracking fallback clears once")
    func monitorThenTrackingExitIsSingular() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 60, y: 10) }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 12, y: 10))
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 60, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.synchronizePointer(locationInWindow: CGPoint(x: 60, y: 10))
        view.mouseExited(with: event)
        view.mouseExited(with: event)

        #expect(exits == 1)
    }

    @Test("exit outside a clipped visible region clears")
    func clippedExitClears() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let clipView = NSClipView(frame: CGRect(x: 0, y: 0, width: 20, height: 300))
        clipView.documentView = view
        let window = NSWindow(contentRect: clipView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = clipView
        view.currentMouseLocationInWindow = { _ in CGPoint(x: 30, y: 10) }
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 12, y: 10))
        reports = 0
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 30, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.mouseExited(with: event)

        #expect(view.bounds.contains(CGPoint(x: 30, y: 10)))
        #expect(!view.visibleRect.contains(CGPoint(x: 30, y: 10)))
        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("geometry republish outside a clipped visible region clears")
    func clippedGeometryRepublishClears() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 300)
        let clipView = NSClipView(frame: view.frame)
        clipView.documentView = view
        let window = NSWindow(contentRect: clipView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = clipView
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 30, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.synchronizePointer(locationInWindow: event.locationInWindow)
        reports = 0
        clipView.frame.size.width = 20

        view.republishPointerAfterGeometryChange()

        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("unclipped superview does not extend synchronized region past bounds")
    func unclippedSuperviewDoesNotExtendSynchronizedRegion() {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        container.addSubview(view)
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 120, y: 100))
        reports = 0
        let outside = CGPoint(x: 900, y: 100)

        view.synchronizePointer(locationInWindow: outside)

        let local = view.convert(outside, from: nil)
        #expect(!view.bounds.contains(local))
        #expect(view.visibleRect.contains(local))
        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("unclipped superview does not extend current exit sample past bounds")
    func unclippedSuperviewDoesNotExtendExitSample() throws {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        container.addSubview(view)
        let outside = CGPoint(x: 900, y: 100)
        view.currentMouseLocationInWindow = { _ in outside }
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: CGPoint(x: 120, y: 100))
        reports = 0
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: outside, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))

        view.mouseExited(with: event)

        let local = view.convert(outside, from: nil)
        #expect(!view.bounds.contains(local))
        #expect(view.visibleRect.contains(local))
        #expect(reports == 0)
        #expect(exits == 1)
    }

    @Test("unclipped superview does not extend geometry republish past bounds")
    func unclippedSuperviewDoesNotExtendGeometryRepublish() {
        let view = SidebarEdgeTrackingView(position: .left)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1_200, height: 800))
        let window = NSWindow(contentRect: container.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        container.addSubview(view)
        let outsideAfterResize = CGPoint(x: 300, y: 100)
        var reports = 0
        view.onPointerMove = { _, _ in reports += 1 }
        var exits = 0
        view.onExit = { exits += 1 }
        view.synchronizePointer(locationInWindow: outsideAfterResize)
        reports = 0
        view.frame.size.width = 200

        view.republishPointerAfterGeometryChange()

        let local = view.convert(outsideAfterResize, from: nil)
        #expect(!view.bounds.contains(local))
        #expect(view.visibleRect.contains(local))
        #expect(reports == 0)
        #expect(exits == 1)
    }
}
