import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct PaneAvailabilityTests {
    private let liveTarget = RemoteTarget(user: "ed", host: "box")!

    @Test func freshlyRestoredTerminalAwaitsHydration() {
        // Default decoded/lazy-mount shape: no surface sampled, empty backend.
        let state = PaneAvailability.terminal(
            liveness: .unsampled,
            connectionHealth: .active,
            reconnect: nil,
            backendMetadata: .empty
        )
        #expect(state == .awaitingHydration)
    }

    @Test func liveProcessIsAttached() {
        #expect(
            PaneAvailability.terminal(
                liveness: .liveCommand,
                connectionHealth: .active,
                reconnect: nil,
                backendMetadata: .empty
            ) == .attached
        )
    }

    @Test func exitedSourceIsUnavailableNotAttached() {
        #expect(
            PaneAvailability.terminal(
                liveness: .exited,
                connectionHealth: .active,
                reconnect: nil,
                backendMetadata: .empty
            ) == .unavailable
        )
    }

    @Test func disconnectedBridgeIsUnavailable() {
        let reconnect = RemoteReconnectState.disconnected(.init(target: liveTarget))
        #expect(
            PaneAvailability.terminal(
                liveness: .bridged,
                connectionHealth: .active,
                reconnect: reconnect,
                backendMetadata: .empty
            ) == .unavailable
        )
    }

    @Test func reconnectingIsStale() {
        let reconnect = RemoteReconnectState.reconnecting(.init(target: liveTarget))
        #expect(
            PaneAvailability.terminal(
                liveness: .bridged,
                connectionHealth: .active,
                reconnect: reconnect,
                backendMetadata: .empty
            ) == .stale
        )
    }

    @Test func possiblyStaleConnectionIsStale() {
        #expect(
            PaneAvailability.terminal(
                liveness: .bridged,
                connectionHealth: .possiblyStale,
                reconnect: nil,
                backendMetadata: .empty
            ) == .stale
        )
    }

    // The load-bearing safety property: a remote/degraded/dead pane is NEVER
    // classified as a healthy local attach.
    @Test func degradedNeverClassifiesAsAttached() {
        let degraded: [(ForegroundProcessLiveness, RemoteConnectionHealth, RemoteReconnectState?)] = [
            (.exited, .active, nil),
            (.bridged, .possiblyStale, nil),
            (.bridged, .active, .disconnected(.init(target: liveTarget))),
            (.bridged, .active, .reconnecting(.init(target: liveTarget))),
        ]
        for (liveness, health, reconnect) in degraded {
            let state = PaneAvailability.terminal(
                liveness: liveness,
                connectionHealth: health,
                reconnect: reconnect,
                backendMetadata: .empty
            )
            #expect(state != .attached)
        }
    }

    @Test func documentGroupIsAlwaysAttached() {
        let doc = DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "av-\(UUID().uuidString).md"),
            title: "notes.md"
        )
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        #expect(PaneAvailability.of(.documentGroup(group)) == .attached)
    }

    @Test func everyAvailabilityStateIsReachable() {
        // Guards against a dead case: each declared state must have a producer.
        var seen: Set<PaneAvailability> = []
        seen.insert(PaneAvailability.terminal(liveness: .unsampled, connectionHealth: .active, reconnect: nil, backendMetadata: .empty))
        seen.insert(PaneAvailability.terminal(liveness: .liveCommand, connectionHealth: .active, reconnect: nil, backendMetadata: .empty))
        seen.insert(PaneAvailability.terminal(liveness: .exited, connectionHealth: .active, reconnect: nil, backendMetadata: .empty))
        seen.insert(
            PaneAvailability.terminal(liveness: .bridged, connectionHealth: .possiblyStale, reconnect: nil, backendMetadata: .empty))
        #expect(seen == Set(PaneAvailability.allCases))
    }
}
