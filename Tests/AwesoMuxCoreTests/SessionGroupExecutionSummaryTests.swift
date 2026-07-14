import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Session group execution summary")
struct SessionGroupExecutionSummaryTests {
    private let alpha = RemoteTarget(user: "alice", host: "alpha")!
    private let zeta = RemoteTarget(user: "zoe", host: "zeta")!

    private func session(_ plans: [PaneExecutionPlan]) -> TerminalSession {
        let panes = plans.enumerated().map { offset, plan in
            TerminalPane(
                title: "pane \(offset + 1)",
                workingDirectory: "~",
                executionPlan: plan
            )
        }
        precondition(!panes.isEmpty)
        var layout = TerminalPaneLayout.pane(panes[panes.count - 1])
        for pane in panes.dropLast().reversed() {
            layout = .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(pane),
                    second: layout
                )
            )
        }
        return TerminalSession(
            title: "workspace",
            workingDirectory: "~",
            layout: layout,
            activePaneID: panes[0].id
        )
    }

    private func replacingExecutionPlans(in value: Any, with replacement: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["executionPlan"] != nil {
                dictionary["executionPlan"] = replacement
            }
            return dictionary.mapValues { replacingExecutionPlans(in: $0, with: replacement) }
        }
        if let array = value as? [Any] {
            return array.map { replacingExecutionPlans(in: $0, with: replacement) }
        }
        return value
    }

    @Test("local panes produce a local-only summary")
    func localOnly() {
        let group = SessionGroup(
            name: "Local",
            sessions: [TerminalSession(title: "shell", workingDirectory: "~")]
        )

        let summary = SessionGroupExecutionSummary(group: group)

        #expect(summary.contents == .localOnly)
        #expect(!summary.hasActiveRemotePanes)
        #expect(!summary.requiresRemoteImpactConfirmation)
    }

    @Test("empty groups retain only their creation default")
    func emptyDefaults() {
        let local = SessionGroupExecutionSummary(
            group: SessionGroup(name: "Empty", sessions: [])
        )
        let remote = SessionGroupExecutionSummary(
            group: SessionGroup(name: "Empty", remote: alpha, sessions: [])
        )

        #expect(local.contents == .empty)
        #expect(local.defaultTarget == nil)
        #expect(!local.requiresRemoteImpactConfirmation)
        #expect(remote.contents == .empty)
        #expect(remote.defaultTarget == alpha)
        #expect(!remote.hasActiveRemotePanes)
        #expect(remote.requiresRemoteImpactConfirmation)
    }

    @Test("a stale SSH default does not turn local panes into remote work")
    func localOnlyWithStaleDefault() {
        let group = SessionGroup(
            name: "Local",
            remote: alpha,
            sessions: [session([.local])]
        )

        let summary = SessionGroupExecutionSummary(group: group)

        #expect(summary.contents == .localOnly)
        #expect(!summary.hasActiveRemotePanes)
        #expect(summary.requiresRemoteImpactConfirmation)
    }

    @Test("all panes on one exact target produce one remote location")
    func oneRemoteTarget() {
        let group = SessionGroup(
            name: "Remote",
            sessions: [
                session([
                    .ssh(SSHExecution(target: alpha)),
                    .ssh(SSHExecution(target: alpha)),
                ])
            ]
        )

        #expect(SessionGroupExecutionSummary(group: group).contents == .singleRemote(alpha))
    }

    @Test("local and remote panes are mixed even on one remote target")
    func localAndRemote() {
        let group = SessionGroup(
            name: "Mixed",
            sessions: [session([.local, .ssh(SSHExecution(target: alpha))])]
        )

        #expect(
            SessionGroupExecutionSummary(group: group).contents
                == .mixed(remoteTargets: [alpha], includesLocal: true)
        )
    }

    @Test("multiple exact destinations are distinct and deterministically sorted")
    func multipleRemoteTargets() {
        let sameHostDifferentUser = RemoteTarget(user: "bob", host: "alpha")!
        let group = SessionGroup(
            name: "Mixed",
            sessions: [
                session([
                    .ssh(SSHExecution(target: zeta)),
                    .ssh(SSHExecution(target: sameHostDifferentUser)),
                    .ssh(SSHExecution(target: alpha)),
                ])
            ]
        )

        #expect(
            SessionGroupExecutionSummary(group: group).contents
                == .mixed(
                    remoteTargets: [alpha, sameHostDifferentUser, zeta],
                    includesLocal: false
                )
        )
    }

    @Test("a remote pane moved into a local-default group keeps remote close safety")
    func movedRemotePane() {
        let group = SessionGroup(
            name: "Local default",
            sessions: [session([.ssh(SSHExecution(target: alpha))])]
        )

        let summary = SessionGroupExecutionSummary(group: group)

        #expect(summary.defaultTarget == nil)
        #expect(summary.hasActiveRemotePanes)
        #expect(summary.requiresRemoteImpactConfirmation)
    }

    @MainActor
    @Test("a restored legacy group summarizes the migrated pane plan")
    func restoredLegacyGroup() throws {
        let legacySession = session([.local])
        let snapshot = SessionSnapshot(
            groups: [
                SessionGroup(
                    name: "Legacy",
                    remote: alpha,
                    sessions: [legacySession]
                )
            ],
            selectedSessionID: legacySession.id
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let data = try JSONSerialization.data(
            withJSONObject: replacingExecutionPlans(in: encoded, with: NSNull())
        )
        let restored = SessionStore(
            restoring: try JSONDecoder().decode(SessionSnapshot.self, from: data)
        )
        let group = try #require(restored.groups.first)

        #expect(SessionGroupExecutionSummary(group: group).contents == .singleRemote(alpha))
    }

    @Test("close safety compares exact pane identity and declared location")
    func exactCloseSafety() {
        let originalSession = session([.local, .ssh(SSHExecution(target: alpha))])
        let original = SessionGroup(
            name: "Work",
            remote: alpha,
            sessions: [originalSession]
        )
        let unchanged = SessionGroupCloseSafetySummary(group: original)

        var retargetedSession = originalSession
        retargetedSession.layout = retargetedSession.layout.mappingPanes { pane in
            var changed = pane
            if pane.executionPlan.remoteTarget != nil {
                changed.executionPlan = .ssh(SSHExecution(target: zeta))
            }
            return changed
        }
        let retargeted = SessionGroupCloseSafetySummary(
            group: SessionGroup(
                id: original.id,
                name: original.name,
                remote: alpha,
                sessions: [retargetedSession]
            )
        )

        #expect(unchanged == SessionGroupCloseSafetySummary(group: original))
        #expect(unchanged != retargeted)
    }

    @Test("close safety ignores sessions that left after confirmation")
    func closeSafetyLimitedToConfirmedMembers() {
        let confirmed = session([.ssh(SSHExecution(target: alpha))])
        let joined = session([.ssh(SSHExecution(target: zeta))])
        let group = SessionGroup(name: "Work", sessions: [confirmed, joined])

        let summary = SessionGroupCloseSafetySummary(
            group: group,
            limitedTo: [confirmed.id]
        )

        #expect(Set(summary.paneLocations.map(\.sessionID)) == [confirmed.id])
    }

    @Test("modal safety ignores joined and moved sessions but rejects retargeting")
    func modalSafetyComparison() {
        let confirmed = session([.ssh(SSHExecution(target: alpha))])
        let moved = session([.ssh(SSHExecution(target: zeta))])
        let before = SessionGroup(name: "Work", sessions: [confirmed, moved])
        let joined = session([.local])
        let afterMembershipChange = SessionGroup(
            id: before.id,
            name: before.name,
            sessions: [confirmed, joined]
        )

        #expect(
            !SessionGroupCloseSafetySummary.hasMaterialChange(
                from: before,
                to: afterMembershipChange,
                confirmedSessionIDs: [confirmed.id, moved.id]
            )
        )

        var retargeted = confirmed
        retargeted.layout = retargeted.layout.mappingPanes { pane in
            var pane = pane
            pane.executionPlan = .ssh(SSHExecution(target: zeta))
            return pane
        }
        let afterRetarget = SessionGroup(
            id: before.id,
            name: before.name,
            sessions: [retargeted, joined]
        )

        #expect(
            SessionGroupCloseSafetySummary.hasMaterialChange(
                from: before,
                to: afterRetarget,
                confirmedSessionIDs: [confirmed.id, moved.id]
            )
        )
    }
}
