import Foundation
import Testing
@testable import AwesoMuxCore

/// INT-524: `TerminalPaneLayout` recurses over attacker-/corruption-controlled
/// nesting during decode. A crafted snapshot with tens of thousands of nested
/// splits stack-overflows inside `JSONDecoder.decode` before the use-time
/// `SessionRestoreReducer.maxRestoredLayoutDepth` guard ever runs. The bound in
/// `TerminalSplit.init(from:)` rejects such input as a catchable
/// `DecodingError` at every decode call site.
///
/// Fixtures are built as raw JSON *text* (not by encoding a deep Swift value):
/// constructing/encoding a near-cap recursive value would itself recurse and
/// could crash in fixture setup rather than exercising the guard. The text
/// shape matches the synthesized enum Codable format (`{"split":{"_0":{…}}}`,
/// `{"pane":{"_0":{…}}}`), verified by round-tripping the legal-depth case.
///
/// Decoding runs on a dedicated 8 MB-stack `Thread` to model the production
/// restore path (main thread), not the shallow-stack Swift-concurrency pool
/// threads Swift Testing schedules work on — the guard's cap (96 levels) is
/// safe on a normal stack but the near-cap recursion needed to *reach* the
/// guard would overflow a pool thread's smaller stack.
@Suite struct TerminalPaneLayoutDecodeDepthTests {
    private enum NestBranch { case first, second }

    private func leafJSON() -> String {
        "{\"pane\":{\"_0\":{\"id\":\"\(UUID().uuidString)\",\"title\":\"z\",\"workingDirectory\":\"/tmp\"}}}"
    }

    /// A linear chain of `splitCount` splits ending in a terminal leaf, nested
    /// down the given branch. At decode the innermost split sees `splitCount-1`
    /// ancestor `first`/`second` keys on its coding path, so the guard
    /// (`splitDepth < maxDecodedSplitDepth`) admits `splitCount <=
    /// maxDecodedSplitDepth` and throws on `splitCount == maxDecodedSplitDepth + 1`.
    private func nestedLayoutJSON(splitCount: Int, branch: NestBranch) -> String {
        var json = leafJSON()
        for _ in 0..<splitCount {
            let sibling = leafJSON()
            let (first, second) = branch == .first ? (json, sibling) : (sibling, json)
            json = "{\"split\":{\"_0\":{\"orientation\":\"vertical\",\"first\":\(first),\"second\":\(second)}}}"
        }
        return json
    }

    /// Handoff across the worker thread. `@unchecked Sendable` is sound here:
    /// the `DispatchSemaphore` establishes a happens-before edge, so the write
    /// on the worker is fully visible before the caller reads after `wait()`.
    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    /// Runs `body` on a thread with a production-sized stack, so a thrown
    /// `DecodingError` (the guard firing) surfaces to the test rather than the
    /// near-cap recursion aborting the whole process on a shallow pool thread.
    private func runOnLargeStack(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 8 * 1024 * 1024
        thread.start()
        done.wait()
    }

    private func decodeLayout(_ json: String) -> Result<TerminalPaneLayout, Error> {
        let data = Data(json.utf8)
        let box = ResultBox<TerminalPaneLayout>()
        runOnLargeStack { box.result = Result { try JSONDecoder().decode(TerminalPaneLayout.self, from: data) } }
        return box.result!
    }

    private func decodeSnapshot(_ json: String) -> Result<SessionSnapshot, Error> {
        let data = Data(json.utf8)
        let box = ResultBox<SessionSnapshot>()
        runOnLargeStack { box.result = Result { try JSONDecoder().decode(SessionSnapshot.self, from: data) } }
        return box.result!
    }

    /// Wraps a layout JSON in the session-state shape (the original failure
    /// vector): `SessionSnapshot` → `SessionGroup` → `TerminalSession` → layout.
    private func snapshotJSON(wrapping layoutJSON: String) -> String {
        """
        {"groups":[{"id":"\(UUID().uuidString)","name":"g","sessions":[\
        {"id":"\(UUID().uuidString)","title":"s","workingDirectory":"/tmp","layout":\(layoutJSON)}]}]}
        """
    }

    // MARK: - Legal depth (also pins the fixture shape against the real format)

    @Test func legalDepthRoundTrips() throws {
        let layout = try decodeLayout(nestedLayoutJSON(splitCount: 8, branch: .first)).get()
        // 8 splits + 8 sibling leaves + 1 deepest leaf = 9 terminal panes.
        #expect(layout.paneCount == 9)
        // Re-encode/decode to confirm the hand-written text matches the type's
        // own round-trip (calibrates the assumed synthesized-enum shape).
        let reencoded = try JSONEncoder().encode(layout)
        let redecoded = try decodeLayout(String(data: reencoded, encoding: .utf8)!).get()
        #expect(redecoded == layout)
    }

    // MARK: - Boundary (bare TerminalPaneLayout)

    @Test func atCapDecodesCleanly() throws {
        let layout = try decodeLayout(
            nestedLayoutJSON(splitCount: TerminalSplit.maxDecodedSplitDepth, branch: .first)
        ).get()
        #expect(layout.paneCount == TerminalSplit.maxDecodedSplitDepth + 1)
    }

    @Test func overCapThrowsFirstBranch() {
        let result = decodeLayout(
            nestedLayoutJSON(splitCount: TerminalSplit.maxDecodedSplitDepth + 1, branch: .first)
        )
        #expect(throws: DecodingError.self) { try result.get() }
    }

    @Test func overCapThrowsSecondBranch() {
        // Nesting down `second` must trip the same guard — the key-count logic
        // is not one-sided.
        let result = decodeLayout(
            nestedLayoutJSON(splitCount: TerminalSplit.maxDecodedSplitDepth + 1, branch: .second)
        )
        #expect(throws: DecodingError.self) { try result.get() }
    }

    // MARK: - Boundary (session-state-shaped path — the original vector)

    /// Outer wrapper keys (`groups`/`sessions`/`layout` + array indices) are not
    /// `first`/`second`, so the boundary must land at the same split count as
    /// the bare case regardless of nesting context.
    @Test func sessionShapedAtCapDecodes() throws {
        let snapshot = try decodeSnapshot(
            snapshotJSON(wrapping: nestedLayoutJSON(
                splitCount: TerminalSplit.maxDecodedSplitDepth, branch: .first
            ))
        ).get()
        #expect(snapshot.groups.first?.sessions.first != nil)
    }

    @Test func sessionShapedOverCapThrows() {
        let result = decodeSnapshot(
            snapshotJSON(wrapping: nestedLayoutJSON(
                splitCount: TerminalSplit.maxDecodedSplitDepth + 1, branch: .first
            ))
        )
        #expect(throws: DecodingError.self) { try result.get() }
    }
}
