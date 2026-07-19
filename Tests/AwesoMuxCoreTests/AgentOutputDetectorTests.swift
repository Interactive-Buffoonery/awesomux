import Testing
import XCTest
@testable import AwesoMuxCore

final class AgentOutputDetectorTests: XCTestCase {
    private let detector = AgentOutputDetector()

    func testDetectsClaudePermissionPromptAsNeedsAttention() {
        let text = """
            claude code v1.7.2
            user › run the build
            ▌ permission needed
              run xcodebuild -scheme awesoMux build ?
              [y] yes  [n] no  [a] always for this session
            """

        XCTAssertEqual(detector.detectedState(in: text), .needsAttention)
    }

    func testDetectsClaudeThinkingCue() {
        let text = """
            claude code v1.7.2
            claude · thinking ▰▰▰▱▱
              checking that GhosttySurfaceDelegate matches the upstream protocol...
            """

        XCTAssertEqual(detector.detectedState(in: text), .thinking)
    }

    func testInfersClaudeIdentityFromConfidentVisibleCue() {
        let text = """
            claude code v1.7.2
            claude · thinking ▰▰▰▱▱
              reading the tree...
            """

        XCTAssertEqual(
            detector.detectedOutput(in: text),
            AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        )
    }

    func testInfersClaudeIdentityFromPromptGlyphVariants() {
        XCTAssertEqual(
            detector.detectedOutput(in: "claude > esc to interrupt"),
            AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        )
        XCTAssertEqual(
            detector.detectedOutput(in: "claude › ctrl-c to interrupt"),
            AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        )
    }

    func testDoesNotInferIdentityFromBareClaudeLaunchCommand() {
        let text = """
            $ claude
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """

        XCTAssertEqual(
            detector.detectedOutput(in: text),
            AgentOutputDetection(state: .needsAttention)
        )
    }

    func testDetectsCodexLaunchCardAsWaitingIdentityCarrier() {
        let text = """
            ✨ ❯ codex

            >_ OpenAI Codex (v0.142.5)

            model:     gpt-5.5 xhigh    /model to change
            directory: ~/Development

            Tip: [tui.keymap] in ~/.codex/config.toml lets you rebind supported shortcuts
            """

        XCTAssertTrue(detector.observesAgentContext(in: text))
        XCTAssertEqual(
            detector.detectedOutput(in: text),
            AgentOutputDetection(state: .waiting, agentKind: .codex)
        )
    }

    func testDoesNotInferIdentityFromBareCodexLaunchCommand() {
        let text = """
            $ codex
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """

        XCTAssertEqual(
            detector.detectedOutput(in: text),
            AgentOutputDetection(state: .needsAttention)
        )
    }

    func testDetectsPromptAfterAgentContextWasObserved() {
        let text = """
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """

        XCTAssertNil(detector.detectedState(in: text))
        XCTAssertEqual(
            detector.detectedState(in: text, assumingAgentContext: true),
            .needsAttention
        )
    }

    func testDetectsClaudeDoneCue() {
        let text = """
            claude code v1.7.2
              ✓ build succeeded · 4.2s
              ⎿ awaiting your review
            """

        XCTAssertEqual(detector.detectedState(in: text), .done)
    }

    func testIgnoresShellTextWithoutAgentContext() {
        let text = """
            $ rg "permission needed"
            docs/state-machine-contract.jsx: permission needed
            """

        XCTAssertNil(detector.detectedState(in: text))
    }

    func testCommandFinishedMapsAgentExitToDoneOrError() {
        XCTAssertEqual(detector.stateForCommandFinished(exitCode: 0, agentWasActive: true), .done)
        XCTAssertEqual(detector.stateForCommandFinished(exitCode: 1, agentWasActive: true), .error)
    }

    func testCommandFinishedIgnoresMissingExitCode() {
        XCTAssertNil(detector.stateForCommandFinished(exitCode: -1, agentWasActive: true))
    }

    func testCommandFinishedDoesNotPaintDoneForHookCapableKinds() {
        for kind in [AgentKind.claudeCode, .codex, .openCode, .pi, .grok] {
            XCTAssertNil(
                detector.stateForCommandFinished(
                    exitCode: 0,
                    agentWasActive: true,
                    liveAgentKind: kind
                ),
                "expected nil done for \(kind)"
            )
        }
        XCTAssertEqual(
            detector.stateForCommandFinished(
                exitCode: 1,
                agentWasActive: true,
                liveAgentKind: .grok
            ),
            .error
        )
    }
}

@Suite("AgentOutputDetector text normalization")
struct AgentOutputDetectorTextNormalizationTests {
    private let detector = AgentOutputDetector()

    @Test("matching is case- and diacritic-insensitive after the single-pass fold")
    func matchingIsCaseAndDiacriticInsensitiveAfterSinglePassFold() {
        // Guards the single-pass, locale-independent fold: caseInsensitive
        // folding must keep lowercasing (no separate .lowercased() pass) and
        // diacritics must keep stripping.
        let text = """
            CLAUDE CODE v1.7.2
            CLAUDE · THINKING ▰▰▰▱▱
              ÉSC TO INTERRUPT
            """

        #expect(detector.detectedState(in: text) == .thinking)
    }
}

@Suite("AgentOutputDetector command finished")
struct AgentOutputDetectorCommandFinishedTests {
    private let detector = AgentOutputDetector()

    @Test("ignores shell exit status when no agent context was observed")
    func ignoresShellExitStatus() {
        #expect(detector.stateForCommandFinished(exitCode: 0, agentWasActive: false) == nil)
        #expect(detector.stateForCommandFinished(exitCode: 1, agentWasActive: false) == nil)
    }
}

@Suite("AgentOutputDetector Grok identity")
struct AgentOutputDetectorGrokIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("infers Grok identity but ignores generic done cues")
    func infersGrokIdentityButIgnoresGenericDoneCues() {
        let text = """
            ❯ grok
              task complete · 3 files changed
            """

        #expect(
            detector.detectedOutput(in: text)
                == AgentOutputDetection(state: .waiting, agentKind: .grok)
        )
    }

    @Test("infers Grok identity but ignores Claude-only thinking cues")
    func infersGrokIdentityButIgnoresClaudeOnlyThinkingCues() {
        // Leftover Claude scrollback must not flip a Grok pane to thinking.
        #expect(
            detector.detectedOutput(in: "grok › esc to interrupt")
                == AgentOutputDetection(state: .waiting, agentKind: .grok)
        )
    }

    @Test("Grok-specific live activity cues surface as thinking")
    func grokSpecificActivityCuesSurfaceAsThinking() {
        #expect(
            detector.detectedOutput(in: "grok ›\nSubagent running: \"review\" — Thinking (grok-4.5)")
                == AgentOutputDetection(state: .thinking, agentKind: .grok)
        )
        #expect(
            detector.detectedOutput(in: "!: - Thinking - Code Review - grok")
                == AgentOutputDetection(state: .thinking, agentKind: .grok)
        )
    }

    @Test("past-tense Thought for does not keep Grok on thinking")
    func pastTenseThoughtForDoesNotKeepGrokOnThinking() {
        // Remains in scrollback after the turn ends; treating it as live activity
        // stuck the sidebar on thinking forever (review-yj).
        #expect(
            detector.detectedOutput(
                in: "❯ grok\nThought for 1.2s\nhere is the answer\nShift+Tab:mode | Ctrl+c:cancel"
            )
                == AgentOutputDetection(state: .waiting, agentKind: .grok)
        )
    }

    @Test("Grok idle prompt with only the cancel footer stays identity-only")
    func grokIdlePromptDoesNotStickOnThinkingFromFooter() {
        #expect(
            detector.detectedOutput(in: "❯ grok\nShift+Tab:mode | Ctrl+c:cancel")
                == AgentOutputDetection(state: .waiting, agentKind: .grok)
        )
    }

    @Test("Grok permission prompts still surface as attention")
    func grokPermissionPromptsStillSurfaceAsAttention() {
        let text = """
            grok ›
            permission needed
            run swift test?
            [y] yes  [n] no
            """

        #expect(
            detector.detectedOutput(in: text)
                == AgentOutputDetection(state: .needsAttention, agentKind: .grok)
        )
    }

    @Test("does not tag a session from a bare mention of grok in prose")
    func doesNotInferGrokFromProse() {
        // A grep result naming grok is agent context only if prompt-anchored;
        // this line is neither, so nothing is detected.
        #expect(detector.detectedState(in: "we switched the model to grok recently") == nil)
    }

    @Test("a launched grok session with no state cue still carries identity")
    func infersGrokIdentityWithoutStateCue() {
        // The launch case: `grok` is running at its prompt but has printed no
        // thinking/done text yet. Identity must still flow (state `.waiting`,
        // which the reducer treats as no state change) so the icon can appear.
        let detection = detector.detectedOutput(in: "❯ grok")
        #expect(detection?.agentKind == .grok)
        #expect(detection?.state == .waiting)
    }
}

@Suite("AgentOutputDetector Codex identity")
struct AgentOutputDetectorCodexIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("infers Codex from its splash banner at launch, before any state cue")
    func infersCodexFromSplashWithoutStateCue() {
        // Codex's SessionStart hook only lands with the first prompt, so at
        // launch the splash is the only identity signal. Identity must flow with
        // a neutral `.waiting` state so the icon appears without a state change.
        let detection = detector.detectedOutput(in: "OpenAI Codex (v0.142.5)\n  model: gpt-5.5")
        #expect(detection?.agentKind == .codex)
        #expect(detection?.state == .waiting)
    }

    @Test("infers Codex from a prompt-anchored launch")
    func infersCodexFromPromptAnchoredLaunch() {
        #expect(detector.detectedOutput(in: "❯ codex")?.agentKind == .codex)
    }

    @Test("does not tag a session from a bare mention of codex in prose")
    func doesNotInferCodexFromProse() {
        #expect(detector.detectedState(in: "the codex repo lives under vendor/") == nil)
    }

    @Test("text detection does not arbitrate stacked grok/codex signatures by position")
    func textDetectionDoesNotArbitrateStackedSignatures() {
        // When both a grok prompt and a Codex splash sit in the viewport, the
        // text detector cannot know which is live — the scrollback position is
        // not a recency proxy either way. It resolves by fixed precedence
        // (grok before codex here), and that is fine BECAUSE the reducer never
        // lets a text detection reclaim a live non-shell kind. Authority to
        // reclaim a live `.grok` comes only from the foreground-`comm`
        // fast-path (see VisibleTextAgentStateReducer.agentKindCorrection),
        // never from this text. This test pins that the detector stays a pure
        // precedence function and is not (re)ordered to fake recency — the
        // arbitration lives in the reducer's source gate, not here.
        let text = """
            ❯ grok
              grok --resume 019f37ce-277c-73f0
            OpenAI Codex (v0.142.5)
            """
        #expect(detector.detectedOutput(in: text)?.agentKind == .grok)
    }
}

@Suite("AgentOutputDetector OpenCode identity")
struct AgentOutputDetectorOpenCodeIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("infers OpenCode from a prompt-anchored launch")
    func infersOpenCodeFromPromptAnchoredLaunch() {
        #expect(detector.detectedOutput(in: "❯ opencode")?.agentKind == .openCode)
        #expect(detector.detectedOutput(in: "$ opencode")?.agentKind == .openCode)
    }

    @Test("does not tag a session from a bare mention of opencode")
    func doesNotInferOpenCodeFromProse() {
        #expect(detector.detectedState(in: "the opencode config lives under ~/.config") == nil)
    }
}
