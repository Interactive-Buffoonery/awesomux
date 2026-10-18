import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxCore
import Foundation

// Only unrelated app composition is stubbed; file custody, watcher, parser,
// line splitting, and client readiness tracking are the production sources.
struct AgentRuntimeEnvironment {
    let sessionID: UUID
    let paneID: UUID
    let eventFileURL: URL
    let enabledFileDropSources: Set<AgentRuntimeSource>
}
enum SessionPersistence {
    static let supportDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "unused-bridge-support")
}
enum LocalDiagnosticEventInput { case runtimeEventFileUnavailable, runtimeEventsDropped, runtimeEventRejected }

@main struct BridgeJourney {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pane = UUID(), client = UUID().uuidString
        let path = directory.appending(path: "\(pane.uuidString).jsonl")
        var tracker = AgentClientStatusTracker()
        var applied = 0, observations = 0
        var failures = 0
        func check(_ label: String, _ value: Bool) {
            print("\(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        func line(_ sequence: UInt64, ready: Bool, at: Double) throws -> Data {
            var payload: [String: Any] = ["v": 1, "source": "codex", "phase": "notification", "clientStatus": ["clientID": client, "sequence": sequence, "completedTurns": 0, "threadEpoch": 1, "pid": 42, "startedAt": 77, "capturedAt": at]]
            if ready { payload["execution"] = "waiting" }
            var data = try JSONSerialization.data(withJSONObject: payload)
            data.append(10)
            return data
        }
        func append(_ data: Data) throws {
            let file = try FileHandle(forWritingTo: path)
            try file.seekToEnd()
            try file.write(contentsOf: data)
            try file.close()
        }
        try line(1, ready: true, at: Date().timeIntervalSince1970).write(to: path)
        let bridge = AgentRuntimeEventBridge(initialIsAppActive: true, runtimeEventsDirectoryURL: directory)
        let apply: (AgentRuntimeEvent) -> Void = { event in
            applied += 1
            if let evidence = event.clientStatus {
                _ = tracker.accept(evidence, inputReady: event.assertsWaitingExecutionState, observedPID: 42, observedStartedAt: 77, foregroundMatchesProvider: true, now: Date().timeIntervalSince1970)
            }
        }
        #if BEFORE_FIX
        _ = bridge.environment(sessionID: UUID(), paneID: pane, enabledFileDropSources: [], applyEvent: apply)
        #else
        _ = bridge.environment(sessionID: UUID(), paneID: pane, enabledFileDropSources: [], observationStarted: { now in
            observations += 1
            tracker.invalidateObservation(now: now)
        }, applyEvent: apply)
        #endif
        check("initial snapshot skips positive readiness", applied == 0 && !tracker.inputReady)
        try append(line(2, ready: true, at: Date().timeIntervalSince1970))
        bridge.drainRuntimeEventsForTesting(paneID: pane)
        check("new live report enables readiness", tracker.isReady(observedPID: 42, observedStartedAt: 77, now: Date().timeIntervalSince1970))
        try append(line(3, ready: false, at: Date().timeIntervalSince1970))
        check("revocation is queued before action drain", tracker.inputReady)
        #if BEFORE_FIX
        // The old action boundary performs no drain before deciding to send.
        #else
        bridge.drainRuntimeEvents(for: pane)
        #endif
        check("action drain applies queued revocation synchronously", !tracker.inputReady)
        bridge.drainRuntimeEventsForTesting(paneID: pane)
        try append(line(4, ready: true, at: Date().timeIntervalSince1970))
        bridge.drainRuntimeEventsForTesting(paneID: pane)
        check("live ready recovers after revocation", tracker.inputReady)
        let previous = tracker.current
        let oldCapturedAt = Date().timeIntervalSince1970
        bridge.retrySourceForTesting(paneID: pane)
        check("watch restart revokes positive readiness", !tracker.inputReady)
        check("watch restart preserves client authority and sequence", tracker.current == previous)
        try append(line(5, ready: true, at: oldCapturedAt))
        bridge.drainRuntimeEventsForTesting(paneID: pane)
        check("pre-restart captured readiness cannot regain trust", !tracker.inputReady)
        try append(line(6, ready: true, at: Date().timeIntervalSince1970))
        bridge.drainRuntimeEventsForTesting(paneID: pane)
        check("fresh post-restart report restores readiness", tracker.inputReady && tracker.current?.sequence == 6)
        #if !BEFORE_FIX
        check("initial watch and retry both invalidate observation", observations == 2)
        #endif
        bridge.stopWatchingAll()
        print("RESULT: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
