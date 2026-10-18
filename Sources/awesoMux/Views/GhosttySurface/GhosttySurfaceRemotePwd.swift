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
    let generation: UInt64
    let report: String
    let deadline: TimeInterval
}

extension GhosttySurfaceNSView {
    private static let remotePwdPrefix = "awesomux:remote-osc7:"
    private static let remotePwdLocalHostnames = LocalHostnames.resolve()

    /// Consumed synchronously during app tick, before ordinary PWD handling.
    func consumeRemotePwdEnvelope(_ value: String, source: ghostty_surface_t?) -> Bool {
        guard value.hasPrefix(Self.remotePwdPrefix) else { return false }
        if let current = sessionStore.session(id: sessionID)?.layout.pane(id: paneID) {
            synchronizeRemotePwdGeneration(sessionID: sessionID, current: current)
        }
        let envelope = value.dropFirst(Self.remotePwdPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard envelope.count == 2, let generation = UInt64(envelope[0]), generation != 0,
            generation == terminalEventState.nativeRemotePwdGeneration
        else { return true }
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
        let report = String(envelope[1])
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
            incarnation: lifecycleState.mouseSurfaceIncarnationID, generation: generation, report: report,
            deadline: CACurrentMediaTime() + 1)
        terminalEventState.pendingRemotePwd = pending
        let expiry = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancelPendingRemotePwd() }
        }
        terminalEventState.remotePwdExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: expiry)
        return true
    }

    /// Compare against a separate snapshot, not the SwiftUI view's delivery-time pane.
    func synchronizeRemotePwdGeneration(sessionID: TerminalSession.ID, current: TerminalPane) {
        defer { terminalEventState.nativeRemotePwdSnapshot = (sessionID, current) }
        guard let snapshot = terminalEventState.nativeRemotePwdSnapshot else { return }
        let previous = snapshot.pane
        let sameIdentity =
            snapshot.sessionID == sessionID && previous.id == current.id
            && previous.terminalSessionID == current.terminalSessionID
            && previous.executionPlan == current.executionPlan
        let initialRecognition =
            previous.remoteHost == nil
            && current.remoteHost.map { host in
                previous.executionPlan.remoteTarget.map {
                    RemoteWorkingDirectoryValidator.hostsMatch($0.host, host)
                } ?? true
            } == true
        let connectionChanged =
            previous.remoteConnectivityEpoch != current.remoteConnectivityEpoch
            || previous.remoteConnectionHealth != current.remoteConnectionHealth
        let observationChanged =
            previous.remoteHost != current.remoteHost
            || previous.pendingRemoteSSHTarget != current.pendingRemoteSSHTarget
            || previous.remoteSSHTarget != current.remoteSSHTarget
        if !sameIdentity || connectionChanged || (observationChanged && !initialRecognition) {
            advanceRemotePwdGeneration()
        }
    }

    func advanceRemotePwdGeneration() {
        cancelPendingRemotePwd()
        let generation = terminalEventState.nativeRemotePwdGeneration
        // Exhaustion disables this view permanently, including replacement surfaces.
        terminalEventState.nativeRemotePwdGeneration = generation == 0 || generation == .max ? 0 : generation + 1
        if let surface {
            awesomux_surface_set_remote_pwd_generation(surface, terminalEventState.nativeRemotePwdGeneration)
        }
    }

    func cancelPendingRemotePwd() {
        terminalEventState.remotePwdExpiry?.cancel()
        terminalEventState.remotePwdExpiry = nil
        terminalEventState.pendingRemotePwd = nil
    }

    func clearNativeRemotePwd() {
        advanceRemotePwdGeneration()
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
            pending.generation == terminalEventState.nativeRemotePwdGeneration,
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
