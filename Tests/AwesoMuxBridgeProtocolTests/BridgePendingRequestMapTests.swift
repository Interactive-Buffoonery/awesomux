import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct BridgePendingRequestMapTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let cap = BridgeTunables.pendingRequestCap

    private static func admit(
        _ map: inout BridgePendingRequestMap,
        id: String,
        target: String = "rm -rf ./build",
        tool: String = "Bash",
        expiresAt: Date = epoch.addingTimeInterval(120)
    ) -> BridgePendingRequestMap.AdmitOutcome {
        map.admit(id: id, target: target, tool: tool, expiresAt: expiresAt)
    }

    // MARK: - Admission + cap

    @Test
    func concurrentEntriesAdmitUpToCap() {
        var map = BridgePendingRequestMap()
        for index in 0..<Self.cap {
            let outcome = Self.admit(&map, id: "req-\(index)")
            guard case .admitted(let entry) = outcome else {
                Issue.record("expected admission for req-\(index)")
                continue
            }
            #expect(entry.id == "req-\(index)")
        }
        #expect(map.count == Self.cap)
    }

    @Test
    func admissionBeyondCapOverflowsAndLeavesPendingUntouched() {
        var map = BridgePendingRequestMap()
        for index in 0..<Self.cap {
            _ = Self.admit(&map, id: "req-\(index)")
        }

        let overflowOutcome = Self.admit(&map, id: "req-\(Self.cap)")
        #expect(overflowOutcome == .overflow)
        #expect(map.count == Self.cap)

        // The pending entries are untouched: each still resolves normally.
        for index in 0..<Self.cap {
            let outcome = map.resolve(id: "req-\(index)", event: .cancelled, now: Self.epoch)
            guard case .resolved(let entry, .cancelled) = outcome else {
                Issue.record("expected req-\(index) to still be pending and resolvable")
                continue
            }
            #expect(entry.id == "req-\(index)")
        }
        // And the rejected extra request was genuinely never stored.
        #expect(map.resolve(id: "req-\(Self.cap)", event: .cancelled, now: Self.epoch) == .unknown)
    }

    @Test
    func duplicateIDIsRejectedAndExistingEntryUntouched() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "req", target: "original target")

        let duplicate = Self.admit(&map, id: "req", target: "swapped target")
        #expect(duplicate == .duplicate)
        #expect(map.count == 1)

        // The original entry survives with its original submitted target —
        // the ground truth the confused-deputy check (B2) compares against.
        #expect(map.peek(id: "req")?.target == "original target")
    }

    @Test
    func duplicateIDAtCapReportsDuplicateNotOverflow() {
        var map = BridgePendingRequestMap()
        for index in 0..<Self.cap {
            _ = Self.admit(&map, id: "req-\(index)")
        }
        #expect(Self.admit(&map, id: "req-0") == .duplicate)
    }

    @Test
    func nonFiniteDeadlineIsRejected() {
        var map = BridgePendingRequestMap()
        let nan = Self.admit(&map, id: "a", expiresAt: Date(timeIntervalSince1970: .nan))
        let infinite = Self.admit(&map, id: "b", expiresAt: Date(timeIntervalSince1970: .infinity))

        #expect(nan == .invalidDeadline)
        #expect(infinite == .invalidDeadline)
        #expect(map.count == 0)
    }

    @Test
    func admittedEntryRoundTripsAllFields() {
        var map = BridgePendingRequestMap()
        let expiresAt = Self.epoch.addingTimeInterval(60)
        _ = map.admit(id: "req", target: "git push", tool: "Shell", expiresAt: expiresAt)

        let outcome = map.resolve(id: "req", event: .decisionApplied, now: Self.epoch)
        guard case .resolved(let entry, .decisionApplied) = outcome else {
            Issue.record("expected the admitted entry back")
            return
        }
        #expect(entry == BridgePendingRequestMap.Entry(id: "req", target: "git push", tool: "Shell", expiresAt: expiresAt))
    }

    // MARK: - Peek

    @Test
    func peekReturnsEntryWithoutConsumingIt() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "req", target: "the target")

        #expect(map.peek(id: "req")?.target == "the target")
        // Still pending: peek must not consume — a failed target check in
        // B2 relies on the entry surviving.
        #expect(map.count == 1)
        #expect(map.peek(id: "ghost") == nil)
    }

    // MARK: - First-terminal-event-wins atomicity

    @Test
    func decisionThenExpiryLeavesLateEventUnknown() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "req")

        let first = map.resolve(id: "req", event: .decisionApplied, now: Self.epoch)
        guard case .resolved(_, .decisionApplied) = first else {
            Issue.record("expected first call to apply the decision")
            return
        }

        let second = map.resolve(id: "req", event: .expired, now: Self.epoch.addingTimeInterval(200))
        #expect(second == .unknown)
        #expect(map.count == 0)
    }

    @Test
    func expiryThenDecisionLeavesLateEventUnknown() {
        var map = BridgePendingRequestMap()
        let expiresAt = Self.epoch.addingTimeInterval(120)
        _ = Self.admit(&map, id: "req", expiresAt: expiresAt)

        let first = map.resolve(id: "req", event: .expired, now: expiresAt)
        guard case .resolved(_, .expired) = first else {
            Issue.record("expected first call to resolve as expired")
            return
        }

        let second = map.resolve(id: "req", event: .decisionApplied, now: Self.epoch)
        #expect(second == .unknown)
    }

    @Test
    func cancelThenDecisionLeavesLateEventUnknown() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "req")

        let first = map.resolve(id: "req", event: .cancelled, now: Self.epoch)
        guard case .resolved(_, .cancelled) = first else {
            Issue.record("expected first call to apply the cancellation")
            return
        }

        let second = map.resolve(id: "req", event: .decisionApplied, now: Self.epoch)
        #expect(second == .unknown)
    }

    @Test
    func connectionLostThenDecisionLeavesLateEventUnknown() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "req")

        let first = map.resolve(id: "req", event: .connectionLost, now: Self.epoch)
        guard case .resolved(_, .connectionLost) = first else {
            Issue.record("expected first call to apply connection-lost")
            return
        }

        let second = map.resolve(id: "req", event: .decisionApplied, now: Self.epoch)
        #expect(second == .unknown)
    }

    @Test
    func lateEventForClearedIDMutatesNothing() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "a")
        _ = Self.admit(&map, id: "b")
        _ = map.resolve(id: "a", event: .decisionApplied, now: Self.epoch)

        #expect(map.count == 1)
        #expect(map.resolve(id: "a", event: .cancelled, now: Self.epoch) == .unknown)
        // "b" is untouched by the late event targeting the already-cleared "a".
        #expect(map.count == 1)
        let stillB = map.resolve(id: "b", event: .decisionApplied, now: Self.epoch)
        guard case .resolved(let entry, .decisionApplied) = stillB else {
            Issue.record("expected b to still be pending")
            return
        }
        #expect(entry.id == "b")
    }

    @Test
    func unknownIDNeverAdmittedResolvesUnknown() {
        var map = BridgePendingRequestMap()
        #expect(map.resolve(id: "ghost", event: .decisionApplied, now: Self.epoch) == .unknown)
    }

    @Test
    func lateDecisionAfterSweepResolvesUnknown() {
        var map = BridgePendingRequestMap()
        let expiresAt = Self.epoch.addingTimeInterval(60)
        _ = Self.admit(&map, id: "req", expiresAt: expiresAt)

        let swept = map.sweepExpired(now: expiresAt)
        #expect(swept.map(\.id) == ["req"])

        // The decision that raced the sweep arrives a beat later.
        #expect(map.resolve(id: "req", event: .decisionApplied, now: expiresAt.addingTimeInterval(1)) == .unknown)
    }

    @Test
    func lateDecisionAfterDrainResolvesUnknown() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "a")
        _ = Self.admit(&map, id: "b")
        _ = map.drainAll()

        // The reattach race: a decision for a drained id was in flight on
        // the old connection when the app drained on connection-loss.
        #expect(map.resolve(id: "a", event: .decisionApplied, now: Self.epoch) == .unknown)
        #expect(map.resolve(id: "b", event: .decisionApplied, now: Self.epoch) == .unknown)
    }

    // MARK: - Deadline supremacy (resolve forces .expired once now >= expiresAt)

    @Test(arguments: [
        BridgePendingRequestMap.TerminalEvent.decisionApplied,
        .cancelled,
        .connectionLost,
    ])
    func eventArrivingAfterDeadlineResolvesAsExpired(event: BridgePendingRequestMap.TerminalEvent) {
        var map = BridgePendingRequestMap()
        let expiresAt = Self.epoch.addingTimeInterval(120)
        _ = Self.admit(&map, id: "req", expiresAt: expiresAt)

        // The caller's claimed event technically arrives, but the clock is
        // already past the deadline — the deadline wins, not the label.
        let outcome = map.resolve(id: "req", event: event, now: expiresAt.addingTimeInterval(1))
        guard case .resolved(_, .expired) = outcome else {
            Issue.record("expected the passed deadline to force .expired over \(event)")
            return
        }
    }

    // MARK: - Expiry sweep

    @Test
    func sweepExpiredBoundaryIsInclusive() {
        var map = BridgePendingRequestMap()
        let expiresAt = Self.epoch.addingTimeInterval(60)
        _ = Self.admit(&map, id: "due", expiresAt: expiresAt)
        _ = Self.admit(&map, id: "notYet", expiresAt: expiresAt.addingTimeInterval(1))

        // now == expiresAt exactly: documented as expired (inclusive boundary).
        let swept = map.sweepExpired(now: expiresAt)

        #expect(swept.map(\.id) == ["due"])
        #expect(map.count == 1)
        #expect(map.resolve(id: "notYet", event: .cancelled, now: Self.epoch) != .unknown)
    }

    @Test
    func sweepExpiredRemovesOnlyOverdueEntriesOldestFirst() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "later", expiresAt: Self.epoch.addingTimeInterval(20))
        _ = Self.admit(&map, id: "sooner", expiresAt: Self.epoch.addingTimeInterval(10))
        _ = Self.admit(&map, id: "alive", expiresAt: Self.epoch.addingTimeInterval(1000))

        let swept = map.sweepExpired(now: Self.epoch.addingTimeInterval(500))

        // Deterministic order: oldest deadline first, not dictionary order.
        #expect(swept.map(\.id) == ["sooner", "later"])
        #expect(map.count == 1)
    }

    @Test
    func sweepExpiredIsExactlyOncePerEntry() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "a", expiresAt: Self.epoch.addingTimeInterval(-1))

        let firstSweep = map.sweepExpired(now: Self.epoch)
        let secondSweep = map.sweepExpired(now: Self.epoch)

        #expect(firstSweep.map(\.id) == ["a"])
        #expect(secondSweep.isEmpty)
    }

    // MARK: - Drain-all (connection-lost)

    @Test
    func drainAllReturnsEveryPendingEntryExactlyOnce() {
        var map = BridgePendingRequestMap()
        _ = Self.admit(&map, id: "a")
        _ = Self.admit(&map, id: "b")
        _ = Self.admit(&map, id: "c")

        let drained = map.drainAll()

        #expect(Set(drained.map(\.id)) == ["a", "b", "c"])
        #expect(map.count == 0)

        // Calling again returns nothing — nothing left to drain.
        #expect(map.drainAll().isEmpty)
    }
}
