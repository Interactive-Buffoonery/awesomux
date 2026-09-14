import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct CodexPermissionNotificationTests {
    private let start = Date(timeIntervalSince1970: 100)

    private func session(reason: AttentionReason? = .permissionPrompt) -> TerminalSession {
        TerminalSession(
            title: "codex", workingDirectory: "~",
            layout: .pane(
                TerminalPane(
                    title: "codex", workingDirectory: "~", agentKind: .codex,
                    agentExecutionState: .thinking, attentionReason: reason,
                    unreadNotificationCount: 1, executionPlan: .local
                ))
        )
    }

    @Test
    func persistentPermissionNotifiesOnceAfterGrace() {
        let groups = [SessionGroup(name: "test", sessions: [session()])]
        var tracker = WorkspaceNotificationTracker()
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start) }().isEmpty)
        #expect(tracker.nextNotificationDeadline == start.addingTimeInterval(10))
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(9)) }().isEmpty)
        #expect(tracker.nextNotificationDeadline == start.addingTimeInterval(10))
        #expect(
            { tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(10)) }().count == 1)
        #expect(tracker.nextNotificationDeadline == nil)
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(20)) }().isEmpty)
    }

    @Test
    func resolvedPermissionCancelsNotification() {
        var paneSession = session()
        var tracker = WorkspaceNotificationTracker()
        #expect(
            {
                tracker.notificationEvents(
                    afterUpdating: [SessionGroup(name: "test", sessions: [paneSession])], selectedSessionID: nil, now: start)
            }().isEmpty)
        _ = WorkspaceAttentionReducer.updatePane(
            &paneSession, paneID: paneSession.activePaneID,
            update: .init(clearsAttention: true, attentionClearIsAuthoritative: true, clearsUnreadNotifications: true),
            now: start.addingTimeInterval(4)
        )
        #expect(
            {
                tracker.notificationEvents(
                    afterUpdating: [SessionGroup(name: "test", sessions: [paneSession])], selectedSessionID: nil,
                    now: start.addingTimeInterval(10))
            }().isEmpty)
        #expect(tracker.nextNotificationDeadline == nil)
    }

    @Test
    func otherAttentionRemainsImmediate() {
        let groups = [SessionGroup(name: "test", sessions: [session(reason: .userInputRequired)])]
        var tracker = WorkspaceNotificationTracker()
        #expect({ tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start) }().count == 1)
        #expect(tracker.nextNotificationDeadline == nil)
    }

    @Test
    func removedPaneCancelsDeadline() {
        var tracker = WorkspaceNotificationTracker()
        _ = tracker.notificationEvents(
            afterUpdating: [SessionGroup(name: "test", sessions: [session()])], selectedSessionID: nil, now: start)
        _ = tracker.notificationEvents(afterUpdating: [], selectedSessionID: nil, now: start.addingTimeInterval(1))
        #expect(tracker.nextNotificationDeadline == nil)
    }

    @Test(arguments: ["mute", "focus", "disabled", "output-disabled", "reset"])
    func noLongerEligibleCancelsDeadline(change: String) {
        var pending = session()
        var tracker = WorkspaceNotificationTracker()
        _ = tracker.notificationEvents(afterUpdating: [SessionGroup(name: "test", sessions: [pending])], selectedSessionID: nil, now: start)
        #expect(tracker.nextNotificationDeadline != nil)
        if change == "mute" { pending.notificationsMuted = true }
        let groups = [SessionGroup(name: "test", sessions: [pending])]
        if change == "reset" {
            tracker.reset(groups: groups)
        }
        let events = tracker.notificationEvents(
            afterUpdating: groups,
            selectedSessionID: change == "focus" ? pending.id : nil,
            outputMarksNeedsAttention: change != "output-disabled",
            notifyOnNeedsAttention: change != "disabled",
            now: start.addingTimeInterval(5)
        )
        #expect(events.isEmpty)
        #expect(tracker.nextNotificationDeadline == nil)
    }

    @Test(arguments: [true, false])
    func siblingBannerConsumesDeferredPermission(codexFirst: Bool) throws {
        let codex = try #require(session().activePane)
        let claude = TerminalPane(
            title: "claude", workingDirectory: "~", agentKind: .claudeCode,
            attentionReason: .userInputRequired, unreadNotificationCount: 1, executionPlan: .local
        )
        let split = TerminalSession(
            title: "split", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(codexFirst ? codex : claude),
                    second: .pane(codexFirst ? claude : codex)
                )))
        let groups = [SessionGroup(name: "test", sessions: [split])]
        var tracker = WorkspaceNotificationTracker()
        let events = tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start)
        #expect(events.count == 1)
        #expect(tracker.nextNotificationDeadline == nil)
        let later = tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, now: start.addingTimeInterval(10))
        #expect(later.isEmpty)
    }

    @Test(arguments: [true, false])
    func siblingTurnDonePreservesDeferredPermission(codexFirst: Bool) throws {
        let codex = try #require(session().activePane)
        let finished = TerminalPane(
            title: "finished", workingDirectory: "~", agentKind: .claudeCode,
            agentExecutionState: .waiting, unreadNotificationCount: 1, executionPlan: .local
        )
        let split = TerminalSession(
            title: "split", workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(codexFirst ? codex : finished),
                    second: .pane(codexFirst ? finished : codex)
                )))
        let groups = [SessionGroup(name: "test", sessions: [split])]
        var tracker = WorkspaceNotificationTracker()
        let immediate = tracker.notificationEvents(afterUpdating: groups, selectedSessionID: nil, notifyOnTurnDone: true, now: start)
        #expect(immediate.map(\.kind) == [.turnDone])
        #expect(tracker.nextNotificationDeadline == start.addingTimeInterval(10))
        let delayed = tracker.notificationEvents(
            afterUpdating: groups, selectedSessionID: nil, notifyOnTurnDone: true, now: start.addingTimeInterval(10))
        #expect(delayed.map(\.kind) == [.needsAttention])
        #expect(tracker.nextNotificationDeadline == nil)
    }
}
