import AwesoMuxCore
import Dispatch
import Foundation
import Testing
@testable import awesoMux

// All coverage runs against injected closure seams — no live ssh, no real
// socket binds. A spy exec channel records the exact assembled teardown
// commands; a spy shutdown records the listener close; a spy sync-exec records
// (and can slow) the quit sweep so its bound is observable on wall time.
@MainActor
@Suite("Bridge generation registry")
struct BridgeGenerationRegistryTests {
    private static let session = TerminalSessionID(rawValue: "abc123-bridge")!
    static let remote = RemoteTarget(user: "ed", host: "box")!
    static let controlPath = "/tmp/ctl/%C"

    private static func channel(
        session: TerminalSessionID = session,
        gen: Int = 1,
        remoteSuffix: String = "aaaa"
    ) -> BridgeChannel {
        BridgeChannel(
            token: "deadbeef",
            gen: gen,
            localSocketPath: "/tmp/awesomux-local-\(remoteSuffix).sock",
            remoteSocketPath: "/tmp/awesomux-bridge-\(remoteSuffix).sock",
            stateFilePath: "/Users/example/.awesomux/bridge/\(session.rawValue).json",
            session: session
        )
    }

    // MARK: - Genuine-close teardown

    @Test("genuine-close teardown cancels, rm's the exact path, and shuts the listener")
    func genuineCloseTearsDown() async {
        let harness = Harness()
        let channel = Self.channel()
        await harness.commitLedger(session: Self.session, channel: channel)
        harness.registry.register(harness.generation(channel: channel), for: Self.session)

        await harness.registry.teardown(for: Self.session)

        let cmds = harness.execCommands
        #expect(cmds.count == 3)
        // Cancel carries the exact remote:local pair; rm the exact remote
        // socket path; rm the exact state-file path (finding #7 — a clean
        // close must not orphan `<session>.json` on the remote).
        let cancel = cmds.first { $0.contains("-O cancel") }
        let socketRemoval = cmds.first {
            $0.contains("rm -f") && $0.contains(channel.remoteSocketPath)
        }
        let stateRemoval = cmds.first {
            $0.contains("rm -f") && $0.contains(channel.stateFilePath)
        }
        #expect(cancel?.contains(channel.remoteSocketPath + ":" + channel.localSocketPath) == true)
        #expect(socketRemoval != nil)
        #expect(stateRemoval != nil)
        // The state-file delete is guarded on THIS generation's socket
        // basename (adversarial-review finding): the per-session path is
        // shared with a successor re-mint, so an unguarded rm racing a fast
        // close-then-reopen would delete the successor's live file.
        #expect(stateRemoval?.contains("grep -qsF") == true)
        #expect(stateRemoval?.contains((channel.remoteSocketPath as NSString).lastPathComponent) == true)
        #expect(harness.shutdownCount == 1)
        // Ledger entry forgotten so the next attach for this session mints gen 1.
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 0)
    }

    @Test("no teardown command is ever a glob")
    func noGlobInTeardown() async {
        let harness = Harness()
        let channel = Self.channel()
        await harness.commitLedger(session: Self.session, channel: channel)
        harness.registry.register(harness.generation(channel: channel), for: Self.session)

        await harness.registry.teardown(for: Self.session)

        for command in harness.execCommands {
            #expect(!command.contains("*"), "glob found: \(command)")
            #expect(!command.contains("find "), "find-sweep found: \(command)")
        }
    }

    // MARK: - Heal / transfer

    @Test("the heal branch preserves the generation — no commands, still registered")
    func healPreservesGeneration() async {
        let harness = Harness()
        let channel = Self.channel()
        await harness.commitLedger(session: Self.session, channel: channel)
        harness.registry.register(harness.generation(channel: channel), for: Self.session)

        // A heal routes AWAY from teardown (see `shouldTearDown`) — the registry
        // is simply not asked to tear down. Nothing runs; the generation stays.
        #expect(BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: true) == false)
        #expect(harness.execCommands.isEmpty)
        #expect(harness.shutdownCount == 0)
        // The successor's re-mint replaces the entry without breaking it here.
        harness.registry.register(harness.generation(channel: Self.channel(gen: 2, remoteSuffix: "bbbb")), for: Self.session)
        #expect(harness.execCommands.isEmpty)
    }

    @Test("shouldTearDown routes genuine close vs heal")
    func routingDecision() {
        #expect(BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: false) == true)
        #expect(BridgeGenerationRegistry.shouldTearDown(preservesRecoveryRecord: true) == false)
    }

    // MARK: - Idempotency + unknown session

    @Test("a second teardown records nothing (idempotent)")
    func teardownIsIdempotent() async {
        let harness = Harness()
        let channel = Self.channel()
        await harness.commitLedger(session: Self.session, channel: channel)
        harness.registry.register(harness.generation(channel: channel), for: Self.session)

        await harness.registry.teardown(for: Self.session)
        let afterFirst = harness.execCommands.count
        await harness.registry.teardown(for: Self.session)

        #expect(afterFirst == 3)
        #expect(harness.execCommands.count == 3) // second call added nothing
        #expect(harness.shutdownCount == 1)
    }

    @Test("teardown deletes its own captured path, never a successor re-mint's")
    func teardownUsesCapturedPathNotLedgerRead() async {
        // Simulate a re-mint committing a DIFFERENT socket under the same session
        // key after gen A registered: teardown(A) must delete A's captured path,
        // not whatever the ledger now names, and must not forget the successor's
        // entry (path-identity guard). Locks in the TOCTOU fix.
        let harness = Harness()
        let channelA = Self.channel(remoteSuffix: "aaaa")
        await harness.commitLedger(session: Self.session, channel: channelA)
        harness.registry.register(harness.generation(channel: channelA), for: Self.session)

        // Ledger rolls forward to a successor path (as a concurrent reattach would).
        await harness.commitLedger(session: Self.session, channel: Self.channel(gen: 2, remoteSuffix: "bbbb"))

        await harness.registry.teardown(for: Self.session)

        let cmds = harness.execCommands
        // Socket-touching commands carry A's captured path only. (The
        // state-file rm carries neither suffix: the state path is per-SESSION,
        // shared by A and its successor — a re-mint overwrites it in place.)
        #expect(cmds.filter { $0.contains(".sock") }.allSatisfy { $0.contains("aaaa") })
        #expect(cmds.allSatisfy { !$0.contains("bbbb") })          // never the successor's
        // The successor's ledger entry survives — its previousGeneration intact.
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 2)
    }

    @Test("teardown of an unknown session is a silent no-op")
    func unknownSessionNoOp() async {
        let harness = Harness()
        await harness.registry.teardown(for: TerminalSessionID(rawValue: "never-registered")!)
        #expect(harness.execCommands.isEmpty)
        #expect(harness.shutdownCount == 0)
    }

    // MARK: - App-quit sweep

    @Test("the quit sweep runs exact-path cancel + rm for every live generation")
    func quitSweepIsExactPathForEveryGeneration() async {
        let harness = Harness()
        let sessionB = TerminalSessionID(rawValue: "def456-bridge")!
        let channelA = Self.channel(remoteSuffix: "aaaa")
        let channelB = Self.channel(session: sessionB, remoteSuffix: "bbbb")
        harness.registry.register(harness.generation(channel: channelA), for: Self.session)
        harness.registry.register(harness.generation(channel: channelB), for: sessionB)

        harness.registry.drainForTermination(budget: 2)
        await harness.awaitSyncDrained(expected: 6)

        let cmds = harness.syncCommands
        #expect(cmds.count == 6) // cancel + socket rm + state-file rm per generation
        for suffix in ["aaaa", "bbbb"] {
            #expect(cmds.contains { $0.contains("-O cancel") && $0.contains("awesomux-bridge-\(suffix).sock") })
            #expect(cmds.contains { $0.contains("rm -f") && $0.contains("awesomux-bridge-\(suffix).sock") })
        }
        // One exact-path state-file rm per generation (finding #7).
        #expect(cmds.filter { $0.contains("rm -f") && $0.contains(".awesomux/bridge/") }.count == 2)
        for command in cmds {
            #expect(!command.contains("*"), "glob found: \(command)")
            #expect(!command.contains("find "), "find-sweep found: \(command)")
        }
    }

    @Test("the quit sweep respects its bound even when the exec is slow")
    func quitSweepRespectsBound() async {
        // Each command sleeps far past the budget; the sweep must still return
        // in ~budget by abandoning the still-running background work.
        let harness = Harness(slowSyncExecSeconds: 5)
        for i in 0..<3 {
            harness.registry.register(
                harness.generation(channel: Self.channel(session: TerminalSessionID(rawValue: "s\(i)-bridge")!, remoteSuffix: "s\(i)")),
                for: TerminalSessionID(rawValue: "s\(i)-bridge")!
            )
        }

        harness.registry.drainForTermination(budget: 0.3)

        // None of the five-second commands can have completed inside the
        // 0.3-second drain budget; the returned recorder state proves the
        // sweep abandoned the still-running background work.
        #expect(harness.syncCommands.isEmpty)
    }

    @Test("the quit sweep is a no-op with no live generations")
    func quitSweepNoOpWhenEmpty() async {
        let harness = Harness()
        harness.registry.drainForTermination(budget: 2)
        #expect(harness.syncCommands.isEmpty)
    }
}

// MARK: - Test doubles

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [String] = []
    private var _shutdownCount = 0

    var commands: [String] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return _commands.count
    }
    var shutdownCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _shutdownCount
    }

    func record(_ command: String) {
        lock.lock(); defer { lock.unlock() }
        _commands.append(command)
    }
    func recordShutdown() {
        lock.lock(); defer { lock.unlock() }
        _shutdownCount += 1
    }
}

@MainActor
private struct Harness {
    let registry: BridgeGenerationRegistry
    let ledger: BridgeSocketLedger
    private let execRecorder = CommandRecorder()
    private let syncRecorder = CommandRecorder()
    private let shutdownRecorder = CommandRecorder()

    var execCommands: [String] { execRecorder.commands }
    var shutdownCount: Int { shutdownRecorder.shutdownCount }
    var syncCommands: [String] { syncRecorder.commands }

    init(slowSyncExecSeconds: Double = 0) {
        let ledger = BridgeSocketLedger()
        let exec = execRecorder
        let sync = syncRecorder
        self.ledger = ledger
        self.registry = BridgeGenerationRegistry(
            ledger: ledger,
            execChannel: { command in
                exec.record(command)
                return Data()
            },
            syncExec: { command in
                if slowSyncExecSeconds > 0 {
                    Thread.sleep(forTimeInterval: slowSyncExecSeconds)
                }
                sync.record(command)
            }
        )
    }

    func generation(channel: BridgeChannel) -> BridgeGenerationRegistry.Generation {
        let recorder = shutdownRecorder
        return BridgeGenerationRegistry.Generation(
            controlPath: BridgeGenerationRegistryTests.controlPath,
            remote: BridgeGenerationRegistryTests.remote,
            channel: channel,
            shutdown: { recorder.recordShutdown() }
        )
    }

    func commitLedger(session: TerminalSessionID, channel: BridgeChannel) async {
        await ledger.commit(
            session: session,
            generation: channel.gen,
            remoteSocketPath: channel.remoteSocketPath,
            mintedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }

    /// The quit sweep runs its commands off the main thread; poll until the spy
    /// has recorded them (fast-exec cases) so assertions see a settled state.
    func awaitSyncDrained(expected: Int) async {
        for _ in 0..<200 where syncRecorder.count < expected {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
