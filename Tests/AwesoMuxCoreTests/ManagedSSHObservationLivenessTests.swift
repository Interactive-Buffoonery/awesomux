import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("Managed SSH observation liveness")
struct ManagedSSHObservationLivenessTests {
    @Test("idle local shell clears runtime remote observation")
    func idleLocalShellClearsConversionTarget() throws {
        let (store, sessionID, paneID) = makeStore(executionPlan: .local)

        #expect(store.managedSSHConversionTarget(sessionID: sessionID, paneID: paneID) != nil)

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .idleShell
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remoteSSHTarget == nil)
        #expect(pane.pendingRemoteSSHTarget == nil)
        #expect(!pane.hasConsumedManagedSSHWorkspaceOffer)
        #expect(pane.remoteHost == nil)
        #expect(pane.executionPlan == .local)
        #expect(store.managedSSHConversionTarget(sessionID: sessionID, paneID: paneID) == nil)
        #expect(!store.index.remotePaneIDs.contains(paneID))

        store.noteSubmittedCommand(sessionID: sessionID, paneID: paneID, command: "ssh next-alias")
        store.updatePane(
            sessionID: sessionID,
            paneID: paneID,
            title: "deploy@next.example: ~"
        )

        let reconnected = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(reconnected.remoteHost == "next.example")
        #expect(reconnected.remoteSSHTarget == "next-alias")
    }

    @Test(
        "unproven process states retain the conversion target",
        arguments: [
            ForegroundProcessLiveness.unsampled,
            .bridged,
            .bridgedBusy,
            .bridgedIndeterminate,
            .exited,
            .busyShell,
            .liveCommand,
            .indeterminate,
        ]
    )
    func unprovenProcessStateRetainsTarget(liveness: ForegroundProcessLiveness) throws {
        let (store, sessionID, paneID) = makeStore(executionPlan: .local)

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: liveness
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remoteSSHTarget == "deploy@server-alias")
        #expect(pane.pendingRemoteSSHTarget == "pending-alias")
        #expect(pane.hasConsumedManagedSSHWorkspaceOffer)
    }

    @Test("managed execution plan retains its runtime target at an idle shell")
    func managedPaneRetainsTarget() throws {
        let target = try #require(RemoteTarget(parsing: "deploy@server-alias"))
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .ssh(SSHExecution(target: target))
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .idleShell
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remoteSSHTarget == "deploy@server-alias")
        #expect(pane.pendingRemoteSSHTarget == "pending-alias")
        #expect(pane.hasConsumedManagedSSHWorkspaceOffer)
        #expect(pane.executionPlan == .ssh(SSHExecution(target: target)))
    }

    @Test("targetless remote observation clears so a later safe SSH can be captured")
    func targetlessRemoteObservationDoesNotBlockLaterSSH() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: nil,
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .idleShell
        )
        store.noteSubmittedCommand(sessionID: sessionID, paneID: paneID, command: "ssh next-alias")
        store.updatePane(
            sessionID: sessionID,
            paneID: paneID,
            title: "deploy@next.example: ~"
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remoteHost == "next.example")
        #expect(pane.remoteSSHTarget == "next-alias")
    }

    @Test("pending target alone survives the pre-exec idle shell window")
    func pendingTargetSurvivesIdleShell() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .idleShell
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == "next-alias")
        #expect(pane.hasManagedSSHObservation)
    }

    @Test("pending target survives a sampled shell before exec")
    func pendingTargetSurvivesSampledShell() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .busyShell,
            foregroundCommand: "zsh"
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == "next-alias")
        #expect(pane.hasManagedSSHObservation)
    }

    @Test("foreground SSH retains an active observed SSH process")
    func foregroundSSHRetainsActiveObservedSSH() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remotePresentationHost == "next-alias")
        #expect(store.index.remotePaneIDs.contains(paneID))
    }

    @Test("a pre-launch helper preserves pending SSH until the next local submission")
    func preLaunchHelperPreservesPendingSSHUntilNextLocalSubmission() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "make"
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(!pane.hasObservedPendingRemoteSSHProcess)
        #expect(pane.pendingRemoteSSHTarget == "next-alias")
        #expect(pane.remotePresentationHost == nil)
        #expect(!store.index.remotePaneIDs.contains(paneID))

        store.noteSubmittedCommand(
            sessionID: sessionID,
            paneID: paneID,
            command: "echo done",
            submittedFromLocalShell: true
        )
        #expect(store.session(id: sessionID)?.layout.pane(id: paneID)?.pendingRemoteSSHTarget == nil)
    }

    @Test("a new local prompt SSH submission replaces an unobserved stale target")
    func newSSHSubmissionReplacesUnobservedStaleTarget() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "failed-alias",
            hasConsumedOffer: false
        )

        store.noteSubmittedCommand(
            sessionID: sessionID,
            paneID: paneID,
            command: "ssh retry-alias",
            submittedFromLocalShell: true
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == "retry-alias")
        #expect(!pane.hasObservedPendingRemoteSSHProcess)
    }

    @Test("a shell-named wrapper cannot replace an observed SSH target")
    func shellNamedWrapperCannotReplaceObservedSSHTarget() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "old-alias",
            hasConsumedOffer: false
        )
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )
        #expect(store.index.remotePaneIDs.contains(paneID))

        store.noteSubmittedCommand(
            sessionID: sessionID,
            paneID: paneID,
            command: "echo remote-input",
            submittedFromLocalShell: true
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == "old-alias")
        #expect(pane.hasObservedPendingRemoteSSHProcess)
        #expect(pane.remotePresentationHost == "old-alias")
        #expect(store.index.remotePaneIDs.contains(paneID))
    }

    @Test("an optioned command cannot replace an observed SSH target")
    func optionedCommandCannotReplaceObservedSSHTarget() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "old-alias",
            hasConsumedOffer: false
        )
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )

        store.noteSubmittedCommand(
            sessionID: sessionID,
            paneID: paneID,
            command: "ssh -p 2222 new-host",
            submittedFromLocalShell: true
        )
        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == "old-alias")
        #expect(pane.remotePresentationHost == "old-alias")
        #expect(store.index.remotePaneIDs.contains(paneID))
    }

    @Test("title-confirmed wrapped SSH survives a bridged shell sample")
    func titleConfirmedWrappedSSHSurvivesBridgedShellSample() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .bridgedBusy,
            foregroundCommand: "ssh"
        )
        store.updatePane(
            sessionID: sessionID,
            paneID: paneID,
            title: "deploy@next.example: ~"
        )
        #expect(store.index.remotePaneIDs.contains(paneID))

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )
        #expect(
            store.session(id: sessionID)?.layout.pane(id: paneID)?.remotePresentationHost
                == "next.example"
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .bridged
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.remotePresentationHost == "next.example")
        #expect(store.index.remotePaneIDs.contains(paneID))
    }

    @Test("an observed SSH command clears after returning to the local shell")
    func observedSSHCommandClearsAtLocalPrompt() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .liveCommand,
            foregroundCommand: "ssh"
        )
        #expect(
            store.managedSSHConversionSuggestion(
                sessionID: sessionID,
                paneID: paneID
            )?.sshDestination == "next-alias"
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .idleShell
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == nil)
        #expect(
            store.managedSSHConversionSuggestion(sessionID: sessionID, paneID: paneID) == nil
        )
    }

    @Test("an observed bridged SSH command clears when the daemon shell becomes idle")
    func observedBridgedSSHCommandClearsAtDaemonPrompt() throws {
        let (store, sessionID, paneID) = makeStore(
            executionPlan: .local,
            remoteHost: nil,
            remoteSSHTarget: nil,
            pendingRemoteSSHTarget: "next-alias",
            hasConsumedOffer: false
        )

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .bridgedBusy,
            foregroundCommand: "ssh"
        )

        let observed = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(observed.remotePresentationHost == "next-alias")
        #expect(store.index.remotePaneIDs.contains(paneID))

        store.clearManagedSSHObservationIfExitedToLocalShell(
            sessionID: sessionID,
            paneID: paneID,
            liveness: .bridged
        )

        let pane = try #require(store.session(id: sessionID)?.layout.pane(id: paneID))
        #expect(pane.pendingRemoteSSHTarget == nil)
        #expect(pane.remotePresentationHost == nil)
        #expect(!store.index.remotePaneIDs.contains(paneID))
    }

    private func makeStore(
        executionPlan: PaneExecutionPlan,
        remoteHost: String? = "server.example",
        remoteSSHTarget: String? = "deploy@server-alias",
        pendingRemoteSSHTarget: String? = "pending-alias",
        hasConsumedOffer: Bool = true
    ) -> (SessionStore, TerminalSession.ID, TerminalPane.ID) {
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "~",
            remoteHost: remoteHost,
            remoteSSHTarget: remoteSSHTarget,
            hasConsumedManagedSSHWorkspaceOffer: hasConsumedOffer,
            pendingRemoteSSHTarget: pendingRemoteSSHTarget,
            executionPlan: executionPlan
        )
        let session = TerminalSession(
            title: "remote",
            workingDirectory: "~",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        return (
            SessionStore(
                groups: [SessionGroup(name: "Work", sessions: [session])],
                selectedSessionID: session.id
            ),
            session.id,
            pane.id
        )
    }
}
