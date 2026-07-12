import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Corner tab state")
@MainActor
struct CornerTabStateTests {
    @Test("a nil session resolves to ended with the fallback directory")
    func nilSessionEnds() {
        #expect(
            CornerTabState.resolve(session: nil, fallbackCommand: "Shell", fallbackDirectory: "/Users/me")
                == .ended(directory: "/Users/me")
        )
    }

    @Test("a live shell session resolves to active")
    func liveSessionActive() {
        let session = TerminalSession(
            title: "t", workingDirectory: "/tmp",
            agentKind: .shell, agentState: AgentKind.shell.initialSessionState
        )
        if case .active(_, let directory, _) = CornerTabState.resolve(
            session: session, fallbackCommand: "Shell", fallbackDirectory: "/Users/me"
        ) {
            #expect(directory == "/tmp")
        } else {
            Issue.record("expected active state")
        }
    }

    @Test("a session whose active pane's foreground process exited resolves to ended")
    func exitedForegroundProcessEnds() {
        var pane = TerminalPane(
            title: "t", workingDirectory: "/tmp",
            agentKind: .shell, agentState: AgentKind.shell.initialSessionState
        )
        pane.foregroundProcessLiveness = .exited
        let session = TerminalSession(
            title: "t", workingDirectory: "/tmp",
            layout: .pane(pane), activePaneID: pane.id
        )
        #expect(
            CornerTabState.resolve(session: session, fallbackCommand: "Shell", fallbackDirectory: "/Users/me")
                == .ended(directory: "/tmp")
        )
    }
}
