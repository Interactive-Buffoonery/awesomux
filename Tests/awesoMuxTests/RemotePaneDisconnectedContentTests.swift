import AwesoMuxCore
import Testing
@testable import awesoMux

/// Truth-table coverage for the pure three-way overlay content helper behind
/// `RemotePaneDisconnectedView` (INT-697 §2/§6). No view hierarchy needed —
/// this is exactly the label/enabled logic that would otherwise only be
/// exercisable via GUI smoke.
@Suite("Remote pane disconnected overlay content")
struct RemotePaneDisconnectedContentTests {
    private let capturedTarget = RemoteTarget(user: "deploy", host: "prod.example")!
    private let movedTarget = RemoteTarget(user: "deploy", host: "staging.example")!

    @Test("disconnected with a live target: enabled button naming the LIVE host")
    func disconnectedWithLiveTarget() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: movedTarget
        )

        #expect(content.title == "Disconnected")
        // Moved to a different host → the second reconciling line appears (#11).
        #expect(
            content.description
                == "Lost connection to prod.example.\nThis workspace now targets staging.example.\nFor more details, try the same destination with ordinary ssh in a local workspace."
        )
        #expect(content.buttonLabel == "Reconnect to staging.example")
        #expect(content.buttonEnabled)
    }

    @Test("disabled background sessions explain the requirement and offer recovery")
    func disabledBackgroundSessions() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: capturedTarget,
            backgroundSessionsEnabled: false
        )

        #expect(content.title == "Background sessions are off")
        #expect(content.description == "Managed SSH requires background terminal sessions.")
        #expect(content.buttonLabel == "Enable and reconnect to prod.example")
        #expect(content.buttonEnabled)
    }

    @Test("disabled background sessions do not replace reconnecting state")
    func disabledBackgroundSessionsWhileReconnecting() {
        let content = RemotePaneDisconnectedContent.make(
            state: .reconnecting(.init(target: capturedTarget)),
            liveTarget: capturedTarget,
            backgroundSessionsEnabled: false
        )

        #expect(content.title == "Reconnecting…")
        #expect(content.buttonLabel == "Reconnecting…")
        #expect(!content.buttonEnabled)
    }

    @Test("disabled background sessions with no live target still restart locally")
    func disabledBackgroundSessionsWithNoLiveTarget() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: nil,
            backgroundSessionsEnabled: false
        )

        #expect(content.title == "Disconnected")
        #expect(content.buttonLabel == "Restart pane")
        #expect(content.buttonEnabled)
    }

    @Test("disconnected with no live target (moved to a local group): Restart pane")
    func disconnectedWithNoLiveTarget() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: nil
        )

        #expect(content.title == "Disconnected")
        #expect(
            content.description
                == "Lost connection to prod.example.\nFor more details, try the same destination with ordinary ssh in a local workspace."
        )
        #expect(content.buttonLabel == "Restart pane")
        #expect(content.buttonEnabled)
    }

    @Test("reconnecting: disabled button and Reconnecting title regardless of live target")
    func reconnectingIsDisabled() {
        let withLive = RemotePaneDisconnectedContent.make(
            state: .reconnecting(.init(target: capturedTarget)),
            liveTarget: movedTarget
        )
        let withoutLive = RemotePaneDisconnectedContent.make(
            state: .reconnecting(.init(target: capturedTarget)),
            liveTarget: nil
        )

        for content in [withLive, withoutLive] {
            #expect(content.title == "Reconnecting…")
            #expect(content.buttonLabel == "Reconnecting…")
            #expect(!content.buttonEnabled)
        }
    }

    @Test("disconnected with a live target matching the captured host still uses the live label")
    func disconnectedWithUnchangedLiveTarget() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: capturedTarget
        )

        #expect(content.buttonLabel == "Reconnect to prod.example")
        #expect(content.buttonEnabled)
        // Same host both places → no contradictory second description line.
        #expect(
            content.description
                == "Lost connection to prod.example.\nFor more details, try the same destination with ordinary ssh in a local workspace."
        )
    }

    @Test("disconnected with a DIFFERENT live host appends the moved-target line")
    func disconnectedWithMovedLiveTargetNamesBoth() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: movedTarget
        )

        // The two hostnames are reconciled: description names the dropped host,
        // a second line names where the workspace now points (INT-697 fix #11).
        #expect(
            content.description
                == "Lost connection to prod.example.\nThis workspace now targets staging.example.\nFor more details, try the same destination with ordinary ssh in a local workspace."
        )
        #expect(content.buttonLabel == "Reconnect to staging.example")
    }
}
