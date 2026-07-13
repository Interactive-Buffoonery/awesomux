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
