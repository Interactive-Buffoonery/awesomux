import CoreGraphics
import Testing
@testable import awesoMux

@Suite("SidebarInsertionResolver")
struct SidebarInsertionResolverTests {
    @Test("insertion index follows row midpoints")
    func insertionIndexFollowsMidpoints() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
        ]
        let ids = ["a", "b", "c"]

        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 4, orderedIDs: ids, frames: frames) == 0)
        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 16, orderedIDs: ids, frames: frames) == 1)
        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 36, orderedIDs: ids, frames: frames) == 2)
        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 60, orderedIDs: ids, frames: frames) == 3)
    }

    @Test("insertion y lands before, between, and after frames")
    func insertionYUsesGapsBetweenFrames() throws {
        let frames: [Int: CGRect] = [
            0: CGRect(x: 0, y: 10, width: 100, height: 10),
            1: CGRect(x: 0, y: 30, width: 100, height: 10),
        ]
        let ids = [0, 1]

        #expect(SidebarInsertionResolver.insertionY(forInsertionIndex: 0, orderedIDs: ids, frames: frames, spacing: 8) == 6)
        #expect(SidebarInsertionResolver.insertionY(forInsertionIndex: 1, orderedIDs: ids, frames: frames, spacing: 8) == 25)
        #expect(SidebarInsertionResolver.insertionY(forInsertionIndex: 2, orderedIDs: ids, frames: frames, spacing: 8) == 44)
    }

    @Test("partial frame caches keep visible drop positions")
    func partialFrameCachesKeepVisibleDropPositions() {
        let frames: [String: CGRect] = [
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
        ]
        let ids = ["a", "b", "c", "d"]

        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 16, orderedIDs: ids, frames: frames) == 1)
        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 36, orderedIDs: ids, frames: frames) == 2)
        #expect(SidebarInsertionResolver.insertionIndex(forDropY: 60, orderedIDs: ids, frames: frames) == 3)
        #expect(SidebarInsertionResolver.insertionY(forInsertionIndex: 1, orderedIDs: ids, frames: frames, spacing: 8) == 16)
        #expect(SidebarInsertionResolver.insertionY(forInsertionIndex: 3, orderedIDs: ids, frames: frames, spacing: 8) == 54)
    }

    @Test("empty frame cache holds the drop (returns nil, not append-to-end)")
    func emptyFrameCacheReturnsNil() {
        // Codex #3: with no cached frames, the old resolver returned
        // orderedIDs.count — silently biasing a top-of-list drop to the END.
        // It must now return nil so the delegate holds until frames arrive.
        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: 10,
                orderedIDs: ["a", "b", "c"],
                frames: [:]
            ) == nil
        )
    }

    @Test("all-zero-height frames are treated as no usable layout (returns nil)")
    func zeroHeightFramesReturnNil() {
        // Rows that just materialized report zero-height frames for a layout
        // pass before the real geometry propagates — that is not usable
        // hit-test data, so hold rather than guess.
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 0),
            "b": CGRect(x: 0, y: 0, width: 100, height: 0),
        ]

        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: 10,
                orderedIDs: ["a", "b"],
                frames: frames
            ) == nil
        )
    }

    /// An empty group holds too, and this is a deliberate architectural
    /// choice rather than a side effect of having no frames to inspect.
    /// `NewWorkspaceInGroupRowPolicy.ownsDropDelegate` gives an empty group's
    /// row its own drop delegate precisely *because* this resolver holds; if
    /// this ever resolved (say to 0, which looks unambiguous for an empty
    /// list) the list delegate would start competing with that row delegate,
    /// producing the flip-flopping affordances the policy exists to prevent.
    @Test("an empty group holds the drop so its row delegate can own it")
    func emptyGroupReturnsNil() {
        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: 10,
                orderedIDs: [String](),
                frames: [:]
            ) == nil
        )
    }

    @Test("a single real frame is enough to resolve (not held)")
    func oneRealFrameResolves() {
        let frames: [String: CGRect] = [
            "b": CGRect(x: 0, y: 20, width: 100, height: 10)
        ]

        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: 16,
                orderedIDs: ["a", "b", "c"],
                frames: frames
            ) == 1
        )
    }

    @Test("insertionY clamps out-of-range indices to the list bounds")
    func insertionYClampsOutOfRange() {
        let frames: [Int: CGRect] = [
            0: CGRect(x: 0, y: 10, width: 100, height: 10),
            1: CGRect(x: 0, y: 30, width: 100, height: 10),
        ]
        let ids = [0, 1]

        // Negative index clamps to the index-0 position.
        #expect(
            SidebarInsertionResolver.insertionY(forInsertionIndex: -5, orderedIDs: ids, frames: frames, spacing: 8)
                == SidebarInsertionResolver.insertionY(forInsertionIndex: 0, orderedIDs: ids, frames: frames, spacing: 8)
        )
        // Past-the-end index clamps to the append position.
        #expect(
            SidebarInsertionResolver.insertionY(forInsertionIndex: 99, orderedIDs: ids, frames: frames, spacing: 8)
                == SidebarInsertionResolver.insertionY(forInsertionIndex: 2, orderedIDs: ids, frames: frames, spacing: 8)
        )
    }

    @Test("post-removal target adjusts downward drags")
    func postRemovalTargetAdjustsDownwardDrags() {
        #expect(SidebarInsertionResolver.postRemovalTargetIndex(sourceIndex: 1, preRemovalIndex: 3) == 2)
        #expect(SidebarInsertionResolver.postRemovalTargetIndex(sourceIndex: 3, preRemovalIndex: 1) == 1)
        #expect(SidebarInsertionResolver.postRemovalTargetIndex(sourceIndex: 1, preRemovalIndex: 2) == 1)
    }

    @Test("visible reorder insertion hides no-op adjacent targets")
    func visibleReorderInsertionHidesNoOpAdjacentTargets() {
        let ids = ["a", "b", "c"]

        #expect(
            SidebarInsertionResolver.visibleReorderInsertionIndex(
                candidateIndex: 1,
                sourceID: "a",
                orderedIDs: ids
            ) == nil
        )
        #expect(
            SidebarInsertionResolver.visibleReorderInsertionIndex(
                candidateIndex: 1,
                sourceID: "b",
                orderedIDs: ids
            ) == nil
        )
        #expect(
            SidebarInsertionResolver.visibleReorderInsertionIndex(
                candidateIndex: 3,
                sourceID: "a",
                orderedIDs: ids
            ) == 3
        )
        #expect(
            SidebarInsertionResolver.visibleReorderInsertionIndex(
                candidateIndex: 0,
                sourceID: nil,
                orderedIDs: ids
            ) == 0
        )
    }

    @Test("workspace drop on own row is a no-op")
    func workspaceDropOnOwnRowIsNoOp() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
        ]

        let target = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
            sourceID: "b",
            dropPoint: CGPoint(x: 10, y: 25),
            preRemovalIndex: 2,
            orderedIDs: ["a", "b", "c"],
            frames: frames
        )

        #expect(target == nil)
    }

    @Test("workspace drop after self is a no-op")
    func workspaceDropAfterSelfIsNoOp() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
        ]

        let target = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
            sourceID: "a",
            dropPoint: CGPoint(x: 10, y: 15),
            preRemovalIndex: 1,
            orderedIDs: ["a", "b"],
            frames: frames
        )

        #expect(target == nil)
    }

    /// The inter-group gutter is reclaimed into the tile stack's drop region
    /// (SidebarGroupView's bottom padding bracket), so a drop y inside that
    /// gutter is resolved by the LIST delegate and must land as append. This is
    /// the contract that lets the geometry change need no index math.
    @Test("a drop y in the reclaimed inter-group gutter appends to the group")
    func gutterDropYAppendsToGroup() {
        // Two 30pt tiles with the comfortable 5pt stack spacing between them.
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 260, height: 30),
            "b": CGRect(x: 0, y: 35, width: 260, height: 30),
        ]
        let ids = ["a", "b"]
        let lastTileMaxY: CGFloat = 65
        let comfortableGroupStackSpacing: CGFloat = 14

        // Anywhere in the reclaimed gutter resolves to append (index 2).
        for offset in stride(from: CGFloat(1), through: comfortableGroupStackSpacing, by: 1) {
            #expect(
                SidebarInsertionResolver.insertionIndex(
                    forDropY: lastTileMaxY + offset,
                    orderedIDs: ids,
                    frames: frames
                ) == ids.count
            )
        }

        // The compact gutter is narrower but behaves identically.
        #expect(
            SidebarInsertionResolver.insertionIndex(
                forDropY: lastTileMaxY + 8,
                orderedIDs: ids,
                frames: frames
            ) == ids.count
        )
    }

    @Test("workspace post-removal target handles cross-group and same-group moves")
    func workspacePostRemovalTargetHandlesMoveDirection() {
        let frames: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 10),
            "b": CGRect(x: 0, y: 20, width: 100, height: 10),
            "c": CGRect(x: 0, y: 40, width: 100, height: 10),
            "d": CGRect(x: 0, y: 60, width: 100, height: 10),
        ]
        let ids = ["a", "b", "c", "d"]

        let sameGroupDown = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
            sourceID: "b",
            dropPoint: CGPoint(x: 10, y: 55),
            preRemovalIndex: 3,
            orderedIDs: ids,
            frames: frames
        )
        let sameGroupUp = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
            sourceID: "d",
            dropPoint: CGPoint(x: 10, y: 15),
            preRemovalIndex: 1,
            orderedIDs: ids,
            frames: frames
        )
        let crossGroup = SidebarInsertionResolver.workspacePostRemovalTargetIndex(
            sourceID: "x",
            dropPoint: CGPoint(x: 10, y: 15),
            preRemovalIndex: 1,
            orderedIDs: ids,
            frames: frames
        )

        #expect(sameGroupDown == 2)
        #expect(sameGroupUp == 1)
        #expect(crossGroup == 1)
    }
}
