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

    @Test("Grok identity waiting clears sticky thinking while hooks stay silent")
    func grokIdentityWaitingClearsStickyThinking() {
        // Grok Build 0.2.x never fires Stop; text waiting is the only clear
        // path after a viewport thinking cue. Claude/Codex still refuse it.
        #expect(reducer.shouldApplyVisibleTextState(
            detectedState: .waiting,
            liveAgentKind: .grok,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking
        ))
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .waiting,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking
        ))
        // Already waiting — no-op.
        #expect(!reducer.shouldApplyVisibleTextState(
            detectedState: .waiting,
            liveAgentKind: .grok,
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
        for fallbackKind in [AgentKind.pi, .grok, .shell] {
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

    @Test("subagent permission-style transcript line never banners the parent pane")
    func subagentPermissionStyleTranscriptLineNeverBannersParentPane() {
        // End-to-end encoding of the INT-714 repro: a subagent echoes a
        // permission-style prompt into the shared pane while the parent
        // Claude Code turn is mid-flight. The detector legitimately reads it
        // as .needsAttention; the reducer must refuse to apply it because the
        // pane's hook stream owns attention.
        let viewport = """
        claude code v1.7.2
        claude · thinking ▰▰▰▱▱
        ⏺ Task(subagent: verify migration)
          │ apply schema changes and proceed? [y/n]
        """
        let detection = AgentOutputDetector().detectedOutput(in: viewport)
        #expect(detection?.state == .needsAttention)

        let decision = reducer.visibleTextDecision(
            detectedState: detection?.state ?? .needsAttention,
            detectedAgentKind: detection?.agentKind,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking,
            terminalIsActiveForAttention: false
        )
        #expect(!decision.shouldApplyState)
        #expect(decision.unreadNotificationDelta == 0)
    }

    @Test("runtime event window suppresses stale visible-text fallback")
    func runtimeEventWindowSuppressesVisibleTextFallback() {
        let lastRuntimeEventAt: TimeInterval = 10
        let window = VisibleTextAgentStateReducer.runtimeEventSuppressionWindow

        #expect(reducer.shouldSuppressVisibleTextState(
            detectedState: .thinking,
            now: lastRuntimeEventAt + window - 0.001,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: nil,
            liveDisplayState: .running
        ))
        #expect(!reducer.shouldSuppressVisibleTextState(
            detectedState: .thinking,
            now: lastRuntimeEventAt + window,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: nil,
            liveDisplayState: .running
        ))
    }

    @Test("runtime attention event suppresses visible-text needs-attention echo")
    func runtimeAttentionEventSuppressesNeedsAttentionEcho() {
        let lastRuntimeEventAt: TimeInterval = 10
        let withinRuntimeEventWindow =
            lastRuntimeEventAt + VisibleTextAgentStateReducer.runtimeEventSuppressionWindow / 2

        #expect(reducer.shouldSuppressVisibleTextState(
            detectedState: .needsAttention,
            now: withinRuntimeEventWindow,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: lastRuntimeEventAt,
            liveDisplayState: .running
        ))
        #expect(reducer.shouldSuppressVisibleTextState(
            detectedState: .needsAttention,
            now: withinRuntimeEventWindow,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: nil,
            liveDisplayState: .needsAttention
        ))
        #expect(!reducer.shouldSuppressVisibleTextState(
            detectedState: .needsAttention,
            now: withinRuntimeEventWindow,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: nil,
            liveDisplayState: .error
        ))
        #expect(!reducer.shouldSuppressVisibleTextState(
            detectedState: .needsAttention,
            now: withinRuntimeEventWindow,
            lastRuntimeEventAppliedAt: lastRuntimeEventAt,
            lastRuntimeAttentionEventAppliedAt: nil,
            liveDisplayState: .idle
        ))
    }

    @Test("visible text decision carries unread and error announcement intents")
    func visibleTextDecisionCarriesSideEffectIntents() {
        // .shell fixture: scraped .needsAttention no longer applies to
        // hook-reliable kinds (INT-714); side-effect intents are what's under
        // test here.
        let needsAttention = reducer.visibleTextDecision(
            detectedState: .needsAttention,
            detectedAgentKind: nil,
            liveAgentKind: .shell,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking,
            terminalIsActiveForAttention: false
        )
        #expect(needsAttention.shouldApply)
        #expect(!needsAttention.clearsAttention)
        #expect(!needsAttention.clearsUnreadNotifications)
        #expect(needsAttention.unreadNotificationDelta == 1)
        #expect(needsAttention.announcementIntent == .none)

        let error = reducer.visibleTextDecision(
            detectedState: .error,
            detectedAgentKind: nil,
            liveAgentKind: .claudeCode,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking,
            terminalIsActiveForAttention: true
        )
        #expect(error.announcementIntent == .errorEntered)

        let cleared = reducer.visibleTextDecision(
            detectedState: .running,
            detectedAgentKind: nil,
            liveAgentKind: .claudeCode,
            liveExecutionState: .error,
            liveDisplayState: .error,
            terminalIsActiveForAttention: true
        )
        #expect(cleared.announcementIntent == .errorCleared)
        #expect(cleared.shouldClearStaleError)
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
        #expect(background.clearsAttention)
        #expect(!background.clearsUnreadNotifications)
        #expect(background.unreadNotificationDelta == 0)
    }

    @Test("visible text corrects stale Codex identity from confident Claude cues")
    func visibleTextCorrectsStaleCodexIdentityFromConfidentClaudeCues() {
        let staleCodex = reducer.visibleTextDecision(
            detectedState: .thinking,
            detectedAgentKind: .claudeCode,
            liveAgentKind: .codex,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking,
            terminalIsActiveForAttention: true
        )
        #expect(staleCodex.shouldApply)
        #expect(!staleCodex.shouldApplyState)
        #expect(staleCodex.agentKind == .claudeCode)

        let shell = reducer.visibleTextDecision(
            detectedState: .thinking,
            detectedAgentKind: .claudeCode,
            liveAgentKind: .shell,
            liveExecutionState: .idle,
            liveDisplayState: .idle,
            terminalIsActiveForAttention: true
        )
        #expect(shell.shouldApply)
        #expect(shell.shouldApplyState)
        #expect(shell.agentKind == .claudeCode)
    }

    @Test("visible text can promote a shell to Codex identity without applying state")
    func visibleTextCanPromoteShellToCodexIdentityWithoutApplyingState() {
        let shell = reducer.visibleTextDecision(
            detectedState: .waiting,
            detectedAgentKind: .codex,
            liveAgentKind: .shell,
            liveExecutionState: .idle,
            liveDisplayState: .idle,
            terminalIsActiveForAttention: true
        )

        #expect(shell.shouldApply)
        #expect(!shell.shouldApplyState)
        #expect(shell.agentKind == .codex)
    }

    @Test("visible text leaves Codex identity when identity is not confident")
    func visibleTextLeavesCodexIdentityWhenIdentityIsNotConfident() {
        let staleCodex = reducer.visibleTextDecision(
            detectedState: .output,
            detectedAgentKind: nil,
            liveAgentKind: .codex,
            liveExecutionState: .thinking,
            liveDisplayState: .thinking,
            terminalIsActiveForAttention: true
        )
        #expect(staleCodex.shouldApply)
        #expect(staleCodex.shouldApplyState)
        #expect(staleCodex.agentKind == nil)

        #expect(reducer.agentKindCorrection(
            detectedAgentKind: nil,
            liveAgentKind: .codex
        ) == nil)
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: nil,
            liveAgentKind: .claudeCode
        ) == nil)
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .claudeCode,
            liveAgentKind: .openCode
        ) == nil)
    }

    @Test("grok text never overrides a hook-identified Codex session")
    func grokTextDoesNotOverrideCodexIdentity() {
        // Regression: a starting Codex session whose visible text tripped the
        // grok signature was being relabelled `.grok`. Grok may claim a bare
        // shell, but must never override an already-identified agent.
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .grok,
            liveAgentKind: .codex
        ) == nil)
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .grok,
            liveAgentKind: .claudeCode
        ) == nil)
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .grok,
            liveAgentKind: .shell
        ) == .grok)
    }

    @Test("only an authoritative kind reclaims a pane stuck on stale agent identity")
    func authoritativeKindReclaimsStaleAgentIdentity() {
        // Regression: a stale text guess or restored kind could park the pane
        // on the wrong agent before the first hook landed. A live foreground
        // process `comm` sample is authoritative and may correct that; scraped
        // viewport text still must not.
        for reclaiming in [AgentKind.codex, .openCode, .claudeCode, .pi] {
            #expect(reducer.agentKindCorrection(
                detectedAgentKind: reclaiming,
                detectedKindIsAuthoritative: true,
                liveAgentKind: .grok
            ) == reclaiming)
        }
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .grok,
            detectedKindIsAuthoritative: true,
            liveAgentKind: .claudeCode
        ) == .grok)

        // The mirror bug the adversarial pass caught: a TEXT detection (default
        // non-authoritative) must NOT reclaim a live grok. A stale Codex splash
        // banner sitting in a live Grok pane's scrollback stays grok.
        for textKind in [AgentKind.codex, .openCode, .claudeCode, .pi] {
            #expect(reducer.agentKindCorrection(
                detectedAgentKind: textKind,
                liveAgentKind: .grok
            ) == nil)
        }

        // And a live hook-capable kind is NOT reclaimed by a fragile grok text
        // guess (the original stale-Codex regression stays fixed).
        #expect(reducer.agentKindCorrection(
            detectedAgentKind: .grok,
            liveAgentKind: .codex
        ) == nil)
    }

    @Test("entering waiting announces once and only on the transition")
    func enteringWaitingAnnouncesOnceOnTransition() {
        #expect(reducer.announcementIntent(
            priorDisplayState: .running,
            newDisplayState: .waiting
        ) == .waitingEntered)
        #expect(reducer.announcementIntent(
            priorDisplayState: .idle,
            newDisplayState: .waiting
        ) == .waitingEntered)
        // First event ever seen for a pane (no prior state) still announces.
        #expect(reducer.announcementIntent(
            priorDisplayState: nil,
            newDisplayState: .waiting
        ) == .waitingEntered)
        // Consecutive waiting events dedupe to silence.
        #expect(reducer.announcementIntent(
            priorDisplayState: .waiting,
            newDisplayState: .waiting
        ) == .none)
        // Leaving waiting is silent.
        #expect(reducer.announcementIntent(
            priorDisplayState: .waiting,
            newDisplayState: .thinking
        ) == .none)
    }

    @Test("error to waiting announces the combined cleared-and-waiting intent")
    func errorToWaitingAnnouncesCombinedIntent() {
        let combined = reducer.announcementIntent(
            priorDisplayState: .error,
            newDisplayState: .waiting
        )
        #expect(combined == .errorClearedAndWaiting)
        #expect(combined.clearsStaleError)
        // Generic error-cleared behavior is untouched for non-waiting exits.
        #expect(reducer.announcementIntent(
            priorDisplayState: .error,
            newDisplayState: .running
        ) == .errorCleared)
        #expect(reducer.announcementIntent(
            priorDisplayState: .error,
            newDisplayState: .needsAttention
        ) == .none)
        #expect(AgentStateAnnouncementIntent.waitingEntered.clearsStaleError == false)
    }

    @Test("runtime event suppression metadata follows state-bearing events")
    func runtimeEventSuppressionMetadataFollowsStateBearingEvents() {
        #expect(reducer.runtimeEventSuppressionDecision(
            state: nil,
            executionState: nil,
            attentionReason: nil
        ) == .init(shouldRecordStateEvent: false, shouldRecordAttentionEvent: false))

        #expect(reducer.runtimeEventSuppressionDecision(
            state: .thinking,
            executionState: nil,
            attentionReason: nil
        ) == .init(shouldRecordStateEvent: true, shouldRecordAttentionEvent: false))

        #expect(reducer.runtimeEventSuppressionDecision(
            state: nil,
            executionState: nil,
            attentionReason: .permissionPrompt
        ) == .init(shouldRecordStateEvent: true, shouldRecordAttentionEvent: true))
    }
}
