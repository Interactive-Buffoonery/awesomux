import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

// MARK: - AmxStatusFileWatcher — pure consume() core tests
//
// These tests focus on the pure `AmxStatusFileWatcher.consume(_:pendingTail:expectedToken:)`
// function, which can be exercised without kqueue, timing, or real files.

@Suite("AmxStatusFileWatcher — consume() core")
struct AmxStatusFileWatcherConsumeTests {

    // MARK: - Helpers

    private static let token = "aabbccdd11223344"

    /// Build a JSONL "attached" line for the given token.
    private static func attachedLine(token: String = token) -> String {
        // No trailing newline — caller adds it so split-point tests control placement.
        """
        {"event":"attached","token":"\(token)","created":true,"daemon_pid":42,"daemon_created_at":1700000000,"daemon_incarnation":99,"session":"sess1","ts":1700000001}
        """
    }

    /// Build a JSONL "session-end" line for the given token.
    private static func sessionEndLine(token: String = token) -> String {
        """
        {"event":"session-end","token":"\(token)","reason":"shell-exit","code":0,"session":"sess1","ts":1700000099}
        """
    }

    private static func toData(_ string: String) -> Data {
        Data(string.utf8)
    }

    // MARK: - Tests

    @Test("two complete lines in one buffer yield 2 events and empty tail")
    func twoCompleteLinesYieldTwoEventsAndEmptyTail() {
        let buffer = Self.toData(Self.attachedLine() + "\n" + Self.sessionEndLine() + "\n")

        let result = AmxStatusFileWatcher.consume(buffer, pendingTail: Data(), expectedToken: Self.token)

        #expect(result.events.count == 2)
        #expect(result.remainingTail.isEmpty)

        if case .attached(let created, let daemon) = result.events.first?.kind {
            #expect(created == true)
            #expect(daemon.pid == 42)
        } else {
            Issue.record("first event should be .attached")
        }

        if case .sessionEnd(let reason, let code) = result.events.last?.kind {
            #expect(reason == .shellExit)
            #expect(code == 0)
        } else {
            Issue.record("second event should be .sessionEnd")
        }
    }

    @Test("line split across two consume() calls is assembled correctly")
    func splitLineAcrossTwoConsumeCalls() {
        // First call: one complete attached line + start of the session-end line.
        let firstAttached = Self.attachedLine() + "\n"
        let sessionEndStr = Self.sessionEndLine()
        let splitIndex = sessionEndStr.index(sessionEndStr.startIndex, offsetBy: 20)
        let partial = String(sessionEndStr[sessionEndStr.startIndex..<splitIndex])
        let rest = String(sessionEndStr[splitIndex...]) + "\n"

        let firstChunk = Self.toData(firstAttached + partial)
        let firstResult = AmxStatusFileWatcher.consume(
            firstChunk,
            pendingTail: Data(),
            expectedToken: Self.token
        )

        #expect(firstResult.events.count == 1)
        #expect(!firstResult.remainingTail.isEmpty)
        #expect(String(data: firstResult.remainingTail, encoding: .utf8) == partial)

        if case .attached = firstResult.events.first?.kind { } else {
            Issue.record("first result's single event should be .attached")
        }

        // Second call: feed rest, combining with tail from first.
        let secondChunk = Self.toData(rest)
        let secondResult = AmxStatusFileWatcher.consume(
            secondChunk,
            pendingTail: firstResult.remainingTail,
            expectedToken: Self.token
        )

        #expect(secondResult.events.count == 1)
        #expect(secondResult.remainingTail.isEmpty)

        if case .sessionEnd(let reason, let code) = secondResult.events.first?.kind {
            #expect(reason == .shellExit)
            #expect(code == 0)
        } else {
            Issue.record("second result's event should be .sessionEnd")
        }
    }

    @Test("buffer with no newline yields 0 events and remainingTail == whole buffer")
    func noNewlineYieldsNoEventsAndWholeBufferIsTail() {
        let partial = "no newline here at all"
        let buffer = Self.toData(partial)

        let result = AmxStatusFileWatcher.consume(buffer, pendingTail: Data(), expectedToken: Self.token)

        #expect(result.events.isEmpty)
        #expect(result.remainingTail == buffer)
    }

    @Test("wrong-token line in the complete slice is dropped, tail empty")
    func wrongTokenLineIsDropped() {
        let wrongToken = "ffffffffffffffff"
        let line = Self.attachedLine(token: wrongToken) + "\n"
        let buffer = Self.toData(line)

        let result = AmxStatusFileWatcher.consume(buffer, pendingTail: Data(), expectedToken: Self.token)

        #expect(result.events.isEmpty)
        #expect(result.remainingTail.isEmpty)
    }

    @Test("empty buffer yields 0 events and empty tail")
    func emptyBufferYieldsNoEventsAndEmptyTail() {
        let result = AmxStatusFileWatcher.consume(Data(), pendingTail: Data(), expectedToken: Self.token)

        #expect(result.events.isEmpty)
        #expect(result.remainingTail.isEmpty)
    }

    @Test("partial line in pendingTail completed by newBytes with newline is parsed")
    func tailCompletedByNewBytes() {
        let fullLine = Self.attachedLine()
        // Put first half in tail, second half + newline in newBytes.
        let mid = fullLine.index(fullLine.startIndex, offsetBy: fullLine.count / 2)
        let firstHalf = String(fullLine[fullLine.startIndex..<mid])
        let secondHalf = String(fullLine[mid...]) + "\n"

        let tail = Self.toData(firstHalf)
        let newBytes = Self.toData(secondHalf)

        let result = AmxStatusFileWatcher.consume(newBytes, pendingTail: tail, expectedToken: Self.token)

        #expect(result.events.count == 1)
        #expect(result.remainingTail.isEmpty)

        if case .attached = result.events.first?.kind { } else {
            Issue.record("event should be .attached")
        }
    }

    @Test("tail exceeding maxTailBytes with no newline is dropped (garbage mitigation)")
    func tailExceedingMaxBytesWithoutNewlineIsDropped() {
        // Create a buffer > 8192 bytes with NO newline anywhere.
        // This simulates a daemon emitting garbage/crash data with no line terminator.
        let garbageBytes = Data(repeating: 0x41, count: 9000)  // 'A' * 9000

        let result = AmxStatusFileWatcher.consume(garbageBytes, pendingTail: Data(), expectedToken: Self.token)

        // No complete line can be formed, so no events.
        #expect(result.events.isEmpty)
        // The tail was too large and had no newline, so it should be dropped (empty).
        #expect(result.remainingTail.isEmpty)
    }

    @Test("small partial line without newline is still retained as tail (sub-maxTail case)")
    func smallPartialLineIsRetainedAsTail() {
        let partial = "small partial"  // < 8192 bytes, no newline
        let buffer = Self.toData(partial)

        let result = AmxStatusFileWatcher.consume(buffer, pendingTail: Data(), expectedToken: Self.token)

        // No newline = no complete lines.
        #expect(result.events.isEmpty)
        // But the tail is small, so it should be retained.
        #expect(result.remainingTail == buffer)
    }
}
