import AwesoMuxCore
import AwesoMuxConfig
import AwesoMuxTestSupport
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import awesoMux

@MainActor
@Suite("Sidebar peek model hover handoff (INT-538)")
struct SidebarPeekModelTests {
    private func twoPaneSession(_ title: String) -> TerminalSession {
        let first = TestData.pane(title: "a", workingDirectory: "~")
        let second = TestData.pane(title: "b", workingDirectory: "~")
        return TestData.session(
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

    @Test("session peek stores the inward edge for either sidebar position")
    func sessionPeekUsesPositionAwareInwardEdge() {
        let model = SidebarPeekModel()
        let session = twoPaneSession("A")
        let frame = CGRect(x: 40, y: 10, width: 80, height: 30)

        model.show(session: session, location: location, tint: tint, frame: frame, position: .left)
        #expect(model.anchorX == frame.maxX)
        #expect(model.peekDirection == .right)

        model.updateFrame(for: session.id, frame: frame, position: .right)
        #expect(model.anchorX == frame.minX)
        #expect(model.peekDirection == .left)
    }

    @Test("intrinsic card alignment hugs the rail on either side")
    func intrinsicCardAlignmentHugsRail() {
        #expect(SidebarPeekCardAlignmentPolicy.resolve(peekDirection: .right) == .leading)
        #expect(SidebarPeekCardAlignmentPolicy.resolve(peekDirection: .left) == .trailing)
    }

    @Test("group peek stores the inward edge for either sidebar position")
    func groupPeekUsesPositionAwareInwardEdge() {
        let model = SidebarPeekModel()
        let (group, a, b) = twoSessionGroup("Code")
        let frame = CGRect(x: 40, y: 10, width: 80, height: 30)

        model.showGroup(
            group: group,
            tint: tint,
            sessions: [a, b],
            activeSessionID: a.id,
            frame: frame,
            position: .right
        )
        #expect(model.anchorX == frame.minX)
        #expect(model.peekDirection == .left)

        model.updateGroupFrame(for: group.id, frame: frame, position: .left)
        #expect(model.anchorX == frame.maxX)
        #expect(model.peekDirection == .right)
    }

    @Test("requestHide hides after the grace when the pointer never reaches the card")
    func requestHideHidesAfterGrace() async {
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let a = twoPaneSession("A")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.session == nil })
        #expect(model.session == nil)
    }

    @Test("pointer reaching the card cancels the pending hide")
    func pointerOverCardCancelsHide() async {
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let a = twoPaneSession("A")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)
        // The grace task must be suspended at its delay point before the
        // pointer lands, so this exercises cancel-of-a-pending-grace (and, via
        // the release below, that the resumed task no-ops on its guards) —
        // not cancel-before-start.
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.setPointerOverCard(true, for: a.id)
        gate.advance()
        await drainMainQueue()
        #expect(model.session?.id == a.id)
    }

    @Test("peek hover retains temporary sidebar reveal until its own grace ends")
    func peekHoverRetainsTemporarySidebarReveal() async throws {
        let peekGate = TestScheduler()
        let presentationGate = TestScheduler()
        let peek = SidebarPeekModel(sleep: { duration in await peekGate.wait(for: duration) })
        let suiteName = "SidebarPeekModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let presentation = SidebarPresentationModel(
            store: store,
            delay: { duration in await presentationGate.wait(for: duration) })
        peek.onPointerChanged = presentation.peekPointerChanged
        let session = twoPaneSession("A")
        peek.show(session: session, location: location, tint: tint, frame: .zero)
        presentation.pointerMoved(x: 15, width: 100, position: .left)
        presentation.trackingRegionExited()
        #expect(await waitUntil { presentationGate.sleeperCount == 1 })

        peek.setPointerOverCard(true, for: session.id)
        presentationGate.advanceOneCycle()
        await drainMainQueue()
        #expect(presentation.isTemporarilyRevealed)

        peek.setPointerOverCard(false, for: session.id)
        #expect(await waitUntil { presentationGate.sleeperCount == 1 })
        presentationGate.advance()
        #expect(await waitUntil { !presentation.isSidebarVisible })

        let proxy = SidebarSplitProxy()
        proxy.setOverlayVisible = { _, _, _ in true }
        ContentView.reconcileSidebarOverlay(
            presentation: presentation,
            peekModel: peek,
            proxy: proxy,
            transition: .hover,
            reduceMotion: true)

        #expect(peek.session == nil)
        peekGate.advance()
        await drainMainQueue()
        #expect(peek.session == nil)
        #expect(presentation.proximityState == .dormant)
    }

    @Test("clearing a hovered peek releases sidebar retention")
    func clearingHoveredPeekReleasesSidebarRetention() async throws {
        let gate = TestScheduler()
        let peek = SidebarPeekModel()
        let suiteName = "SidebarPeekModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(true)
        let presentation = SidebarPresentationModel(
            store: store, delay: { duration in await gate.wait(for: duration) })
        peek.onPointerChanged = presentation.peekPointerChanged
        let session = twoPaneSession("A")
        peek.show(session: session, location: location, tint: tint, frame: .zero)
        presentation.pointerMoved(x: 15, width: 100, position: .left)
        peek.setPointerOverCard(true, for: session.id)
        presentation.trackingRegionExited()

        peek.hideAll()

        #expect(peek.session == nil)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { !presentation.isSidebarVisible })
    }

    @Test("stale peek teardown does not steal explicit visibility ownership")
    func stalePeekTeardownPreservesExplicitOwnership() throws {
        let peek = SidebarPeekModel()
        let suiteName = "SidebarPeekModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SidebarPresentationPreferenceStore(defaults: defaults)
        store.saveHidden(false)
        let presentation = SidebarPresentationModel(store: store)
        peek.onPointerChanged = presentation.peekPointerChanged
        let session = twoPaneSession("A")
        peek.show(session: session, location: location, tint: tint, frame: .zero)
        peek.setPointerOverCard(true, for: session.id)

        #expect(presentation.applyPersistentHidden(true) { _ in .applied } == .applied)
        peek.hideAll()

        #expect(presentation.userWantsHidden)
        #expect(presentation.proximityState == .dormant)
        #expect(presentation.visibilitySource == .explicit)
    }

    @Test("show takeover resets the pointer flag so the new card can still hide")
    func showResetsPointerFlagAcrossTakeover() async {
        // Codex 538 regression: pointer rests on card A; tile B's `show` wins
        // before A's `onHover(false)` lands. A's late false no-ops on the
        // session-id guard. Without `show` resetting `isPointerOverCard`, B's
        // requestHide would never fire and B's card would strand open.
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let a = twoPaneSession("A")
        let b = twoPaneSession("B")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.setPointerOverCard(true, for: a.id)
        model.show(session: b, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == b.id)

        model.requestHide(for: b.id)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.session == nil })
        #expect(model.session == nil)
    }

    @Test("a stale grace fire cannot hide a card a newer show put up")
    func staleGraceDoesNotHideNewSession() async {
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let a = twoPaneSession("A")
        let b = twoPaneSession("B")
        model.show(session: a, location: location, tint: tint, frame: .zero)
        model.requestHide(for: a.id)  // grace scheduled for A
        // Suspend A's grace at its delay point BEFORE B's takeover, so the
        // release below resumes a genuinely stale task — it must no-op via the
        // cancel guard and the session-id re-guard.
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.show(session: b, location: location, tint: tint, frame: .zero)  // cancels it
        gate.advance()
        await drainMainQueue()
        #expect(model.session?.id == b.id)  // B survived
    }

    private func twoSessionGroup(_ name: String) -> (SessionGroup, TerminalSession, TerminalSession) {
        let a = TestData.session(title: "A", workingDirectory: "~")
        let b = TestData.session(title: "B", workingDirectory: "~")
        let group = TestData.workspace(name: name, sessions: [a, b])
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
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        gate.advance()
        #expect(await waitUntil { model.group == nil })
        #expect(model.group == nil)
    }

    @Test("pointer reaching the group card cancels the pending hide")
    func pointerOverGroupCardCancelsHide() async {
        let gate = TestScheduler()
        let model = SidebarPeekModel(sleep: { duration in await gate.wait(for: duration) })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.sleeperCount == 1 })
        model.setPointerOverGroupCard(true, for: group.id)
        gate.advance()
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

}
