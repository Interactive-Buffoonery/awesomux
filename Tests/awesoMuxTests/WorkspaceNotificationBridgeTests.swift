import AwesoMuxConfig
import Testing
import UserNotifications
@testable import awesoMux

@Suite("Workspace notification bridge authorization coalescing")
struct WorkspaceNotificationBridgeTests {
    @Test("A second prime request while one is in flight is dropped")
    @MainActor
    func coalescesInFlightPrime() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.beginAuthorizationRequestForTesting()
        #expect(bridge.isAuthorizationRequestInFlight == true)
        bridge.requestAuthorizationWithExplanationIfNeeded()
        #expect(bridge.explanationPresentationCountForTesting == 0)
    }

    // Guards the latch bug on the "already decided" exit: a burst of
    // mutations that finds authorization already denied/authorized must not
    // leave the flag stuck true, or every later prime request drops forever.
    // Drives `handlePrimeStatus` directly (see its doc comment) rather than
    // the full round trip, since a real `UNUserNotificationCenter` crashes an
    // unbundled test process.
    @Test("The in-flight flag clears when the status is already decided")
    @MainActor
    func clearsFlagWhenStatusAlreadyDecided() {
        let bridge = WorkspaceNotificationBridge()
        bridge.beginAuthorizationRequestForTesting()

        bridge.handlePrimeStatus(.denied)

        #expect(bridge.isAuthorizationRequestInFlight == false)
    }

    // Guards the latch bug on the OTHER exit: once the system request itself
    // finishes (granted or denied), the flag must also clear, or the first
    // real "not determined yet" prime latches the bridge permanently.
    @Test("The in-flight flag clears when the authorization request finishes")
    @MainActor
    func clearsFlagWhenRequestFinishes() {
        let bridge = WorkspaceNotificationBridge()
        bridge.beginAuthorizationRequestForTesting()

        bridge.handlePrimeRequestResult(granted: true)

        #expect(bridge.isAuthorizationRequestInFlight == false)
    }
}
