import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct AgentRuntimeEventLineSplitterTests {
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

    /// Feeds one burst through several reads whose cuts never land on a
    /// newline, so every boundary call carries a partial fragment with a
    /// non-zero `Data` slice index into the next. Guards the slice-based
    /// splitting: a re-based or newline-leaking slice shows up as a lost
    /// first byte or a spurious empty line in the reassembled feed.
    @Test(arguments: [false, true])
    func multiBurstFeedWithStraddlingFragmentsReassemblesExactly(emptyReads: Bool) {
        let payloads = [
            #"{"v":1,"seq":1,"note":"first"}"#,
            #"{"v":1,"seq":2,"note":"second"}"#,
            "",
            #"{"v":1,"seq":3,"note":"third"}"#,
            #"{"v":1,"seq":4,"note":"fourth"}"#,
        ]
        let bytes = Array(payloads.map { $0 + "\n" }.joined().utf8)
        // Cuts deliberately mid-line and never twice at the same offset.
        let cuts = [5, 21, 40, 65, 90, 111]
        var offset = 0
        var trailing = Data()
        var delivered: [Data] = []

        for cut in cuts {
            if emptyReads {
                let (lines, remainder) = AgentRuntimeEventLineSplitter.extractCompleteLines(
                    from: Data(), trailingFragment: trailing
                )
                #expect(lines.isEmpty)
                #expect(remainder == trailing)
                trailing = remainder
            }
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
}
