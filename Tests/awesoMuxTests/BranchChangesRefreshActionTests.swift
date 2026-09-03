import AwesoMuxCore
import Testing

@testable import awesoMux

@Suite("Branch changes refresh policy")
struct BranchChangesRefreshActionTests {
    private func pane() -> TerminalPane {
        TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
    }

    @Test("an available local target is ready; in flight is busy")
    func readyAndBusy() {
        #expect(
            BranchChangesRefreshPolicy.verdict(target: .available(pane()), inFlight: false)
                == .ready
        )
        #expect(
            BranchChangesRefreshPolicy.verdict(target: .available(pane()), inFlight: true)
                == .busy
        )
    }

    @Test("a closed or remote terminal is unavailable with a caption")
    func unavailable() {
        guard
            case .unavailable(let closed) = BranchChangesRefreshPolicy.verdict(
                target: .unavailable(.terminalUnavailable),
                inFlight: false
            )
        else {
            Issue.record("expected unavailable")
            return
        }
        #expect(closed == "This tab's terminal was closed")
        guard
            case .unavailable(let remote) = BranchChangesRefreshPolicy.verdict(
                target: .unavailable(.requiresLocalTerminal),
                inFlight: false
            )
        else {
            Issue.record("expected unavailable")
            return
        }
        #expect(remote == "Refresh needs a local terminal")
    }

    /// A read-only remote snapshot cannot be a locally generated branch diff, so
    /// it takes the closed-terminal sentence rather than a case of its own.
    @Test("every other unavailable reason takes the closed-terminal caption")
    func remainingReasonsShareOneCaption() {
        for reason: DocumentNudgeUnavailableReason in [
            .readOnlyRemoteSnapshot, .foregroundSSH, .localTerminalUnverified, .noVerifiedAgent,
        ] {
            #expect(
                BranchChangesRefreshPolicy.verdict(target: .unavailable(reason), inFlight: false)
                    == .unavailable("This tab's terminal was closed")
            )
        }
    }
}
