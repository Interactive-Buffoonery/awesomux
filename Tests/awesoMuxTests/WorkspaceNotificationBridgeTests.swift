import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing
import UserNotifications
@testable import awesoMux

@Suite("Workspace notification bridge authorization coalescing")
struct WorkspaceNotificationBridgeTests {
    private static func event(title: String = "workspace") -> WorkspaceNotificationEvent {
        WorkspaceNotificationEvent(
            sessionID: UUID(),
            title: title,
            agentKind: .claudeCode,
            unreadNotificationCount: 1
        )
    }

    /// The bridge that survived four review lanes: `postWorkspaceNotification`
    /// had its own authorization path calling `center.requestAuthorization`
    /// directly — no explanation, no in-flight latch — so a first-run user's
    /// first attention event showed the bare macOS dialog. Nothing here touched
    /// that path, which is why it survived.
    ///
    /// Driven with the latch already set so the delegated round trip stops at
    /// its guard: a real `UNUserNotificationCenter` crashes an unbundled test
    /// process, and the point of the assertion is that this post *delegates*
    /// rather than requesting on its own.
    @Test("An undetermined post delegates instead of requesting")
    @MainActor
    func undeterminedPostDelegatesToGuardedPrime() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.setAuthorizationStatusForTesting(.notDetermined)
        bridge.beginAuthorizationRequestForTesting()

        bridge.postWorkspaceNotification(Self.event())

        #expect(bridge.pendingAuthorizationEventCountForTesting == 1)
        #expect(bridge.explanationPresentationCountForTesting == 0)
        #expect(bridge.isAuthorizationRequestInFlight == true)
    }

    /// `AppDelegate.evaluateAndPostNotifications()` posts a batch in a
    /// synchronous loop and `authorizationStatus` only updates on the first
    /// completion, so the old code fired one system dialog per eligible event.
    @Test("A synchronous batch of undetermined posts starts one round trip")
    @MainActor
    func undeterminedBatchCoalescesToOneRoundTrip() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.setAuthorizationStatusForTesting(.notDetermined)
        bridge.beginAuthorizationRequestForTesting()

        for index in 0..<3 {
            bridge.postWorkspaceNotification(Self.event(title: "workspace \(index)"))
        }

        #expect(bridge.pendingAuthorizationEventCountForTesting == 3)
        #expect(bridge.explanationPresentationCountForTesting == 0)
    }

    /// A denied answer must drop the queue rather than leave it to grow across
    /// every later agent tick.
    @Test("A denied authorization discards the deferred events")
    @MainActor
    func deniedAuthorizationDiscardsDeferredEvents() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.setAuthorizationStatusForTesting(.notDetermined)
        bridge.beginAuthorizationRequestForTesting()
        bridge.postWorkspaceNotification(Self.event())

        bridge.handlePrimeRequestResult(granted: false)

        #expect(bridge.pendingAuthorizationEventCountForTesting == 0)
        #expect(bridge.isAuthorizationRequestInFlight == false)
    }

    /// Fix J's early-out is only safe with an invalidation path. Settings →
    /// Notifications deep-links the user into System Settings so a `.denied`
    /// answer can be reversed, and that re-query never reaches this cache — so
    /// without this every later event would hit `case .denied` and be dropped
    /// until relaunch.
    @Test("A settled authorization status does not survive an app activation")
    @MainActor
    func activationInvalidatesCachedStatus() {
        let bridge = WorkspaceNotificationBridge()
        bridge.setAuthorizationStatusForTesting(.denied)

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)

        #expect(bridge.authorizationStatusForTesting == nil)
    }

    /// A settled answer is not worth an XPC round trip. Priming is wired to
    /// session-store mutations, which tick on ordinary agent state changes, so
    /// without the early-out this re-queried notifyd forever. The observable
    /// proof: the latch is never taken, because the refresh is never started.
    @Test("A settled authorization status skips the status round trip")
    @MainActor
    func settledStatusSkipsRefresh() {
        let bridge = WorkspaceNotificationBridge()
        bridge.configurePreferencesProvider { NotificationPreferences.allEnabledForTesting }
        bridge.setAuthorizationStatusForTesting(.denied)

        bridge.requestAuthorizationWithExplanationIfNeeded()

        #expect(bridge.isAuthorizationRequestInFlight == false)
        #expect(bridge.explanationPresentationCountForTesting == 0)
    }

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
    @Test(
        "The in-flight flag clears when the authorization request finishes",
        arguments: [true, false])
    @MainActor
    func clearsFlagWhenRequestFinishes(granted: Bool) {
        let bridge = WorkspaceNotificationBridge()
        bridge.beginAuthorizationRequestForTesting()

        bridge.handlePrimeRequestResult(granted: granted)

        #expect(bridge.isAuthorizationRequestInFlight == false)
    }
}
