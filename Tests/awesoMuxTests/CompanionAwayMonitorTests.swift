import AppKit
import AwesoMuxCore
import Testing

@testable import awesoMux

// Failure model: lock delivery can trail the first journal write; stale lock
// and unlock callbacks can arrive after the console has already changed again.
@MainActor
@Suite("Companion away monitor", .serialized)
struct CompanionAwayMonitorTests {
    @Test func journalWritesReconcileBeforeAuthenticatedActivity() {
        let pane = TerminalPane(title: "Shell", workingDirectory: "/tmp", executionPlan: .local)
        let workspace = TerminalSession(title: "Workspace", workingDirectory: "/tmp", layout: .pane(pane))
        let store = SessionStore(groups: [SessionGroup(name: "Group", sessions: [workspace])])
        store.bindLocalAPIInstance(UUID())
        var away = false
        let monitor = CompanionAwayMonitor(store: store, consoleIsAway: { away }, appIsActive: { true })
        away = true
        store.recordCommandCompletion(
            sessionID: workspace.id, paneID: pane.id, terminalSessionID: pane.terminalSessionID,
            executionPlan: pane.executionPlan,
            completion: ShellCommandCompletion(exitCode: 1, durationNanoseconds: 40_000_000_000)!)
        monitor.recordAuthenticatedActivity()
        away = false
        monitor.reconcile()
        #expect(store.whileAwaySummary?.events.count == 1)
        // A delayed lock signal reads the current console rather than reopening
        // the interval; a delayed unlock likewise cannot close a new interval.
        monitor.reconcile()
        store.dismissWhileAwaySummary()
        away = true
        monitor.reconcile()
        monitor.reconcile()
        monitor.recordAuthenticatedActivity()
        store.recordCommandCompletion(
            sessionID: workspace.id, paneID: pane.id, terminalSessionID: pane.terminalSessionID,
            executionPlan: pane.executionPlan,
            completion: ShellCommandCompletion(exitCode: 1, durationNanoseconds: 40_000_000_000)!)
        away = false
        monitor.reconcile()
        #expect(store.whileAwaySummary?.events.count == 1)
    }

    @Test func activationReconcilesButWaitsForActiveApp() {
        let pane = TerminalPane(title: "Agent", workingDirectory: "/tmp", agentKind: .codex, executionPlan: .local)
        let workspace = TerminalSession(title: "Workspace", workingDirectory: "/tmp", layout: .pane(pane))
        let store = SessionStore(groups: [SessionGroup(name: "Group", sessions: [workspace])])
        store.bindLocalAPIInstance(UUID())
        var away: Bool? = false
        var active = false
        let monitor = CompanionAwayMonitor(store: store, consoleIsAway: { away }, appIsActive: { active })
        away = true
        store.updatePermissionPromptAttention(sessionID: workspace.id, paneID: pane.id, countDelta: 1, hasPending: true)
        monitor.recordAuthenticatedActivity()
        away = nil
        #expect(!monitor.reconcile())
        away = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.whileAwaySummary == nil)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(store.whileAwaySummary?.events.count == 1)
    }
}
