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

    // Guards the latch bug directly: coalescing alone can pass even if the
    // flag is never cleared, since a permanently-true flag also drops every
    // later call. This drives a full round trip (via the status override,
    // never a real UNUserNotificationCenter — see WorkspaceNotificationBridge
    // .center's doc comment) and requires the flag to come back down.
    @Test("The in-flight flag is cleared once a round trip completes")
    @MainActor
    func clearsFlagAfterCompletedRoundTrip() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.authorizationStatusOverrideForTesting = .denied

        bridge.requestAuthorizationWithExplanationIfNeeded()

        #expect(bridge.isAuthorizationRequestInFlight == false)
    }
}
