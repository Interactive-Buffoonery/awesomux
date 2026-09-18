import AwesoMuxBridgeProtocol
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

@Suite("AgentOutputDetector generic identity")
struct AgentOutputDetectorGenericIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("infers a generic agent from a versioned Muse Code banner")
    func infersMuseFromVersionedBanner() {
        let detection = detector.detectedOutput(in: "Muse Code v1.2.3")
        #expect(detection?.agentKind == .generic)
        #expect(detection?.state == .waiting)
    }

    @Test(
        "infers generic agents from complete prompt command names",
        arguments: ["❯ muse", "✨ ❯ cursor-agent --resume", "$ amp --help"]
    )
    func infersPromptAnchoredGenericAgent(text: String) {
        #expect(detector.detectedOutput(in: text)?.agentKind == .generic)
    }

    @Test(
        "does not infer a generic agent from prose or command-name prefixes",
        arguments: [
            "we use muse code conventions in this repository",
            "$ amplify deploy",
            "❯ rootlesskit --help",
            "$ cursorctl status",
        ]
    )
    func rejectsProseAndCommandPrefixes(text: String) {
        #expect(detector.detectedOutput(in: text) == nil)
    }
}

@Suite("AgentOutputDetector Claude identity")
struct AgentOutputDetectorClaudeIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("does not first-tag from a mid-line mention of claude code")
    func doesNotInferClaudeFromProse() {
        #expect(
            detector.detectedOutput(
                in: "we use claude code for reviews\npermission needed\n[y] yes  [n] no"
            ) == nil
        )
        #expect(
            detector.detectedOutput(
                in: "the log said claude · thinking while Hermes ran"
            ) == nil
        )
        #expect(detector.detectedState(in: "docs/foo.md: claude code v1.7.2") == nil)
    }

    @Test("still tags genuine Claude Code splash and status lines")
    func infersClaudeFromAnchoredSplashAndPrompt() {
        #expect(
            detector.detectedOutput(in: "claude code v1.7.2")?.agentKind == .claudeCode
        )
        #expect(
            detector.detectedOutput(in: "╭─── Claude Code v2.1.214 ───╮\nready")?.agentKind
                == .claudeCode
        )
        #expect(
            detector.detectedOutput(in: "❯ claude")?.agentKind == .claudeCode
        )
        #expect(
            detector.detectedOutput(in: "$ claude --resume")?.agentKind == .claudeCode
        )
    }

    @Test("punctuation, quotes, and digits around claude code do not first-tag")
    func doesNotInferClaudeFromWrappedOrNumberedMentions() {
        for text in [
            "(claude code…)",
            "\"claude code\"",
            "[claude code]",
            "**claude code**",
            "42 claude code",
        ] {
            #expect(detector.detectedOutput(in: text) == nil)
        }
    }

    @Test("mid-sentence prompt quotes do not first-tag Claude")
    func midSentencePromptQuotesDoNotFirstTagClaude() {
        #expect(detector.detectedOutput(in: "docs say run `$ claude` to start") == nil)
        #expect(detector.detectedOutput(in: "try ❯ claude from the shell notes") == nil)
    }
}

@Suite("AgentOutputDetector Hermes identity")
struct AgentOutputDetectorHermesIdentityTests {
    private let detector = AgentOutputDetector()

    @Test("infers Hermes from its heading, config path, and prompt")
    func infersHermesFromSplashCues() {
        #expect(detector.detectedOutput(in: "Hermes\ngpt-5.6-sol")?.agentKind == .hermes)
        #expect(detector.detectedOutput(in: "config: ~/.hermes")?.agentKind == .hermes)
        #expect(detector.detectedOutput(in: "❯ hermes")?.agentKind == .hermes)
        #expect(detector.detectedOutput(in: "$ hermes --resume")?.agentKind == .hermes)
    }

    @Test("Hermes ruminating is live thinking, not a generic done cue")
    func hermesRuminatingIsThinking() {
        #expect(
            detector.detectedOutput(in: "Hermes\nruminating\ngpt-5.6-sol")
                == AgentOutputDetection(state: .thinking, agentKind: .hermes)
        )
    }

    @Test("does not tag a session from a bare mention of hermes in prose")
    func doesNotInferHermesFromProse() {
        #expect(detector.detectedState(in: "the hermes package landed last week") == nil)
        #expect(detector.detectedState(in: "NASA Hermes mission notes") == nil)
    }

    @Test("Hermes identity wins over leftover Claude prose in the same viewport")
    func hermesWinsOverClaudeProse() {
        let text = """
            Hermes
            gpt-5.6-sol
            ~/.hermes
            see also: we used to run claude code on this host
            """
        #expect(detector.detectedOutput(in: text)?.agentKind == .hermes)
    }

    @Test("leftover Claude interrupt cues do not flip a Hermes pane to thinking")
    func leftoverClaudeThinkingDoesNotStickHermes() {
        #expect(
            detector.detectedOutput(in: "Hermes\nesc to interrupt")
                == AgentOutputDetection(state: .waiting, agentKind: .hermes)
        )
        let mixed = """
            claude code v1.7.2
            Hermes
            gpt-5.6-sol
            esc to interrupt
            claude · thinking
            """
        let detection = detector.detectedOutput(in: mixed)
        #expect(detection?.agentKind == .hermes)
        #expect(detection?.state != .thinking)
        #expect(detection?.state == .waiting)
    }

    @Test("a lone ruminating status line does not first-tag Hermes")
    func ruminatingAloneDoesNotFirstTagHermes() {
        #expect(detector.detectedOutput(in: "Ruminating…") == nil)
        #expect(detector.detectedOutput(in: "ruminating") == nil)
    }

    @Test("historical mid-line ruminating does not keep Thinking")
    func midLineRuminatingDoesNotKeepThinking() {
        let text = """
            Hermes
            gpt-5.6-sol
            the previous turn was ruminating for 12s
            """
        #expect(
            detector.detectedOutput(in: text)
                == AgentOutputDetection(state: .waiting, agentKind: .hermes)
        )
    }

    @Test("parenthetical hermes prose does not first-tag")
    func doesNotInferHermesFromParentheticalProse() {
        #expect(detector.detectedOutput(in: "(hermes is a mission)") == nil)
    }

    @Test("mid-sentence prompt quotes do not first-tag Hermes")
    func midSentencePromptQuotesDoNotFirstTagHermes() {
        #expect(detector.detectedOutput(in: "the README quotes `$ hermes` as the launch") == nil)
        #expect(detector.detectedOutput(in: "then ❯ hermes --resume in the guide") == nil)
    }
}

