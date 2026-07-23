import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Bridge socket ledger")
struct BridgeSocketLedgerTests {
    private static let sessionA = TerminalSessionID(rawValue: "abc123-bridge")!
    private static let sessionB = TerminalSessionID(rawValue: "def456-bridge")!
    private static let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test("previousGeneration is zero for an unknown session")
    func previousGenerationDefaultsToZero() async {
        let ledger = BridgeSocketLedger()
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 0)
    }

    @Test("commit advances the generation and returns the entry it replaced")
    func commitAdvancesAndReturnsPrevious() async {
        let ledger = BridgeSocketLedger()

        let firstReplaced = await ledger.commit(
            session: Self.sessionA, generation: 1,
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock", mintedAt: Self.epoch
        )
        #expect(firstReplaced == nil)
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 1)

        let secondReplaced = await ledger.commit(
            session: Self.sessionA, generation: 2,
            remoteSocketPath: "/tmp/awesomux-bridge-bbbb.sock", mintedAt: Self.epoch
        )
        #expect(secondReplaced?.generation == 1)
        #expect(secondReplaced?.remoteSocketPath == "/tmp/awesomux-bridge-aaaa.sock")
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 2)
    }

    @Test("remoteSocketPath returns the exact last-minted path, nil when absent")
    func remoteSocketPathIsExactAndAbsentWhenUnknown() async {
        let ledger = BridgeSocketLedger()
        #expect(await ledger.remoteSocketPath(for: Self.sessionA) == nil)

        await ledger.commit(
            session: Self.sessionA, generation: 1,
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock", mintedAt: Self.epoch
        )
        #expect(await ledger.remoteSocketPath(for: Self.sessionA) == "/tmp/awesomux-bridge-aaaa.sock")
    }

    @Test("forget drops the entry and resets its generation")
    func forgetResetsSession() async {
        let ledger = BridgeSocketLedger()
        await ledger.commit(
            session: Self.sessionA, generation: 3,
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock", mintedAt: Self.epoch
        )
        await ledger.forget(Self.sessionA)
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 0)
        #expect(await ledger.remoteSocketPath(for: Self.sessionA) == nil)
    }

    @Test("compare-and-forget drops only a matching path, leaves a re-minted entry")
    func forgetIfMatchesGuardsSuccessor() async {
        let ledger = BridgeSocketLedger()
        await ledger.commit(
            session: Self.sessionA, generation: 1,
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock", mintedAt: Self.epoch
        )
        // A successor re-mint replaced the entry; a stale teardown holding the
        // old path must not drop the successor's entry.
        await ledger.commit(
            session: Self.sessionA, generation: 2,
            remoteSocketPath: "/tmp/awesomux-bridge-bbbb.sock", mintedAt: Self.epoch
        )
        await ledger.forget(Self.sessionA, ifMatches: "/tmp/awesomux-bridge-aaaa.sock")
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 2)

        // The matching path forgets.
        await ledger.forget(Self.sessionA, ifMatches: "/tmp/awesomux-bridge-bbbb.sock")
        #expect(await ledger.previousGeneration(for: Self.sessionA) == 0)
    }

    @Test("sessions are isolated from each other")
    func sessionsAreIndependent() async {
        let ledger = BridgeSocketLedger()
        await ledger.commit(
            session: Self.sessionA, generation: 5,
            remoteSocketPath: "/tmp/awesomux-bridge-aaaa.sock", mintedAt: Self.epoch
        )
        #expect(await ledger.previousGeneration(for: Self.sessionB) == 0)
        #expect(await ledger.remoteSocketPath(for: Self.sessionB) == nil)
    }
}
