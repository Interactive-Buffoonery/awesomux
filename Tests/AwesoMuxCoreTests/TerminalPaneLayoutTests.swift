import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Terminal pane layout")
struct TerminalPaneLayoutTests {
    @Test("terminal pane layout preserves nested pane identity across coding")
    func terminalPaneLayoutCodingRoundTrip() throws {
        let first = TerminalPane(title: "one", workingDirectory: "/tmp/one", executionPlan: .local)
        let second = TerminalPane(title: "two", workingDirectory: "/tmp/two", executionPlan: .local)
        let layout = TerminalPaneLayout.split(
            TerminalSplit(
                orientation: .horizontal,
                first: .pane(first),
                second: .pane(second),
                firstFraction: 0.35
            )
        )

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(TerminalPaneLayout.self, from: data)

        #expect(decoded == layout)
        #expect(decoded.paneIDs == [first.id, second.id])
    }

    @Test("paneIDs preserves depth-first order through nested splits")
    func paneIDsPreservesDepthFirstOrder() {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local)
        let layout = nestedLayout(first: first, second: second, third: third)

        #expect(layout.paneIDs == [first.id, second.id, third.id])

        var appendedIDs: [TerminalPane.ID] = []
        layout.appendPaneIDs(into: &appendedIDs)
        #expect(appendedIDs == [first.id, second.id, third.id])
    }

    @Test("appendRemotePaneIDs preserves nested remote pane membership")
    func appendRemotePaneIDsFindsNestedRemotePanes() {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(
            title: "second",
            workingDirectory: "~",
            remoteHost: "webserver",
            executionPlan: .local
        )
        let third = TerminalPane(
            title: "third",
            workingDirectory: "~",
            remoteHost: "db",
            remoteConnectionHealth: .possiblyStale,
            executionPlan: .local
        )
        let layout = nestedLayout(first: first, second: second, third: third)

        var remoteIDs = Set<TerminalPane.ID>()
        layout.appendRemotePaneIDs(into: &remoteIDs)

        #expect(remoteIDs == Set([second.id, third.id]))
    }

    @Test("contains finds nested panes without materializing paneIDs")
    func containsFindsNestedPanes() {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local)
        let layout = nestedLayout(first: first, second: second, third: third)

        #expect(layout.contains(paneID: first.id))
        #expect(layout.contains(paneID: second.id))
        #expect(layout.contains(paneID: third.id))
        #expect(!layout.contains(paneID: TerminalPane.ID()))
    }

    @Test("removing a nested pane collapses only its owning split")
    func removingNestedPaneCollapsesOwningSplit() throws {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local)
        let layout = nestedLayout(first: first, second: second, third: third)

        let nextLayout = try #require(layout.removingPane(id: third.id))

        #expect(nextLayout.paneIDs == [first.id, second.id])
        guard case let .split(root) = nextLayout,
              case let .pane(survivor) = root.second else {
            Issue.record("Expected root split with collapsed nested sibling")
            return
        }
        #expect(survivor.id == second.id)
    }

    @Test("resize by pane adjusts the nearest containing split")
    func resizeByPaneAdjustsNearestContainingSplit() throws {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local)
        let layout = nestedLayout(first: first, second: second, third: third)

        let nextLayout = try #require(layout.resizingSplit(containing: third.id, by: 0.1))

        guard case let .split(root) = nextLayout,
              case let .split(nested) = root.second else {
            Issue.record("Expected nested split to survive resize")
            return
        }
        #expect(root.firstFraction == 0.5)
        #expect(nested.firstFraction == 0.4)
    }

    @Test("marking stale returns no change for nested splits with no remote panes")
    func markingRemotePanesPossiblyStaleDoesNotChangeLocalSplits() {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(title: "second", workingDirectory: "~", executionPlan: .local)
        let third = TerminalPane(title: "third", workingDirectory: "~", executionPlan: .local)
        let layout = nestedLayout(first: first, second: second, third: third)

        let result = layout.markingRemotePanesPossiblyStale()

        #expect(result.didChange == false)
        #expect(result.layout == layout)
    }

    @Test("marking stale returns no change when all remote panes are already stale")
    func markingRemotePanesPossiblyStaleDoesNotChangeAlreadyStaleRemotePanes() {
        let first = TerminalPane(title: "first", workingDirectory: "~", executionPlan: .local)
        let second = TerminalPane(
            title: "second",
            workingDirectory: "~",
            remoteHost: "webserver",
            remoteConnectionHealth: .possiblyStale,
            executionPlan: .local
        )
        let third = TerminalPane(
            title: "third",
            workingDirectory: "~",
            remoteHost: "db",
            remoteConnectionHealth: .possiblyStale,
            executionPlan: .local
        )
        let layout = nestedLayout(first: first, second: second, third: third)

        let result = layout.markingRemotePanesPossiblyStale()

        #expect(result.didChange == false)
        #expect(result.layout.pane(id: second.id)?.remoteConnectionHealth == .possiblyStale)
        #expect(result.layout.pane(id: third.id)?.remoteConnectionHealth == .possiblyStale)
    }

    @Test("marking stale recurses through splits and preserves layout shape")
    func markingRemotePanesPossiblyStaleRecursesAndPreservesLayoutShape() throws {
        let rootSplitID = TerminalSplit.ID()
        let nestedSplitID = TerminalSplit.ID()
        let localPane = TerminalPane(title: "local", workingDirectory: "~", executionPlan: .local)
        let activeRemotePane = TerminalPane(
            title: "remote",
            workingDirectory: "~",
            remoteHost: "webserver",
            executionPlan: .local
        )
        let staleRemotePane = TerminalPane(
            title: "stale",
            workingDirectory: "~",
            remoteHost: "db",
            remoteConnectionHealth: .possiblyStale,
            executionPlan: .local
        )
        let layout = nestedLayout(
            first: localPane,
            second: activeRemotePane,
            third: staleRemotePane,
            rootSplitID: rootSplitID,
            nestedSplitID: nestedSplitID,
            rootFirstFraction: 0.35,
            nestedFirstFraction: 0.65
        )

        let result = layout.markingRemotePanesPossiblyStale()

        #expect(result.didChange)
        #expect(result.layout.paneIDs == [localPane.id, activeRemotePane.id, staleRemotePane.id])
        #expect(result.layout.pane(id: localPane.id)?.remoteConnectionHealth == .active)
        #expect(result.layout.pane(id: activeRemotePane.id)?.remoteConnectionHealth == .possiblyStale)
        #expect(result.layout.pane(id: staleRemotePane.id)?.remoteConnectionHealth == .possiblyStale)

        let root = try #require(result.layout.split(id: rootSplitID))
        #expect(root.orientation == .vertical)
        #expect(root.firstFraction == 0.35)
        let nested = try #require(result.layout.split(id: nestedSplitID))
        #expect(nested.orientation == .horizontal)
        #expect(nested.firstFraction == 0.65)
    }

    private func nestedLayout(
        first: TerminalPane,
        second: TerminalPane,
        third: TerminalPane,
        rootSplitID: TerminalSplit.ID = TerminalSplit.ID(),
        nestedSplitID: TerminalSplit.ID = TerminalSplit.ID(),
        rootFirstFraction: Double = 0.5,
        nestedFirstFraction: Double = 0.5
    ) -> TerminalPaneLayout {
        .split(
            TerminalSplit(
                id: rootSplitID,
                orientation: .vertical,
                first: .pane(first),
                second: .split(
                    TerminalSplit(
                        id: nestedSplitID,
                        orientation: .horizontal,
                        first: .pane(second),
                        second: .pane(third),
                        firstFraction: nestedFirstFraction
                    )
                ),
                firstFraction: rootFirstFraction
            )
        )
    }
}
