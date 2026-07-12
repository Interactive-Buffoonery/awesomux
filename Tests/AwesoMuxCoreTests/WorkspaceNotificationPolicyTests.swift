import AwesoMuxCore
import XCTest

final class WorkspaceNotificationPolicyTests: XCTestCase {
    private let policy = WorkspaceNotificationPolicy()

    func testSelectedActiveWorkspaceGetsOnlyVisibleAttentionChannels() {
        XCTAssertEqual(
            policy.channels(
                for: .needsAttention,
                focusContext: .selectedWorkspaceActive
            ),
            [.inPaneBanner, .sidebarIndicator, .tabIndicator, .dockBadge]
        )
    }

    func testDifferentActiveWorkspaceGetsInterruptiveAttentionChannels() {
        XCTAssertEqual(
            policy.channels(
                for: .needsAttention,
                focusContext: .otherWorkspaceActive
            ),
            [
                .inPaneBanner,
                .sidebarIndicator,
                .tabIndicator,
                .dockBadge,
                .macOSNotification,
                .sound
            ]
        )
    }

    func testInactiveAppGetsInterruptiveAttentionChannelsEvenForSelectedWorkspace() {
        XCTAssertEqual(
            policy.focusContext(
                isSelectedWorkspace: true,
                isAppActive: false
            ),
            .appInactive
        )
        XCTAssertTrue(
            policy.channels(
                for: .needsAttention,
                focusContext: .appInactive
            ).contains(.macOSNotification)
        )
    }

    func testNonAttentionStatesDoNotFirePolicyChannels() {
        XCTAssertEqual(policy.channels(for: .idle, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .running, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .waiting, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .thinking, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .output, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .done, focusContext: .appInactive), [])
        XCTAssertEqual(policy.channels(for: .error, focusContext: .appInactive), [])
    }

    func testOutputMarksNeedsAttentionGateSuppressesAttentionChannels() {
        XCTAssertEqual(
            policy.channels(
                for: .needsAttention,
                focusContext: .appInactive,
                outputMarksNeedsAttention: false
            ),
            []
        )
    }

    func testWaitingNeverFiresPolicyChannels() {
        XCTAssertEqual(policy.channels(for: .waiting, focusContext: .selectedWorkspaceActive), [])
        XCTAssertEqual(policy.channels(for: .waiting, focusContext: .otherWorkspaceActive), [])
        XCTAssertEqual(policy.channels(for: .waiting, focusContext: .appInactive), [])
        XCTAssertEqual(
            policy.channels(
                executionState: .waiting,
                attentionReason: nil,
                focusContext: .appInactive
            ),
            []
        )
    }

    func testAttentionCanNotifyWhileExecutionIsWaiting() {
        XCTAssertTrue(
            policy.channels(
                executionState: .waiting,
                attentionReason: .desktopNotification,
                focusContext: .appInactive
            ).contains(.macOSNotification)
        )
    }

    // INT-598 per-workspace mute contract: mute strips ONLY the interruptive
    // channels; visible state (sidebar dot, tab indicator, dock badge,
    // in-pane banner) is unaffected in every focus context.
    func testMutedWorkspaceKeepsVisibleStateAndDropsInterruptiveChannels() {
        for focusContext: WorkspaceNotificationPolicy.FocusContext in [
            .otherWorkspaceActive, .appInactive
        ] {
            XCTAssertEqual(
                policy.channels(
                    for: .needsAttention,
                    focusContext: focusContext,
                    isWorkspaceMuted: true
                ),
                .visibleState,
                "muted workspace in \(focusContext) should keep exactly the visible-state channels"
            )
        }
    }

    func testMutedWorkspaceInSelectedActiveContextMatchesUnmuted() {
        // The selected-active context never grants interruptive channels, so
        // mute must be a no-op there — not an accidental visible-state strip.
        XCTAssertEqual(
            policy.channels(
                for: .needsAttention,
                focusContext: .selectedWorkspaceActive,
                isWorkspaceMuted: true
            ),
            policy.channels(
                for: .needsAttention,
                focusContext: .selectedWorkspaceActive,
                isWorkspaceMuted: false
            )
        )
    }

    func testChannelsAllPartitionsVisibleAndInterruptive() {
        XCTAssertEqual(
            WorkspaceNotificationPolicy.Channels.visibleState
                .union(.interruptive),
            WorkspaceNotificationPolicy.Channels.all
        )
        XCTAssertTrue(
            WorkspaceNotificationPolicy.Channels.visibleState
                .intersection(.interruptive)
                .isEmpty
        )
    }
}
