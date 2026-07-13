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

        #expect(content.title == "SSH connection failed")
        // Moved to a different host → the second reconciling line appears (#11).
        #expect(
            content.description
                == "Could not connect to prod.example, or the connection ended.\nThis workspace now targets staging.example.\nCheck that staging.example is a valid hostname or SSH config alias and is reachable.\nFor more details, try ssh deploy@staging.example in a local workspace."
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

        #expect(content.title == "SSH connection failed")
        #expect(content.buttonLabel == "Restart pane")
        #expect(content.buttonEnabled)
    }

    @Test("disconnected with no live target (moved to a local group): Restart pane")
    func disconnectedWithNoLiveTarget() {
        let content = RemotePaneDisconnectedContent.make(
            state: .disconnected(.init(target: capturedTarget)),
            liveTarget: nil
        )

        #expect(content.title == "SSH connection failed")
        #expect(
            content.description
                == "Could not connect to prod.example, or the connection ended.\nCheck that prod.example is a valid hostname or SSH config alias and is reachable.\nFor more details, try ssh deploy@prod.example in a local workspace."
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
                == "Could not connect to prod.example, or the connection ended.\nCheck that prod.example is a valid hostname or SSH config alias and is reachable.\nFor more details, try ssh deploy@prod.example in a local workspace."
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
                == "Could not connect to prod.example, or the connection ended.\nThis workspace now targets staging.example.\nCheck that staging.example is a valid hostname or SSH config alias and is reachable.\nFor more details, try ssh deploy@staging.example in a local workspace."
        )
        #expect(content.buttonLabel == "Reconnect to staging.example")
    }
}
