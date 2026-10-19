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

    private enum ContentsCase: CaseIterable { case local, emptyLocal, emptyRemote, staleDefault, oneRemote, localAndRemote, multipleRemote }

    @Test(arguments: ContentsCase.allCases)
    private func contents(scenario: ContentsCase) {
        let plans: [PaneExecutionPlan]
        let defaultTarget: RemoteTarget?
        let expected: SessionGroupExecutionSummary.Contents
        let bob = RemoteTarget(user: "bob", host: "alpha")!
        switch scenario {
        case .local: plans = [.local]; defaultTarget = nil; expected = .localOnly
        case .emptyLocal: plans = []; defaultTarget = nil; expected = .empty
        case .emptyRemote: plans = []; defaultTarget = alpha; expected = .empty
        case .staleDefault: plans = [.local]; defaultTarget = alpha; expected = .localOnly
        case .oneRemote:
            plans = [.ssh(SSHExecution(target: alpha)), .ssh(SSHExecution(target: alpha))]; defaultTarget = nil;
            expected = .singleRemote(alpha)
        case .localAndRemote:
            plans = [.local, .ssh(SSHExecution(target: alpha))]; defaultTarget = nil;
            expected = .mixed(remoteTargets: [alpha], includesLocal: true)
        case .multipleRemote:
            plans = [.ssh(SSHExecution(target: zeta)), .ssh(SSHExecution(target: bob)), .ssh(SSHExecution(target: alpha))]
            defaultTarget = nil; expected = .mixed(remoteTargets: [alpha, bob, zeta], includesLocal: false)
        }
        let summary = SessionGroupExecutionSummary(
            group: SessionGroup(name: "Work", remote: defaultTarget, sessions: plans.isEmpty ? [] : [session(plans)]))
        #expect(summary.contents == expected)
        #expect(summary.defaultTarget == defaultTarget)
    }

    private enum OwnershipCase: CaseIterable { case mixed, remoteOnly, localOnly }

    @Test(arguments: OwnershipCase.allCases)
    private func ownership(scenario: OwnershipCase) throws {
        let remoteOwned = try #require(
            SSHExecution(
                target: scenario == .mixed ? zeta : alpha, persistenceOwner: .remoteZmx, sessionName: RemoteSessionName(rawValue: "work")))
        let plans: [PaneExecutionPlan] =
            scenario == .mixed
            ? [.ssh(SSHExecution(target: alpha)), .ssh(remoteOwned)] : scenario == .remoteOnly ? [.ssh(remoteOwned)] : [.local]
        let summary = SessionGroupExecutionSummary(group: SessionGroup(name: "Work", sessions: [session(plans)]))
        #expect(summary.localAmxTargets == (scenario == .mixed ? [alpha] : []))
        #expect(summary.remoteOwnedTargets == (scenario == .mixed ? [zeta] : scenario == .remoteOnly ? [alpha] : []))
        #expect(summary.includesLocallyOwnedSessions == (scenario != .remoteOnly))
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
            restoring: try SessionSnapshot.decode(from: data)
        )
        let group = try #require(restored.groups.first)

        #expect(SessionGroupExecutionSummary(group: group).contents == .singleRemote(alpha))
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
