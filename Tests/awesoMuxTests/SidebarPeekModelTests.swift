import AwesoMuxCore
import CoreGraphics
import Testing
@testable import awesoMux

@MainActor
@Suite("Sidebar peek model hover handoff (INT-538)")
struct SidebarPeekModelTests {
    private func twoPaneSession(_ title: String) -> TerminalSession {
        let first = TerminalPane(title: "a", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "b", workingDirectory: "~", executionPlan: .local)
        return TerminalSession(
            title: title,
            workingDirectory: "~",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(first),
                    second: .pane(second)
                )),
            activePaneID: first.id
        )
    }

    private var tint: ProjectTint { ProjectTint(groupName: "g", color: nil, index: 0) }
    private var location: SidebarSessionLocation { .local("~") }

    @Test("requestHide hides after the grace when the pointer never reaches the card")
    func requestHideHidesAfterGrace() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let a = twoPaneSession("A")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        gate.release()
        #expect(await waitUntil { model.session == nil })
        #expect(model.session == nil)
    }

    @Test("pointer reaching the card cancels the pending hide")
    func pointerOverCardCancelsHide() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let a = twoPaneSession("A")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)
        // The grace task must be suspended at its delay point before the
        // pointer lands, so this exercises cancel-of-a-pending-grace (and, via
        // the release below, that the resumed task no-ops on its guards) —
        // not cancel-before-start.
        #expect(await waitUntil { gate.waiterCount == 1 })
        model.setPointerOverCard(true, for: a.id)
        gate.release()
        await drainMainQueue()
        #expect(model.session?.id == a.id)
    }

    @Test("show takeover resets the pointer flag so the new card can still hide")
    func showResetsPointerFlagAcrossTakeover() async {
        // Codex 538 regression: pointer rests on card A; tile B's `show` wins
        // before A's `onHover(false)` lands. A's late false no-ops on the
        // session-id guard. Without `show` resetting `isPointerOverCard`, B's
        // requestHide would never fire and B's card would strand open.
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let a = twoPaneSession("A")
        let b = twoPaneSession("B")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.setPointerOverCard(true, for: a.id)
        model.show(session: b, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == b.id)

        model.requestHide(for: b.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        gate.release()
        #expect(await waitUntil { model.session == nil })
        #expect(model.session == nil)
    }

    @Test("a stale grace fire cannot hide a card a newer show put up")
    func staleGraceDoesNotHideNewSession() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let a = twoPaneSession("A")
        let b = twoPaneSession("B")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)  // grace scheduled for A
        // Suspend A's grace at its delay point BEFORE B's takeover, so the
        // release below resumes a genuinely stale task — it must no-op via the
        // cancel guard and the session-id re-guard.
        #expect(await waitUntil { gate.waiterCount == 1 })
        model.show(session: b, location: location, tint: tint, frame: .zero)  // cancels it
        gate.release()
        await drainMainQueue()
        #expect(model.session?.id == b.id)  // B survived
    }

    private func twoSessionGroup(_ name: String) -> (SessionGroup, TerminalSession, TerminalSession) {
        let a = TerminalSession(title: "A", workingDirectory: "~", agentKind: .shell, agentState: .idle)
        let b = TerminalSession(title: "B", workingDirectory: "~", agentKind: .shell, agentState: .idle)
        let group = SessionGroup(name: name, sessions: [a, b])
        return (group, a, b)
    }

    @Test("showGroup clears any active session peek, and vice versa")
    func showGroupAndShowSessionAreMutuallyExclusive() async {
        let model = SidebarPeekModel()
        let session = twoPaneSession("A")
        let (group, ga, gb) = twoSessionGroup("Code")

        model.show(session: session, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == session.id)
        #expect(model.group == nil)

        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: ga.id, frame: .zero)
        #expect(model.group?.id == group.id)
        #expect(model.groupSessionItems.map(\.id) == [ga.id, gb.id])
        #expect(model.session == nil)  // showing the group cleared the session peek

        model.show(session: session, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == session.id)
        #expect(model.group == nil)  // showing the session cleared the group peek
    }

    @Test("requestHideGroup hides after the grace when the pointer never reaches the card")
    func requestHideGroupHidesAfterGrace() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        gate.release()
        #expect(await waitUntil { model.group == nil })
        #expect(model.group == nil)
    }

    @Test("pointer reaching the group card cancels the pending hide")
    func pointerOverGroupCardCancelsHide() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        model.setPointerOverGroupCard(true, for: group.id)
        gate.release()
        await drainMainQueue()
        #expect(model.group?.id == group.id)
    }

    @Test("refreshGroup updates content only while this group owns the peek")
    func refreshGroupGuardsOwnership() async {
        let model = SidebarPeekModel()
        let (groupA, aOne, aTwo) = twoSessionGroup("A")
        let (groupB, _, _) = twoSessionGroup("B")
        model.showGroup(group: groupA, tint: tint, sessions: [aOne, aTwo], activeSessionID: nil, frame: .zero)

        // A different, non-owning group's refresh must no-op.
        model.refreshGroup(group: groupB, tint: tint, sessions: [], activeSessionID: nil)
        #expect(model.group?.id == groupA.id)

        // The owning group's refresh updates content in place.
        model.refreshGroup(group: groupA, tint: tint, sessions: [aOne], activeSessionID: aOne.id)
        #expect(model.groupSessionItems.map(\.id) == [aOne.id])
        #expect(model.groupSessionItems[0].isActive == true)
    }

    /// Yield-poll with a bound: deterministic (no wall clock — pending
    /// main-actor jobs run whenever this suspends), and a condition that never
    /// comes reports a failure rather than hanging the suite.
    private func waitUntil(
        _ condition: () -> Bool,
        attempts: Int = 10_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }
}
