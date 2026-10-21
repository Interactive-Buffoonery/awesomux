import AwesoMuxBridgeProtocol
import AwesoMuxCore
import AwesoMuxTestSupport
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
        remoteSuffix: String = "aaaa",
        token: String = "deadbeef"
    ) -> BridgeChannel {
        BridgeChannel(
            token: token,
            gen: gen,
            localSocketPath: "/tmp/awesomux-local-\(remoteSuffix).sock",
            remoteSocketPath: "/tmp/awesomux-bridge-\(remoteSuffix).sock",
            stateFilePath: "/Users/example/.awesomux/bridge/\(session.rawValue).json",
            session: session
        )
    }

    // MARK: - Genuine-close teardown

    @Test("teardown ifToken no-ops on a successor re-mint, tears down its own token")
    func teardownIfTokenProtectsSuccessor() async throws {
        let registry = BridgeGenerationRegistry(
            ledger: BridgeSocketLedger(),
            execChannel: { _ in Data() },
            syncExec: { _ in }
        )
        let session = Self.session

        let old = try #require(
            BridgeChannel.mint(
                session: session, previousGeneration: 0,
                localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
            ))
        let oldFlag = AsyncFlag()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl", remote: Self.remote, channel: old,
                shutdown: { await oldFlag.signal() }
            ),
            for: session
        )
        let staleToken = try #require(registry.currentToken(for: session))

        // A reconnect re-mints a successor for the same session (replaces entry).
        let new = try #require(
            BridgeChannel.mint(
                session: session, previousGeneration: old.gen,
                localSocketPath: "/tmp/l.sock", remoteHome: "/Users/example"
            ))
        #expect(new.token != old.token)
        let newFlag = AsyncFlag()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: "/tmp/ctl", remote: Self.remote, channel: new,
                shutdown: { await newFlag.signal() }
            ),
            for: session
        )

        // The stale (old-token) teardown must NOT break the successor.
        await registry.teardown(for: session, ifToken: staleToken)
        #expect(!(await newFlag.isSet))

        // The successor's own token still tears it down.
        let liveToken = try #require(registry.currentToken(for: session))
        await registry.teardown(for: session, ifToken: liveToken)
        #expect(await newFlag.isSet)
    }

    @Test("genuine close removes its resources while preserving successor state")
    func genuineCloseTearsDown() async throws {
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

        let directory = try TemporaryDirectory(prefix: "bridge-remove-guard")
        let state = directory.url.appendingPathComponent("state.json")
        let oldSocket = "/tmp/awesomux-bridge-aaaa.sock"
        let successorSocket = "/tmp/awesomux-bridge-bbbb.sock"
        let script = AmxBackend.bridgeStateFileRemoveRemoteScript(
            stateFilePath: state.path, remoteSocketPath: oldSocket
        )
        for socket in [successorSocket, oldSocket] {
            try JSONEncoder().encode(
                BridgeStateFile(
                    proto: "awesomux-bridge-v1", gen: 1, socket: socket, token: "token"
                )
            ).write(to: state)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try process.run()
            try await process.waitUntilExitEventually()
            #expect(process.terminationStatus == (socket == oldSocket ? 0 : 1))
            #expect(FileManager.default.fileExists(atPath: state.path) == (socket == successorSocket))
            if socket == successorSocket {
                #expect(try JSONDecoder().decode(BridgeStateFile.self, from: Data(contentsOf: state)).socket == successorSocket)
            }
        }
    }

    // MARK: - Idempotency + unknown session

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
        #expect(cmds.allSatisfy { !$0.contains("bbbb") })  // never the successor's
        // The successor's ledger entry survives — its previousGeneration intact.
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 2)
    }

    @Test("discarding a stale committed generation preserves its successor")
    func discardCommittedGenerationPreservesSuccessor() async {
        let harness = Harness()
        let stale = Self.channel(remoteSuffix: "aaaa", token: "stale-token")
        let successor = Self.channel(
            gen: 2,
            remoteSuffix: "bbbb",
            token: "successor-token"
        )
        await harness.commitLedger(session: Self.session, channel: successor)
        harness.registry.register(harness.generation(channel: successor), for: Self.session)

        await harness.registry.discardCommitted(
            harness.generation(channel: stale),
            for: Self.session
        )

        #expect(harness.execCommands.filter { $0.contains(".sock") }.allSatisfy { $0.contains("aaaa") })
        #expect(harness.execCommands.allSatisfy { !$0.contains("bbbb") })
        #expect(harness.registry.currentToken(for: Self.session) == successor.token)
        #expect(await harness.ledger.previousGeneration(for: Self.session) == 2)
    }

    @Test("committed discard stays quit-visible while remote cleanup is blocked")
    func committedDiscardStaysTerminationVisibleDuringRemoteCleanup() async {
        let ledger = BridgeSocketLedger()
        let remoteCleanup = RemoteCleanupGate()
        let shutdown = CommandRecorder()
        let terminationCommands = CommandRecorder()
        let channel = Self.channel(remoteSuffix: "stale")
        let registry = BridgeGenerationRegistry(
            ledger: ledger,
            execChannel: { command in
                await remoteCleanup.block(command)
                return Data()
            },
            syncExec: { terminationCommands.record($0) }
        )
        await ledger.commit(
            session: Self.session,
            generation: channel.gen,
            remoteSocketPath: channel.remoteSocketPath,
            mintedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        await registry.discardCommitted(
            BridgeGenerationRegistry.Generation(
                controlPath: Self.controlPath,
                remote: Self.remote,
                channel: channel,
                shutdown: { shutdown.recordShutdown() }
            ),
            for: Self.session
        )

        #expect(shutdown.shutdownCount == 1)
        #expect(await ledger.previousGeneration(for: Self.session) == 0)
        await remoteCleanup.waitForCount(3)
        let commands = await remoteCleanup.commands
        #expect(commands.count == 3)
        #expect(commands.contains { $0.contains("-O cancel") })
        #expect(commands.allSatisfy { !$0.contains("*") })
        #expect(commands.filter { $0.contains(channel.remoteSocketPath) }.count == 2)
        #expect(
            commands.contains {
                $0.contains(channel.stateFilePath)
                    && $0.contains((channel.remoteSocketPath as NSString).lastPathComponent)
            }
        )
        registry.drainForTermination()
        #expect(terminationCommands.count == 3)
        await remoteCleanup.release()
    }

    @Test("extracted live generation stays quit-visible while teardown is blocked")
    func extractedGenerationStaysTerminationVisibleDuringTeardown() async throws {
        let ledger = BridgeSocketLedger()
        let remoteCleanup = RemoteCleanupGate()
        let terminationCommands = CommandRecorder()
        let channel = Self.channel(remoteSuffix: "extracted")
        let registry = BridgeGenerationRegistry(
            ledger: ledger,
            execChannel: { command in
                await remoteCleanup.block(command)
                return Data()
            },
            syncExec: { terminationCommands.record($0) }
        )
        let generation = BridgeGenerationRegistry.Generation(
            controlPath: Self.controlPath,
            remote: Self.remote,
            channel: channel,
            shutdown: {}
        )
        registry.register(generation, for: Self.session)

        let extracted = try #require(registry.takeGeneration(for: Self.session))
        let teardown = Task {
            await registry.tearDownExtracted(extracted, for: Self.session)
        }
        await remoteCleanup.waitForCount(3)

        registry.drainForTermination()
        #expect(terminationCommands.count == 3)
        await remoteCleanup.release()
        await teardown.value
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
        #expect(cmds.count == 6)  // cancel + socket rm + state-file rm per generation
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

    @Test("approved termination waits past the old budget for mutation then cleanup")
    func approvedTerminationWaitsForMutationAndCleanup() async throws {
        let ledger = BridgeSocketLedger()
        let mutationGate = RemoteCleanupGate()
        let cleanup = CommandRecorder()
        let drainCompletion = CommandRecorder()
        let barrier = BridgePreflightTerminationBarrier()
        let channel = Self.channel(remoteSuffix: "termination-barrier")
        let shutdown = CommandRecorder()
        let registry = BridgeGenerationRegistry(
            ledger: ledger,
            execChannel: { command in
                cleanup.record(command)
                return Data()
            },
            syncExec: { _ in }
        )
        registry.stageForTermination(
            BridgeGenerationRegistry.Generation(
                controlPath: Self.controlPath,
                remote: Self.remote,
                channel: channel,
                shutdown: { shutdown.recordShutdown() },
                terminationBarrier: barrier
            )
        )
        await ledger.commit(
            session: Self.session,
            generation: channel.gen,
            remoteSocketPath: channel.remoteSocketPath,
            mintedAt: Date(timeIntervalSince1970: 1_000_000)
        )

        let mutation = Task {
            try? await barrier.performMutation {
                await mutationGate.block("mutation")
                return Data()
            }
        }
        await mutationGate.waitForCount(1)
        let drain = Task {
            await registry.drainForTerminationBeforeExit()
            drainCompletion.record("complete")
        }

        await Task.yield()
        registry.register(
            BridgeGenerationRegistry.Generation(
                controlPath: Self.controlPath,
                remote: Self.remote,
                channel: channel,
                shutdown: { shutdown.recordShutdown() }
            ),
            for: Self.session
        )

        try await Task.sleep(for: .milliseconds(2_100))
        #expect(cleanup.commands.isEmpty)
        #expect(drainCompletion.count == 0)

        await mutationGate.release()
        _ = await mutation.value
        await drain.value
        #expect(cleanup.count == 3)
        #expect(drainCompletion.count == 1)
        #expect(shutdown.shutdownCount == 1)
        #expect(await ledger.previousGeneration(for: Self.session) == 0)
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

private actor RemoteCleanupGate {
    private(set) var commands: [String] = []
    private var releaseWaiters: [SignalResumer] = []
    private var countWaiter: (expected: Int, continuation: SignalResumer)?

    func block(_ command: String) async {
        commands.append(command)
        if let countWaiter, commands.count >= countWaiter.expected {
            self.countWaiter = nil
            countWaiter.continuation.resume()
        }
        await awaitSignal { releaseWaiters.append($0) }
    }

    func waitForCount(_ expected: Int) async {
        guard commands.count < expected else { return }
        await awaitSignal { countWaiter = (expected, $0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
