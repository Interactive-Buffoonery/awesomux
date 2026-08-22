import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct AgentRuntimeEventLineSplitterTests {
    @Test
    func singleCompleteLineSplits() {
        let chunk = Data("hello\n".utf8)
        let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk,
            trailingFragment: Data()
        )

        #expect(lines.count == 1)
        #expect(lines.first == Data("hello".utf8))
        #expect(remainder.isEmpty)
    }

    @Test
    func partialTrailingLineBecomesRemainder() {
        let chunk = Data("first\nsecond".utf8)
        let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk,
            trailingFragment: Data()
        )

        #expect(lines == [Data("first".utf8)])
        #expect(remainder == Data("second".utf8))
    }

    @Test
    func fragmentCarriesAcrossCalls() {
        let chunk1 = Data(#"{"v":1,"sou"#.utf8)
        let (lines1, remainder1) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk1,
            trailingFragment: Data()
        )
        #expect(lines1.isEmpty)
        #expect(remainder1 == chunk1)

        let chunk2 = Data((#"rce":"codex"}"# + "\n").utf8)
        let (lines2, remainder2) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk2,
            trailingFragment: remainder1
        )
        #expect(lines2.count == 1)
        #expect(lines2.first == Data(#"{"v":1,"source":"codex"}"#.utf8))
        #expect(remainder2.isEmpty)
    }

    @Test
    func midUTF8CodepointStraddleSurvives() {
        // U+1F600 (😀) = 0xF0 0x9F 0x98 0x80
        let emojiBytes: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        var lineBytes = Data("{\"v\":1,\"source\":\"codex\",\"eventID\":\"".utf8)
        lineBytes.append(contentsOf: emojiBytes)
        lineBytes.append(contentsOf: Data("\"}\n".utf8))

        // Split the chunk in the middle of the multi-byte sequence.
        let cut = lineBytes.count - 5  // after 0xF0 0x9F, before 0x98
        let chunkA = lineBytes.prefix(cut)
        let chunkB = lineBytes.suffix(from: cut)

        let (lines1, remainder1) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunkA,
            trailingFragment: Data()
        )
        #expect(lines1.isEmpty)

        let (lines2, _) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunkB,
            trailingFragment: remainder1
        )
        #expect(lines2.count == 1)

        guard let line = lines2.first else { return }
        let event = AgentRuntimeEvent.parse(data: line)
        #expect(event != nil)
        #expect(event?.eventID == "😀")
    }

    @Test
    func multipleLinesInOneChunk() {
        let chunk = Data("a\nb\nc\n".utf8)
        let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk,
            trailingFragment: Data()
        )

        #expect(lines == [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        #expect(remainder.isEmpty)
    }

    @Test
    func consecutiveNewlinesProduceEmptyLines() {
        let chunk = Data("a\n\nb\n".utf8)
        let (lines, _) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: chunk,
            trailingFragment: Data()
        )

        #expect(lines == [Data("a".utf8), Data(), Data("b".utf8)])
    }

    /// Feeds one burst through several reads whose cuts never land on a
    /// newline, so every boundary call carries a partial fragment with a
    /// non-zero `Data` slice index into the next. Guards the slice-based
    /// splitting: a re-based or newline-leaking slice shows up as a lost
    /// first byte or a spurious empty line in the reassembled feed.
    @Test
    func multiBurstFeedWithStraddlingFragmentsReassemblesExactly() {
        let payloads = [
            #"{"v":1,"seq":1,"note":"first"}"#,
            #"{"v":1,"seq":2,"note":"second"}"#,
            #"{"v":1,"seq":3,"note":"third"}"#,
            #"{"v":1,"seq":4,"note":"fourth"}"#,
        ]
        let bytes = Array(payloads.map { $0 + "\n" }.joined().utf8)
        // Cuts deliberately mid-line and never twice at the same offset.
        let cuts = [5, 21, 40, 63, 90, 111]
        var offset = 0
        var trailing = Data()
        var delivered: [Data] = []

        for cut in cuts {
            let chunk = Data(bytes[offset..<cut])
            offset = cut
            let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
                from: chunk,
                trailingFragment: trailing
            )
            delivered.append(contentsOf: lines)
            trailing = remainder
        }

        let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: Data(bytes[offset...]),
            trailingFragment: trailing
        )
        delivered.append(contentsOf: lines)

        #expect(delivered == payloads.map { Data($0.utf8) })
        #expect(remainder.isEmpty)
    }

    /// A burst that ends on an empty line must not let that line leak into
    /// the next call: the remainder is empty, and a fragment-carrying call
    /// with an empty chunk re-emits only the carried fragment.
    @Test
    func emptyChunkWithCarriedFragmentEmitsOnlyTheFragmentLine() {
        let (_, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: Data("complete\n".utf8),
            trailingFragment: Data()
        )
        #expect(remainder.isEmpty)

        let partial = Data("partial-li".utf8)
        let (_, carried) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: Data(),
            trailingFragment: partial
        )
        #expect(carried == partial)

        let (lines, finalRemainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
            from: Data("ne\n".utf8),
            trailingFragment: carried
        )
        #expect(lines == [Data("partial-line".utf8)])
        #expect(finalRemainder.isEmpty)
    }
}
