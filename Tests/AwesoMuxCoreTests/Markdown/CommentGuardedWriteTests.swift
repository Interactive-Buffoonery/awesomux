import Testing
@testable import AwesoMuxCore

@Suite("CommentGuardedWrite")
struct CommentGuardedWriteTests {

    @Test("applyIfCurrent calls operation when source matches")
    func matchingSource() {
        let src = "hello"
        let result = CommentMarkerWriter.applyIfCurrent(
            renderTimeSource: src,
            onDisk: src,
            operation: { s in s + " world" }
        )
        #expect(result == "hello world")
    }

    @Test("applyIfCurrent returns nil when onDisk differs from renderTimeSource")
    func staleSource() {
        let result = CommentMarkerWriter.applyIfCurrent(
            renderTimeSource: "old source",
            onDisk: "agent edited this",
            operation: { s in s + " mutated" }
        )
        #expect(result == nil)
    }

    @Test("applyIfCurrent passes onDisk to operation")
    func passesOnDisk() {
        let src = "identical"
        var received: String? = nil
        _ = CommentMarkerWriter.applyIfCurrent(
            renderTimeSource: src,
            onDisk: src,
            operation: { s in received = s; return s }
        )
        #expect(received == src)
    }

    @Test("applyIfCurrent returning nil from operation propagates nil")
    func operationReturnsNil() {
        let src = "hello"
        let result = CommentMarkerWriter.applyIfCurrent(
            renderTimeSource: src,
            onDisk: src,
            operation: { _ in nil }
        )
        #expect(result == nil)
    }

    @Test("insertingComment via applyIfCurrent produces correctly wrapped source")
    func insertViaApply() {
        let src = "fix the loader now"
        let result = CommentMarkerWriter.applyIfCurrent(
            renderTimeSource: src,
            onDisk: src,
            operation: { s in
                let (newSrc, _) = CommentMarkerWriter.insertingComment(
                    in: s, span: 8..<14, note: "make async"
                )
                return newSrc
            }
        )
        #expect(result == "fix the <mark>loader</mark><!-- USER COMMENT 1: make async --> now")
    }
}
