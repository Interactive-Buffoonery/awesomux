import AppKit
import Testing
@testable import awesoMux

@Suite("Command palette click toggle state")
struct CommandPaletteClickToggleStateTests {
    @Test("suppresses the mouse-up toggle after mouse-down resign dismissal")
    func suppressesMatchingMouseUpToggle() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)
        #expect(state.isPendingMouseUp(.leftMouseUp))
        let suppressedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(suppressedToggle)
        let suppressedSecondToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedSecondToggle)
    }

    @Test("preserves keyboard and menu toggles")
    func preservesNonmatchingToggles() {
        var state = CommandPaletteClickToggleState()
        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)

        let suppressedKeyboardToggle = state.consumeToggle(during: .keyDown)
        #expect(!suppressedKeyboardToggle)
        let suppressedPairedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(suppressedPairedToggle)

        var menuState = CommandPaletteClickToggleState()
        let suppressedMenuToggle = menuState.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedMenuToggle)
    }

    @Test("expires suppression after a mouse-up without a toggle")
    func expiresAfterMouseUpDispatch() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)
        state.cancel()

        let suppressedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(!suppressedToggle)
    }

    @Test("matches each mouse button to its own release")
    func matchesMouseButton() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .rightMouseDown)
        #expect(recordedDismiss)
        #expect(!state.isPendingMouseUp(.leftMouseUp))
        #expect(state.isPendingMouseUp(.rightMouseUp))
        let suppressedToggle = state.consumeToggle(during: .rightMouseUp)
        #expect(suppressedToggle)
    }

    @Test("drag events preserve the originating click token")
    func dragPreservesPendingToggle() {
        var state = CommandPaletteClickToggleState()

        let recordedDismiss = state.recordResignDismiss(during: .leftMouseDown)
        #expect(recordedDismiss)
        let suppressedDragToggle = state.consumeToggle(during: .leftMouseDragged)
        #expect(!suppressedDragToggle)
        let suppressedPairedToggle = state.consumeToggle(during: .leftMouseUp)
        #expect(suppressedPairedToggle)
    }
}

@Suite("Command palette click toggle tracker")
@MainActor
struct CommandPaletteClickToggleTrackerTests {
    @Test("next distinct click clears a token whose mouse-up was missed")
    func nextClickClearsMissedMouseUp() {
        let monitor = MonitorSpy()
        let tracker = monitor.makeTracker()
        tracker.recordResignDismiss(during: .leftMouseDown)

        tracker.handleMonitoredEvent(.leftMouseDown)

        #expect(!tracker.consumeToggle(during: .leftMouseUp))
        #expect(monitor.removeCount == 1)
    }

    @Test("app deactivation cancels suppression and removes observation")
    func appDeactivationCancelsSuppression() {
        let center = NotificationCenter()
        let monitor = MonitorSpy()
        let tracker = monitor.makeTracker(notificationCenter: center)
        tracker.recordResignDismiss(during: .leftMouseDown)

        center.post(name: NSApplication.didResignActiveNotification, object: nil)

        #expect(!tracker.consumeToggle(during: .leftMouseUp))
        #expect(monitor.removeCount == 1)
    }

    @Test("tracker teardown removes its live monitor")
    func teardownRemovesMonitor() {
        let monitor = MonitorSpy()
        var tracker: CommandPaletteClickToggleTracker? = monitor.makeTracker()
        tracker?.recordResignDismiss(during: .leftMouseDown)

        tracker = nil

        #expect(monitor.removeCount == 1)
    }
}

@MainActor
private final class MonitorSpy {
    private(set) var removeCount = 0
    private let token = NSObject()

    func makeTracker(
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> CommandPaletteClickToggleTracker {
        CommandPaletteClickToggleTracker(
            notificationCenter: notificationCenter,
            addEventMonitor: { [token] _, _ in token },
            removeEventMonitor: { [weak self] _ in self?.removeCount += 1 }
        )
    }
}
