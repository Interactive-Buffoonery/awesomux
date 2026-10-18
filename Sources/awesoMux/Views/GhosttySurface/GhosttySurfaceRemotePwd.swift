import AppKit
import AwesoMuxCore
import GhosttyKit

/// A report can precede the first throttled title, but cannot survive a connection.
@MainActor
struct PendingRemotePwd {
    let sessionID: TerminalSession.ID
    let pane: TerminalPane
    let surface: ghostty_surface_t
    let incarnation: UInt64?
    let report: String
    let deadline: TimeInterval
}

extension GhosttySurfaceNSView {
    private static let remotePwdPrefix = "awesomux:remote-osc7:"
    private static let remotePwdLocalHostnames = LocalHostnames.resolve()

    /// Consumed synchronously during app tick, before ordinary PWD handling.
    func consumeRemotePwdEnvelope(_ value: String, source: ghostty_surface_t?) -> Bool {
        guard value.hasPrefix(Self.remotePwdPrefix) else { return false }
        guard let source, surface == source, !ghostty_surface_process_exited(source),
            let origin = terminalEventState.nativeRemotePwdOrigin,
            origin.sessionID == sessionID, origin.pane.id == paneID,
            let current = sessionStore.session(id: sessionID)?.layout.pane(id: paneID),
            origin.pane.terminalSessionID == current.terminalSessionID,
            origin.pane.executionPlan == current.executionPlan,
            current.terminalSessionID == pane.terminalSessionID,
            current.executionPlan == pane.executionPlan,
            current.remoteConnectivityEpoch == pane.remoteConnectivityEpoch
        else { return true }
        cancelPendingRemotePwd()
        let report = String(value.dropFirst(Self.remotePwdPrefix.count))
        let expectedHost = current.remoteHost ?? current.executionPlan.remoteTarget?.host
        if expectedHost != nil {
            sessionStore.updateNativeRemoteWorkingDirectory(
                sessionID: sessionID, originatingPane: current, report: report)
            return true
        }
        sessionStore.updateNativeRemoteWorkingDirectory(
            sessionID: sessionID, originatingPane: current, report: nil)
        guard
            RemoteWorkingDirectoryValidator.validatedNativeReport(
                report, expectedHost: nil, localHostnames: Self.remotePwdLocalHostnames) != nil
        else { return true }
        let pending = PendingRemotePwd(
            sessionID: sessionID, pane: current, surface: source,
            incarnation: lifecycleState.mouseSurfaceIncarnationID, report: report, deadline: CACurrentMediaTime() + 1)
        terminalEventState.pendingRemotePwd = pending
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancelPendingRemotePwd() }
        }
        terminalEventState.remotePwdExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: expiry)
        return true
    }

    func cancelPendingRemotePwd() {
        terminalEventState.remotePwdExpiry?.cancel()
        terminalEventState.remotePwdExpiry = nil
        terminalEventState.pendingRemotePwd = nil
    }

    func clearNativeRemotePwd() {
        cancelPendingRemotePwd()
        guard let current = sessionStore.session(id: sessionID)?.layout.pane(id: paneID),
            current.terminalSessionID == pane.terminalSessionID
        else { return }
        sessionStore.updateNativeRemoteWorkingDirectory(
            sessionID: sessionID, originatingPane: current, report: nil)
    }

    func qualifyPendingRemotePwd(previous: TerminalPane?) {
        guard let pending = terminalEventState.pendingRemotePwd else { return }
        // The first committed title is the only opportunity to qualify this report.
        cancelPendingRemotePwd()
        guard let previous, previous.remoteHost == nil,
            let current = sessionStore.session(id: sessionID)?.layout.pane(id: paneID),
            current.remoteHost != nil,
            pending.sessionID == sessionID, pending.pane.id == paneID,
            pending.surface == surface,
            pending.incarnation == lifecycleState.mouseSurfaceIncarnationID,
            !ghostty_surface_process_exited(pending.surface),
            pending.deadline >= CACurrentMediaTime(),
            pending.pane.terminalSessionID == current.terminalSessionID,
            pending.pane.executionPlan == current.executionPlan,
            pending.pane.remoteConnectivityEpoch == current.remoteConnectivityEpoch,
            pending.pane.remoteConnectionHealth == current.remoteConnectionHealth,
            pending.pane.pendingRemoteSSHTarget == previous.pendingRemoteSSHTarget,
            pending.pane.remoteSSHTarget == previous.remoteSSHTarget
        else { return }
        sessionStore.updateNativeRemoteWorkingDirectory(
            sessionID: sessionID, originatingPane: current, report: pending.report)
    }
}
