import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("AgentOutputDetector")
struct AgentOutputDetectorTests {
    private let detector = AgentOutputDetector()

    @Test(arguments: [
        (
            """
            claude code v1.7.2
            user › run the build
            ▌ permission needed
              run xcodebuild -scheme awesoMux build ?
              [y] yes  [n] no  [a] always for this session
            """, AgentKind.shell, false, AgentOutputDetection(state: .needsAttention, agentKind: .claudeCode)
        ),
        (
            """
            claude code v1.7.2
            claude · thinking ▰▰▰▱▱
              checking that GhosttySurfaceDelegate matches the upstream protocol...
            """, AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        ),
        ("claude > esc to interrupt", AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)),
        ("claude › ctrl-c to interrupt", AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)),
        (
            """
            $ claude
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """, AgentKind.shell, false, AgentOutputDetection(state: .needsAttention, agentKind: nil)
        ),
        (
            """
            ✨ ❯ codex

            >_ OpenAI Codex (v0.142.5)

            model:     gpt-5.5 xhigh    /model to change
            directory: ~/Development

            Tip: [tui.keymap] in ~/.codex/config.toml lets you rebind supported shortcuts
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .codex)
        ),
        (
            """
            $ codex
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """, AgentKind.shell, false, AgentOutputDetection(state: .needsAttention, agentKind: nil)
        ),
        (
            """
            claude code v1.7.2
              ✓ build succeeded · 4.2s
              ⎿ awaiting your review
            """, AgentKind.shell, false, AgentOutputDetection(state: .done, agentKind: .claudeCode)
        ),
        (
            """
            CLAUDE CODE v1.7.2
            CLAUDE · THINKING ▰▰▰▱▱
              ÉSC TO INTERRUPT
            """, AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        ),
        (
            """
            ❯ grok
              task complete · 3 files changed
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .grok)
        ),
        ("grok › esc to interrupt", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .grok)),
        (
            "grok ›\nSubagent running: \"review\" — Thinking (grok-4.5)", AgentKind.shell, false,
            AgentOutputDetection(state: .thinking, agentKind: .grok)
        ),
        ("!: - Thinking - Code Review - grok", AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .grok)),
        (
            "❯ grok\nThought for 1.2s\nhere is the answer\nShift+Tab:mode | Ctrl+c:cancel", AgentKind.shell, false,
            AgentOutputDetection(state: .waiting, agentKind: .grok)
        ),
        ("❯ grok\nShift+Tab:mode | Ctrl+c:cancel", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .grok)),
        (
            """
            grok ›
            permission needed
            run swift test?
            [y] yes  [n] no
            """, AgentKind.shell, false, AgentOutputDetection(state: .needsAttention, agentKind: .grok)
        ),
        ("❯ grok", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .grok)),
        ("OpenAI Codex (v0.142.5)\n  model: gpt-5.5", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .codex)),
        ("❯ codex", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .codex)),
        ("❯ opencode", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .openCode)),
        ("$ opencode", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .openCode)),
        ("Muse Code v1.2.3", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .generic)),
        ("❯ muse", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .generic)),
        ("✨ ❯ cursor-agent --resume", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .generic)),
        ("$ amp --help", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .generic)),
        ("claude code v1.7.2", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)),
        ("╭─── Claude Code v2.1.214 ───╮\nready", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)),
        ("❯ claude", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)),
        ("$ claude --resume", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)),
        (
            """
            claude code v1.7.2
            ❯ grok
            OpenAI Codex (v0.142.5)
            ❯ opencode
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)
        ),
        ("Hermes\ngpt-5.6-sol", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        ("❯ hermes", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        ("$ hermes --resume", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        ("Hermes Agent v0.21.3", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        ("Hermes\nruminating\ngpt-5.6-sol", AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .hermes)),
        (
            """
            Hermes
            gpt-5.6-sol
            ~/.hermes
            see also: we used to run claude code on this host
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)
        ),
        (
            """
            Hermes
            gpt-5.6-sol
            the previous turn was ruminating for 12s
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)
        ),
        (
            """
            ▌ permission needed
              run swift test ?
              [y] yes  [n] no
            """, AgentKind.shell, true, AgentOutputDetection(state: .needsAttention, agentKind: nil)
        ),
        ("config: ~/.hermes\nRuminating…", AgentKind.hermes, false, AgentOutputDetection(state: .thinking, agentKind: .hermes)),
        ("config: ~/.hermes", AgentKind.hermes, true, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        ("approve pending request", AgentKind.hermes, false, AgentOutputDetection(state: .needsAttention, agentKind: nil)),
        ("Hermes\nesc to interrupt", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)),
        (
            """
            claude code v1.7.2
            Hermes
            gpt-5.6-sol
            esc to interrupt
            claude · thinking
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)
        ),
        ("claude code v1.7.2\nesc to interrupt", AgentKind.hermes, false, AgentOutputDetection(state: .waiting, agentKind: .claudeCode)),
        (
            """
            claude code v1.7.2
            claude · thinking
            cat /.hermes/config
            """, AgentKind.claudeCode, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        ),
        (
            "claude code v1.7.2\nesc to interrupt\n~/.hermes/logs/session.json", AgentKind.claudeCode, false,
            AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        ),
        ("❯ grok\nconfig: ~/.hermes", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .grok)),
        ("OpenAI Codex (v0.142.5)\nconfig: ~/.hermes", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .codex)),
        ("❯ opencode\nconfig: ~/.hermes", AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .openCode)),
        (
            "cat ~/.hermes/logs/session.json\nesc to interrupt", AgentKind.claudeCode, true,
            AgentOutputDetection(state: .thinking, agentKind: nil)
        ),
        (
            """
            cat /.hermes/config
            claude code v1.7.2
            esc to interrupt
            claude · thinking
            """, AgentKind.shell, false, AgentOutputDetection(state: .thinking, agentKind: .claudeCode)
        ),
        (
            """
            config: ~/.hermes
            claude code v1.7.2
            awaiting your review
            task complete
            """, AgentKind.shell, false, AgentOutputDetection(state: .done, agentKind: .claudeCode)
        ),
        (
            """
            claude code v1.7.2
            Hermes
            gpt-5.6-sol
            awaiting your review
            task complete
            """, AgentKind.shell, false, AgentOutputDetection(state: .waiting, agentKind: .hermes)
        ),
        (
            "claude code v1.7.2\nawaiting your review", AgentKind.hermes, false,
            AgentOutputDetection(state: .waiting, agentKind: .claudeCode)
        ),
    ])
    func detects(text: String, liveKind: AgentKind, assumingContext: Bool, expected: AgentOutputDetection) {
        #expect(
            detector.detectedOutput(
                in: text,
                assumingAgentContext: assumingContext,
                liveAgentKind: liveKind
            ) == expected)
        if expected.agentKind == .codex {
            #expect(detector.observesAgentContext(in: text))
        }
    }

    @Test("quoted Codex menus yield to later live UI")
    func quotedCodexMenusYieldToLaterLiveUI() {
        let example = """
            Would you like to run the following command?
            $ swift test
            › 1. Yes, proceed (y)
              2. Yes, and don't ask again for this command (p)
              3. No, and tell Codex what to do differently (esc)
            """
        let selectedPersistentApproval = example.replacingOccurrences(of: "› 1.", with: "  1.")
            .replacingOccurrences(of: "  2.", with: "› 2.")
        #expect(detector.detectedOutput(in: selectedPersistentApproval, liveAgentKind: .codex)?.state == .needsAttention)
        #expect(detector.detectedOutput(in: example + "\n› Summarize changes", liveAgentKind: .codex)?.state == .waiting)
        #expect(detector.detectedOutput(in: example + "\n› ", liveAgentKind: .codex)?.state == .waiting)
        #expect(detector.detectedOutput(in: example + "\n• Working (3s • esc to interrupt)", liveAgentKind: .codex)?.state == .thinking)
        let prose = """
            Would you like to run the following command?
            Yes, proceed
            No, and tell Codex what to do differently
            """
        #expect(detector.detectedOutput(in: prose, liveAgentKind: .codex)?.state != .needsAttention)
    }

    @Test("live codex pane reads its viewport after the launch banner scrolls away")
    func liveCodexPaneReadsViewportWithoutBanner() {
        // A Codex pane on a shared app-server gets no hooks, so its approval
        // prompt, working line, and idle composer are the only status signals.
        let approval = """
              Would you like to run the following command?

              $ swift test

            › 1. Yes, proceed (y)
              2. Yes, and don't ask again for this command (p)
              3. No, and tell Codex what to do differently (esc)
            """
        #expect(
            detector.detectedOutput(in: approval, liveAgentKind: .codex)
                == AgentOutputDetection(state: .needsAttention, agentKind: nil))
        #expect(
            detector.detectedOutput(in: "• Working (12s • esc to interrupt)", liveAgentKind: .codex)
                == AgentOutputDetection(state: .thinking, agentKind: nil))
        #expect(
            detector.detectedOutput(in: "› Summarize recent commits\n\n  100% context left", liveAgentKind: .codex)
                == AgentOutputDetection(state: .waiting, agentKind: .codex))
        #expect(detector.detectedOutput(in: "› Summarize recent commits", liveAgentKind: .shell) == nil)

        // Quoted prompt text and completion prose in the transcript are not
        // live approval or turn-end UI; that pane may have no hook to correct it.
        let quotedApproval = """
            • Codex asks "Would you like to run the following command?" before it runs tools.

            • Working (3s • esc to interrupt)
            """
        #expect(
            detector.detectedOutput(in: quotedApproval, liveAgentKind: .codex)
                == AgentOutputDetection(state: .thinking, agentKind: nil))
        #expect(
            detector.detectedOutput(in: "• Task complete: tests pass.\n\n› ", liveAgentKind: .codex)
                == AgentOutputDetection(state: .waiting, agentKind: .codex))
    }

    @Test(arguments: [
        """
        $ rg "permission needed"
        docs/state-machine-contract.jsx: permission needed
        """,
        "we switched the model to grok recently",
        "the codex repo lives under vendor/",
        "the opencode config lives under ~/.config",
        "we use muse code conventions in this repository",
        "$ amplify deploy",
        "❯ rootlesskit --help",
        "$ cursorctl status",
        "we use claude code for reviews\npermission needed\n[y] yes  [n] no",
        "the log said claude · thinking while Hermes ran",
        "docs/foo.md: claude code v1.7.2",
        "(claude code…)",
        "\"claude code\"",
        "[claude code]",
        "**claude code**",
        "42 claude code",
        "docs say run `$ claude` to start",
        "try ❯ claude from the shell notes",
        "user@remote:~/.hermes ❯ ssh",
        "~/.hermes ❯ micro .env",
        "❯ cd ~/.hermes",
        "config: ~/.hermes",
        "cat /.hermes/config",
        "Hermes is a messaging protocol",
        "the hermes package landed last week",
        "NASA Hermes mission notes",
        "Ruminating…",
        "ruminating",
        "(hermes is a mission)",
        "the README quotes `$ hermes` as the launch",
        "then ❯ hermes --resume in the guide",
        """
        ▌ permission needed
          run swift test ?
          [y] yes  [n] no
        """,
        "approve pending request",
    ])
    func detectsNothing(text: String) {
        #expect(detector.detectedOutput(in: text) == nil)
        #expect(!detector.observesAgentContext(in: text))
    }

    @Test(
        arguments: [
            (Int16(0), true, AgentKind.shell, AgentState.done),
            (1, true, .shell, .error),
            (-1, true, .shell, nil),
            (0, false, .shell, nil),
            (1, false, .shell, nil),
            (0, true, .claudeCode, nil),
            (0, true, .codex, nil),
            (0, true, .openCode, nil),
            (0, true, .pi, nil),
            (0, true, .grok, nil),
            (1, true, .grok, .error),
        ] as [(Int16, Bool, AgentKind, AgentState?)])
    func stateForCommandFinished(exitCode: Int16, active: Bool, kind: AgentKind, expected: AgentState?) {
        #expect(
            detector.stateForCommandFinished(
                exitCode: exitCode, agentWasActive: active, liveAgentKind: kind
            ) == expected)
    }
}
