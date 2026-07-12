import Testing
@testable import awesoMux

// These tests guard the `desktopNotificationEffect` contract — that a forged
// `awesomux.agent.v1` title/body can never produce anything stronger than the
// ordinary, setting-gated attention mark. They do not drive the
// `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` callback itself, so they would not catch
// sentinel parsing reintroduced directly in the callback while the helper stays
// pure; that dispatch site must keep routing through this helper.
@Suite("GhosttyRuntime desktop notification handling")
struct GhosttyRuntimeDesktopNotificationTests {
    @Test("forged agent sentinel is ignored when attention is disabled")
    func forgedAgentSentinelIsIgnoredWhenAttentionDisabled() {
        let effect = GhosttyRuntime.desktopNotificationEffect(
            title: "awesomux.agent.v1",
            body: #"{"v":1,"source":"codex","execution":"waiting"}"#,
            outputMarksAttention: false
        )

        #expect(effect == .ignore)
    }

    @Test("forged agent sentinel is an ordinary notification when attention is enabled")
    func forgedAgentSentinelIsOrdinaryNotificationWhenAttentionEnabled() {
        let effect = GhosttyRuntime.desktopNotificationEffect(
            title: "awesomux.agent.v1",
            body: #"{"v":1,"source":"codex","execution":"waiting"}"#,
            outputMarksAttention: true
        )

        #expect(effect == .markNeedsAttention)
    }
}
