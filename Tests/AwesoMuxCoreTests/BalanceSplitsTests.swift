import Foundation
import Observation
import Synchronization
import Testing
@testable import AwesoMuxCore

@MainActor
struct BalanceSplitsTests {
    private let pane = TerminalPane(title: "shell", workingDirectory: "/tmp", executionPlan: .local)

    @Test
    func returnRebalancesWhenSourceReplacesAPane() throws {
        let (store, id) = fixture(.pane(pane))
        let second = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let third = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let moved = try #require(store.movePaneToNewWorkspace(id: third, in: id))
        store.setActivePane(id: pane.id, in: id)
        _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        _ = try #require(store.closePane(id: second, in: id))
        #expect(store.returnPaneToSourceWorkspace(sessionID: moved))
        let returned = try #require(store.session(id: id))
        guard case let .split(root) = returned.layout else {
            Issue.record("Expected a split")
            return
        }
        #expect(abs(root.firstFraction - 1.0 / 3) < 0.001)
    }

    @Test
    func immediateReturnPreservesAutomaticParentOfManualSibling() throws {
        let (store, id) = fixture(.pane(pane))
        _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let original = try #require(store.session(id: id))
        guard case let .split(root) = original.layout, case let .split(sibling) = root.second else {
            Issue.record("Expected nested splits")
            return
        }
        store.resizeSplit(id: sibling.id, firstFraction: 0.4, in: id)
        let moved = try #require(store.movePaneToNewWorkspace(id: pane.id, in: id))
        #expect(store.returnPaneToSourceWorkspace(sessionID: moved))
        let returned = try #require(store.session(id: id))
        #expect(returned.layout.split(id: root.id)?.firstFraction == root.firstFraction)
        #expect(returned.layout.split(id: sibling.id)?.firstFraction == 0.4)
    }

    @Test(arguments: [false, true], [false, true])
    func returningPaneRebalancesUntouchedDividers(editSource: Bool, detachFirst: Bool) throws {
        let (store, id) = fixture(.pane(pane))
        _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let third = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let detached = detachFirst ? pane.id : third
        let moved = try #require(store.movePaneToNewWorkspace(id: detached, in: id))
        if editSource {
            store.setActivePane(id: detachFirst ? third : pane.id, in: id)
            _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        }
        #expect(store.returnPaneToSourceWorkspace(sessionID: moved))
        let restored = try #require(store.session(id: id))
        guard case let .split(root) = restored.layout else {
            Issue.record("Expected a split")
            return
        }
        let expected = editSource ? (detachFirst ? 0.25 : 0.5) : 1.0 / 3
        #expect(abs(root.firstFraction - expected) < 0.001)
        #expect(restored.activePaneID == detached)
    }

    @Test
    func splitAndCloseRebalanceUntouchedDividers() throws {
        let (store, id) = fixture(.pane(pane))
        let second = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let third = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let triple = try #require(store.session(id: id))
        guard case let .split(root) = triple.layout else {
            Issue.record("Expected three panes")
            return
        }
        #expect(abs(root.firstFraction - 1.0 / 3) < 0.001)
        #expect(triple.activePaneID == third)
        #expect(triple.layout.pane(id: pane.id)?.localTerminalSessionName == pane.localTerminalSessionName)
        _ = try #require(store.closePane(id: third, in: id))
        let pair = try #require(store.session(id: id))
        #expect(pair.layout.split(id: root.id)?.firstFraction == 0.5)
        #expect(pair.activePaneID == second)
    }

    @Test
    func splitAndCloseRespectADividerManuallyReturnedToHalf() throws {
        let (store, id) = fixture(.pane(pane))
        _ = try #require(store.splitActivePane(orientation: .vertical, in: id))
        let pair = try #require(store.session(id: id))
        guard case let .split(root) = pair.layout else {
            Issue.record("Expected a divider")
            return
        }
        store.resizeSplit(id: root.id, firstFraction: 0.4, in: id)
        store.resizeSplit(id: root.id, firstFraction: 0.5, in: id)
        let third = try #require(store.splitActivePane(orientation: .vertical, in: id))
        #expect(store.session(id: id)?.layout.split(id: root.id)?.firstFraction == 0.5)
        _ = try #require(store.closePane(id: third, in: id))
        #expect(store.session(id: id)?.layout.split(id: root.id)?.firstFraction == 0.5)
    }

    @Test(arguments: [480.0, 481.0, 482.0], [true, false])
    func equalizesTwoPanesAndBothThreePaneNestings(width: Double, nestedFirst: Bool) throws {
        let leaf = TerminalPaneLayout.pane(pane)
        let pair = split(leaf, .pane(TerminalPane(title: "second", workingDirectory: "/tmp", executionPlan: .local)))
        let third = TerminalPaneLayout.pane(TerminalPane(title: "third", workingDirectory: "/tmp", executionPlan: .local))
        let triple = nestedFirst ? split(pair, third) : split(third, pair)
        for (layout, count) in [(pair, 2), (triple, 3)] {
            let (store, id) = fixture(layout)
            let size = CGSize(width: width, height: 250)
            #expect(store.balanceSplits(in: id, size: size))
            let balanced = try #require(store.session(id: id)?.layout)
            let extents = leafSizes(balanced, size)
            #expect(extents.count == count)
            for extent in extents {
                #expect(abs(extent.width - (width - Double(count - 1)) / Double(count)) < 1e-10)
            }
        }
    }

    @Test
    func balancesMixedAxesWithOneRatioOnlyWrite() throws {
        let leaf = TerminalPaneLayout.pane(pane)
        let tab = DocumentPane(fileURL: URL(fileURLWithPath: "/tmp/balance.md"), title: "Balance")
        let documents = TerminalPaneLayout.documentGroup(DocumentGroup(tabs: [tab], selectedTabID: tab.id))
        let other = TerminalPaneLayout.pane(TerminalPane(title: "second", workingDirectory: "/tmp", executionPlan: .local))
        let layout = split(split(leaf, documents, axis: .horizontal), other)
        let (store, id) = fixture(layout)
        let original = try #require(store.session(id: id))
        let size = CGSize(width: 481, height: 201)

        let changed = trackGroups(store)
        #expect(store.balanceSplits(in: id, size: size))
        #expect(changed.value.withLock { $0 })
        let balanced = try #require(store.session(id: id))
        #expect(
            leafSizes(balanced.layout, size) == [
                CGSize(width: 240, height: 100), CGSize(width: 240, height: 100), CGSize(width: 240, height: 201),
            ])
        guard case let .split(root) = layout, case let .split(child) = root.first else {
            Issue.record("Expected two split nodes")
            return
        }
        var expected = original
        expected.layout = layout.resizingSplit(id: root.id, firstFraction: 0.5)
            .resizingSplit(id: child.id, firstFraction: 0.5)
        #expect(balanced == expected)
        #expect(store.selectedSessionID == id)

        let repeated = trackGroups(store)
        #expect(store.balanceSplits(in: id, size: size))
        #expect(!repeated.value.withLock { $0 })
        #expect(store.session(id: id) == balanced)
    }

    @Test
    func clampsSevenLanesAndRejectsUnrepresentableGeometryBeforePublishing() throws {
        let layout = (1..<7).reduce(TerminalPaneLayout.pane(pane)) { tree, index in
            split(tree, .pane(TerminalPane(title: "pane \(index)", workingDirectory: "/tmp", executionPlan: .local)))
        }
        let (store, id) = fixture(layout)
        let original = store.groups
        let rejected = trackGroups(store)
        for width in [0, 6, Double.infinity, Double.nan] {
            #expect(!store.balanceSplits(in: id, size: CGSize(width: width, height: 100)))
        }
        #expect(!rejected.value.withLock { $0 })
        #expect(store.groups == original)

        let size = CGSize(width: 700, height: 100)
        #expect(store.balanceSplits(in: id, size: size))
        let balanced = try #require(store.session(id: id)?.layout)
        guard case let .split(root) = balanced else {
            Issue.record("Expected a split")
            return
        }
        #expect(root.firstFraction == 0.85)
        let extents = leafSizes(balanced, size)
        #expect(extents.count == 7)
        #expect(extents.allSatisfy { $0.width > 0 && $0.height > 0 })
        #expect(abs(extents.map(\.width).reduce(0, +) - 694) < 1e-10)
    }

    @Test
    func movesInwardWhenTheRenderedSecondChildRoundsToZero() throws {
        let leaves = (0..<4).map { index in
            TerminalPaneLayout.pane(
                index == 0
                    ? pane
                    : TerminalPane(
                        title: "pane \(index)", workingDirectory: "/tmp", executionPlan: .local
                    ))
        }
        let layout = split(split(split(leaves[0], leaves[1]), leaves[2]), leaves[3])
        let (store, id) = fixture(layout)
        let size = CGSize(width: 3.0.nextUp.nextUp, height: 100)
        #expect(store.balanceSplits(in: id, size: size))
        let balanced = try #require(store.session(id: id)?.layout)
        #expect(leafSizes(balanced, size).allSatisfy { $0.width > 0 })
    }

    private func fixture(_ layout: TerminalPaneLayout) -> (SessionStore, TerminalSession.ID) {
        let session = TerminalSession(title: "workspace", workingDirectory: "/tmp", layout: layout, activePaneID: pane.id)
        return (SessionStore(groups: [SessionGroup(name: "group", sessions: [session])]), session.id)
    }

    private func split(
        _ first: TerminalPaneLayout,
        _ second: TerminalPaneLayout,
        axis: TerminalSplitOrientation = .vertical
    ) -> TerminalPaneLayout {
        .split(TerminalSplit(orientation: axis, first: first, second: second, firstFraction: 0.7))
    }

    private final class GroupChange: Sendable {
        let value = Mutex(false)
    }

    private func trackGroups(_ store: SessionStore) -> GroupChange {
        let changed = GroupChange()
        withObservationTracking {
            _ = store.groups
        } onChange: {
            changed.value.withLock { $0 = true }
        }
        return changed
    }

    // Reproduce the renderer arithmetic independently, including subtraction before multiplication on the second side.
    private func leafSizes(_ layout: TerminalPaneLayout, _ size: CGSize) -> [CGSize] {
        guard case let .split(split) = layout else { return [size] }
        let axis: WritableKeyPath<CGSize, CGFloat> = split.orientation == .vertical ? \.width : \.height
        var first = size
        var second = size
        first[keyPath: axis] = size[keyPath: axis] * split.firstFraction - 0.5
        second[keyPath: axis] = size[keyPath: axis] * (1 - split.firstFraction) - 0.5
        return leafSizes(split.first, first) + leafSizes(split.second, second)
    }
}
