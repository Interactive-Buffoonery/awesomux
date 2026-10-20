import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("VisibleTextAgentStateReducer")
struct VisibleTextAgentStateReducerTests {
    private let reducer = VisibleTextAgentStateReducer()

    @Test("visible-text guard preserves semantic waiting")
    func visibleTextGuardPreservesSemanticWaiting() {
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .waiting,
            liveAgentKind: .shell,
            liveExecutionState: .running,
            liveDisplayState: .running
        ))
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .idle,
            liveAgentKind: .shell,
            liveExecutionState: .waiting,
            liveDisplayState: .waiting
        ))
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .running,
            liveAgentKind: .shell,
            liveExecutionState: .waiting,
            liveDisplayState: .waiting
        ))
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .idle,
            liveAgentKind: .shell,
            liveExecutionState: .waiting,
            liveDisplayState: .needsAttention
        ))
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .running,
            liveAgentKind: .shell,
            liveExecutionState: .waiting,
            liveDisplayState: .needsAttention
        ))

        for state in [AgentState.thinking, .output, .needsAttention, .done, .error] {
            #expect(reducer.shouldApplyVisibleTextState(
                detectedState: state,
                liveAgentKind: .shell,
                liveExecutionState: .waiting,
                liveDisplayState: .waiting
            ))
        }
    }

    @Test("scraped done never overrides a hook agent, still applies to non-hook kinds")
    func scrapedDoneNeverOverridesHookAgent() {
        // A subagent's "task complete" line in the viewport must not flip the
        // still-working parent Claude/Codex to .done. The hook stream owns the
        // real turn-end (.waiting).
        for hookKind in [AgentKind.claudeCode, .codex, .openCode, .pi, .grok] {
            #expect(!reducer.shouldApplyVisibleTextState(
                detectedState: .done,
                liveAgentKind: hookKind,
                liveExecutionState: .thinking,
                liveDisplayState: .thinking
            ))
        }

        #expect(reducer.shouldApplyVisibleTextState(
            detectedState: .done,
            liveAgentKind: .shell,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking
        ))

        // The gate is scoped to .done and .needsAttention — other scraped
        // states still apply to hook agents (e.g. thinking).
        #expect(reducer.shouldApplyVisibleTextState(
            detectedState: .thinking,
            liveAgentKind: .claudeCode,
            liveExecutionState: .waiting,
            liveDisplayState: .waiting
        ))
    }

    @Test("scraped needs-attention never overrides a hook agent, still applies to non-hook kinds")
    func scrapedNeedsAttentionNeverOverridesHookAgent() {
        // INT-714: a subagent's `[y/n] proceed?`-style transcript line in the
        // shared pane must not arm the Acknowledge banner while the parent
        // agent is still driving. Real permission prompts for these providers
        // arrive through their installed attention hooks.
        for hookKind in [AgentKind.claudeCode, .codex, .openCode] {
            #expect(!reducer.shouldApplyVisibleTextState(
                detectedState: .needsAttention,
                liveAgentKind: hookKind,
                liveExecutionState: .thinking,
                liveDisplayState: .thinking
            ))
        }

        // Pi reports lifecycle only; Grok 0.2.x never fires Permission hooks —
        // both keep scraped attention as their fallback.
        for fallbackKind in [AgentKind.pi, .grok, .generic, .shell] {
            #expect(reducer.shouldApplyVisibleTextState(
                detectedState: .needsAttention,
                liveAgentKind: fallbackKind,
                liveExecutionState: .thinking,
                liveDisplayState: .thinking
            ))
        }

        // An exit-nonzero .error still applies to hook agents.
        #expect(reducer.shouldApplyVisibleTextState(
            detectedState: .error,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking
        ))
    }

    @Test("active visible agent activity acknowledges stale unread attention")
    func activeVisibleAgentActivityAcknowledgesStaleUnreadAttention() {
        let active = reducer.visibleTextDecision(
            detectedState: .thinking,
            detectedAgentKind: nil,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .needsAttention,
            terminalIsActiveForAttention: true
        )
        #expect(active.shouldApply)
        #expect(active.clearsAttention)
        #expect(active.clearsUnreadNotifications)
        #expect(active.unreadNotificationDelta == 0)

        let background = reducer.visibleTextDecision(
            detectedState: .thinking,
            detectedAgentKind: nil,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .needsAttention,
            terminalIsActiveForAttention: false
        )
        #expect(background.shouldApply)
        // Live repro for the background half: a workspace lifts into the
        // sidebar's Needs Input section, then a re-scrape ~0.5s later reads a
        // non-attention viewport and drops the row back out before the user can
        // click it — unread stuck at 1, cue gone. Attention must survive while
        // the user is elsewhere, on the same terms as the unread badge.
        #expect(!background.clearsAttention)
        #expect(!background.clearsUnreadNotifications)
        #expect(background.unreadNotificationDelta == 0)
    }

    @Test(arguments: [
        (AgentKind.grok, AgentExecutionState.thinking, AgentState.thinking, true),
        (.hermes, .thinking, .thinking, true),
        (.claudeCode, .thinking, .thinking, false),
        (.grok, .waiting, .waiting, false),
        (.hermes, .waiting, .waiting, false),
    ])
    func identityWaitingClearsStickyThinking(kind: AgentKind, execution: AgentExecutionState, display: AgentState, expected: Bool) {
        #expect(
            reducer.shouldApplyVisibleTextState(
                detectedState: .waiting, liveAgentKind: kind, liveExecutionState: execution, liveDisplayState: display) == expected)
    }

    @Test(
        arguments: [
            (.grok, false, .codex, nil, .thinking, .thinking, false),
            (.grok, false, .claudeCode, nil, .thinking, .thinking, false),
            (.grok, false, .shell, .grok, .thinking, .idle, true),
            (.codex, true, .grok, .codex, .thinking, .thinking, false),
            (.openCode, true, .grok, .openCode, .thinking, .thinking, false),
            (.claudeCode, true, .grok, .claudeCode, .thinking, .thinking, false),
            (.pi, true, .grok, .pi, .thinking, .thinking, false),
            (.hermes, true, .grok, .hermes, .thinking, .thinking, false),
            (.generic, true, .grok, .generic, .thinking, .thinking, false),
            (.grok, true, .claudeCode, .grok, .thinking, .thinking, false),
            (.hermes, true, .claudeCode, .hermes, .thinking, .thinking, false),
            (.codex, false, .grok, nil, .thinking, .thinking, false),
            (.openCode, false, .grok, nil, .thinking, .thinking, false),
            (.claudeCode, false, .grok, nil, .thinking, .thinking, false),
            (.pi, false, .grok, nil, .thinking, .thinking, false),
            (.hermes, false, .grok, nil, .thinking, .thinking, false),
            (.claudeCode, false, .codex, nil, .thinking, .thinking, false),
            (.claudeCode, false, .shell, .claudeCode, .thinking, .idle, true),
            (nil, false, .codex, nil, .output, .thinking, true),
            (nil, false, .claudeCode, nil, .thinking, .thinking, false),
            (.claudeCode, false, .openCode, nil, .thinking, .thinking, false),
        ] as [(AgentKind?, Bool, AgentKind, AgentKind?, AgentState, AgentExecutionState, Bool)])
    func kindCorrection(
        detected: AgentKind?, authoritative: Bool, live: AgentKind, expected: AgentKind?, state: AgentState, execution: AgentExecutionState,
        appliesState: Bool
    ) {
        #expect(
            reducer.agentKindCorrection(detectedAgentKind: detected, detectedKindIsAuthoritative: authoritative, liveAgentKind: live)
                == expected)
        let decision = reducer.visibleTextDecision(
            detectedState: state, detectedAgentKind: detected, detectedKindIsAuthoritative: authoritative,
            liveAgentKind: live, liveExecutionState: execution, liveDisplayState: AgentState(executionState: execution),
            terminalIsActiveForAttention: true
        )
        #expect(decision.agentKind == expected)
        #expect(decision.shouldApplyState == appliesState)
        #expect(decision.shouldApply == (appliesState || expected != nil))
    }
}
