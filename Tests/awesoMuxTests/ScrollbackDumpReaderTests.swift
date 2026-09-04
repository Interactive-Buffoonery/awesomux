import Testing
@testable import awesoMux

@Suite("Bounded scrollback native bridge")
struct ScrollbackDumpReaderTests {
    @Test("reads the exact byte count including embedded NUL and Unicode")
    func preservesBytes() {
        let text = "a\0é"
        let expected = Array(text.utf8)
        let result = ScrollbackDumpReader.read(maximumBytes: expected.count) { buffer, written in
            for (index, byte) in expected.enumerated() { buffer[index] = byte }
            written = expected.count
            return 0
        }
        #expect(result == .loaded(text))
    }

    @Test("native rejection discards partially written text")
    func discardsPartialHistory() {
        let result = ScrollbackDumpReader.read(maximumBytes: 4) { buffer, written in
            buffer[0] = 65
            written = 1
            return 1
        }
        #expect(result == .tooLarge)
    }

    @Test("invalid native lengths fail without reading beyond the buffer", arguments: [-1, 5])
    func rejectsInvalidLengths(length: Int) {
        let result = ScrollbackDumpReader.read(maximumBytes: 4) { _, written in
            written = length
            return 0
        }
        #expect(result == .failed)
    }

    @Test("distinguishes an empty history from failure")
    func emptyAndFailure() {
        #expect(ScrollbackDumpReader.read(maximumBytes: 4) { _, _ in 0 } == .loaded(""))
        #expect(ScrollbackDumpReader.read(maximumBytes: 4) { _, _ in 2 } == .failed)
    }
}
