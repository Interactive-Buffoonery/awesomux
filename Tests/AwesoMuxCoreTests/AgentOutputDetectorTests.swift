import AwesoMuxBridgeProtocol
import Testing
@testable import AwesoMuxCore

@Suite("AgentOutputDetector")
struct AgentOutputDetectorTests {
    private let detector = AgentOutputDetector()

    @Test("attention identity ignores progress but distinguishes the requested command")
    func attentionCueIgnoresUnrelatedProgress() {
        let prompt = "claude code v1.7.2\npermission needed\nrun swift test?\n[y] yes [n] no"
        let first = detector.attentionCue(in: prompt + "\nDownloading 1%", liveAgentKind: .shell)
        #expect(first != nil)
        #expect(first == detector.attentionCue(in: prompt + "\nDownloading 99%", liveAgentKind: .shell))
        #expect(first == detector.attentionCue(in: prompt + "\nrun package upgrade step 99", liveAgentKind: .shell))
        let leadingProgress = prompt.replacingOccurrences(of: "permission needed", with: "run package upgrade step 1\npermission needed")
        #expect(
            detector.attentionCue(in: leadingProgress, liveAgentKind: .shell)
                == detector.attentionCue(in: leadingProgress.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        #expect(
            first != detector.attentionCue(in: prompt.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        let priorPrompt = "permission needed\nrun previous task?\n[y] yes [n] no\nrun package upgrade step 1\n" + prompt
        #expect(
            detector.attentionCue(in: priorPrompt, liveAgentKind: .shell)
                == detector.attentionCue(in: priorPrompt.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        let inlinePrompt = "Muse Code v1.2.3\nrun package upgrade step 1\nProceed with swift test? [y/n]"
        #expect(
            detector.attentionCue(in: inlinePrompt, liveAgentKind: .shell)
                == detector.attentionCue(in: inlinePrompt.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        #expect(
            detector.attentionCue(in: inlinePrompt, liveAgentKind: .shell)
                != detector.attentionCue(
                    in: inlinePrompt.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        let inlineSeparateChoices = inlinePrompt.replacingOccurrences(of: "[y/n]", with: "[y] yes [n] no")
        #expect(
            detector.attentionCue(in: inlineSeparateChoices, liveAgentKind: .shell)
                == detector.attentionCue(
                    in: inlineSeparateChoices.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        let choiceLessPrompt = "Hermes\npermission needed\n\nCommand: swift test\n--configuration debug\n\nDownloading 1%"
        let choiceLessCue = detector.attentionCue(in: choiceLessPrompt, liveAgentKind: .hermes)
        #expect(choiceLessCue != nil)
        #expect(
            choiceLessCue == detector.attentionCue(in: choiceLessPrompt.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes)
        )
        #expect(
            choiceLessCue
                != detector.attentionCue(
                    in: choiceLessPrompt.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        #expect(
            choiceLessCue
                != detector.attentionCue(in: choiceLessPrompt.replacingOccurrences(of: "debug", with: "release"), liveAgentKind: .hermes))
        let mixedChoices = "Muse Code v1.2.3\nrun package upgrade step 1\nProceed with swift test? [y] yes\n[n] no"
        #expect(
            detector.attentionCue(in: mixedChoices, liveAgentKind: .shell)
                == detector.attentionCue(in: mixedChoices.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        #expect(
            detector.attentionCue(in: mixedChoices, liveAgentKind: .shell)
                != detector.attentionCue(
                    in: mixedChoices.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        let oldBlock = "Hermes\npermission needed\nCommand: previous task\n[y] yes [n] no\n"
        let newestInline = "Proceed with swift test? [y/n]"
        #expect(
            detector.attentionCue(in: oldBlock + newestInline, liveAgentKind: .hermes)
                == detector.attentionCue(in: "Hermes\n" + newestInline, liveAgentKind: .hermes))
        let adjacentCommand = "Muse Code v1.2.3\nrun package upgrade step 1\nCommand: swift test\nProceed? [y/n]"
        #expect(
            detector.attentionCue(in: adjacentCommand, liveAgentKind: .shell)
                == detector.attentionCue(in: adjacentCommand.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        #expect(
            detector.attentionCue(in: adjacentCommand, liveAgentKind: .shell)
                != detector.attentionCue(
                    in: adjacentCommand.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        let caseSensitive = prompt.replacingOccurrences(of: "swift test", with: "printf 'A'")
        #expect(
            detector.attentionCue(in: caseSensitive, liveAgentKind: .shell)
                != detector.attentionCue(in: caseSensitive.replacingOccurrences(of: "'A'", with: "'a'"), liveAgentKind: .shell))
        let accents = prompt.replacingOccurrences(of: "swift test", with: "printf 'café'")
        #expect(
            detector.attentionCue(in: accents, liveAgentKind: .shell)
                != detector.attentionCue(in: accents.replacingOccurrences(of: "café", with: "cafe"), liveAgentKind: .shell))
        let oldChoiceLessHeading =
            "Hermes\npermission needed\nCommand: previous task\n\nDownloading 1%\n\nProceed with swift test? [y] yes\n[n] no"
        #expect(
            detector.attentionCue(in: oldChoiceLessHeading, liveAgentKind: .hermes)
                == detector.attentionCue(in: oldChoiceLessHeading.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        #expect(
            detector.attentionCue(in: oldChoiceLessHeading, liveAgentKind: .hermes)
                != detector.attentionCue(
                    in: oldChoiceLessHeading.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        let multilineQuestion = "Muse Code v1.2.3\nrun swift test\n--configuration debug\n[y] yes [n] no"
        #expect(
            detector.attentionCue(in: multilineQuestion, liveAgentKind: .shell)
                != detector.attentionCue(
                    in: multilineQuestion.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        for argument in ["--filter Parser?", "Parser?"] {
            let argumentQuestionMark = "Hermes\nrun swift test\n" + argument + "\n[y] yes [n] no"
            #expect(
                detector.attentionCue(in: argumentQuestionMark, liveAgentKind: .hermes)
                    != detector.attentionCue(
                        in: argumentQuestionMark.replacingOccurrences(of: "run swift test", with: "run swift test --parallel"),
                        liveAgentKind: .hermes))
        }
        for choices in ["", "\n[y] yes [n] no"] {
            let quotedPermission = "Hermes\npermission needed\nCommand: swift test\n--message \"permission required\"" + choices
            let cue = detector.attentionCue(in: quotedPermission, liveAgentKind: .hermes)
            #expect(cue != nil)
            #expect(
                cue
                    != detector.attentionCue(
                        in: quotedPermission.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        }
        let negativeFirst = "Hermes\nrun package upgrade step 1\nProceed with swift test? [n] no\n[y] yes"
        let negativeCue = detector.attentionCue(in: negativeFirst, liveAgentKind: .hermes)
        #expect(negativeCue != nil)
        #expect(
            negativeCue
                == detector.attentionCue(
                    in: negativeFirst.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .hermes))
        #expect(
            negativeCue
                != detector.attentionCue(
                    in: negativeFirst.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        let introductoryHeading = "Hermes\nThis tool needs permission\nCommand: swift test\n\nDownloading 1%"
        let introductoryCue = detector.attentionCue(in: introductoryHeading, liveAgentKind: .hermes)
        #expect(introductoryCue != nil)
        let oneLineCommand = "Hermes\nThis tool needs permission\nCommand: printf 'permission required'\n\nDownloading 1%"
        let oneLineCue = detector.attentionCue(in: oneLineCommand, liveAgentKind: .hermes)
        #expect(oneLineCue != nil)
        let optionPhrase = "Hermes\npermission needed\nrun swift test\n--message 'permission required'\n\nDownloading 1%"
        let optionCue = detector.attentionCue(in: optionPhrase, liveAgentKind: .hermes)
        #expect(optionCue != nil)
        #expect(
            optionCue
                != detector.attentionCue(
                    in: optionPhrase.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        #expect(
            optionCue
                == detector.attentionCue(
                    in: optionPhrase.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        #expect(
            oneLineCue
                == detector.attentionCue(
                    in: oneLineCommand.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        #expect(
            oneLineCue
                != detector.attentionCue(
                    in: oneLineCommand.replacingOccurrences(of: "printf", with: "echo"), liveAgentKind: .hermes))
        for argument in ["--configuration debug", "--filter Parser?", "--message 'run this?'"] {
            let politeQuestion = "Hermes\nrun package upgrade step 1\nWould you like to run swift test?\n" + argument + "\n[y] yes [n] no"
            let politeCue = detector.attentionCue(in: politeQuestion, liveAgentKind: .hermes)
            #expect(detector.detectedState(in: politeQuestion, liveAgentKind: .hermes) == .needsAttention)
            #expect(politeCue != nil)
            #expect(
                politeCue
                    != detector.attentionCue(
                        in: politeQuestion.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
            #expect(
                politeCue
                    == detector.attentionCue(
                        in: politeQuestion.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .hermes))
        }
        for oldChoices in ["", "\n[y] yes [n] no"] {
            let retainedOldBlock = "Hermes\npermission needed\nCommand: previous task" + oldChoices + "\n\n" + introductoryHeading
            let currentCue = detector.attentionCue(in: retainedOldBlock, liveAgentKind: .hermes)
            #expect(currentCue == introductoryCue)
            #expect(
                currentCue
                    != detector.attentionCue(
                        in: retainedOldBlock.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
            #expect(
                currentCue
                    == detector.attentionCue(
                        in: retainedOldBlock.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        }
        #expect(
            introductoryCue
                == detector.attentionCue(
                    in: introductoryHeading.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        let introductoryPayload = introductoryHeading.replacingOccurrences(
            of: "Command: swift test", with: "Command: swift test\n--message \"permission required\"")
        #expect(
            detector.attentionCue(in: introductoryPayload, liveAgentKind: .hermes)
                != detector.attentionCue(
                    in: introductoryPayload.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .hermes))
        #expect(
            detector.attentionCue(in: introductoryPayload, liveAgentKind: .hermes)
                == detector.attentionCue(
                    in: introductoryPayload.replacingOccurrences(of: "1%", with: "99%"), liveAgentKind: .hermes))
        #expect(detector.attentionCue(in: "Downloading 99%", liveAgentKind: .shell) == nil)
        let commandPrompt = prompt.replacingOccurrences(of: "run swift test?", with: "Command: swift test")
        #expect(
            detector.attentionCue(in: commandPrompt, liveAgentKind: .shell)
                != detector.attentionCue(
                    in: commandPrompt.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell))
        let splitChoice = "Muse Code v1.2.3\nrun package upgrade step 1\nProceed with swift test?\n[y] yes [n] no"
        #expect(detector.detectedState(in: splitChoice) == .needsAttention)
        let priorSplitChoice = "permission needed\nrun previous task?\n[y] yes [n] no\n" + splitChoice
        #expect(
            detector.attentionCue(in: priorSplitChoice, liveAgentKind: .shell)
                == detector.attentionCue(in: priorSplitChoice.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))

        #expect(
            detector.attentionCue(in: splitChoice, liveAgentKind: .shell)
                == detector.attentionCue(in: splitChoice.replacingOccurrences(of: "step 1", with: "step 2"), liveAgentKind: .shell))
        #expect(
            detector.attentionCue(in: splitChoice, liveAgentKind: .shell)
                != detector.attentionCue(in: splitChoice.replacingOccurrences(of: "swift test", with: "swift build"), liveAgentKind: .shell)
        )
    }

    @Test("live Codex approval identity survives menu navigation")
    func codexCueIgnoresSelectedChoice() {
        let prompt =
            "Would you like to run the following command?\nswift test\n› 1. Yes, proceed\n  2. No, and tell Codex what to do differently"
        let first = detector.attentionCue(in: prompt, liveAgentKind: .codex)
        #expect(first != nil)
        let moved = prompt.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2.")
        #expect(first == detector.attentionCue(in: moved, liveAgentKind: .codex))
        #expect(first == detector.attentionCue(in: prompt + "\nDownloading 99%", liveAgentKind: .codex))
        #expect(detector.detectedState(in: prompt, liveAgentKind: .codex) == .needsAttention)
        let trailingStatus = prompt + "\n\nStatus: yes, proceed label rendered; tick 1"
        #expect(detector.detectedState(in: trailingStatus, liveAgentKind: .codex) == .needsAttention)
        #expect(first == detector.attentionCue(in: trailingStatus, liveAgentKind: .codex))
        #expect(
            detector.attentionCue(in: trailingStatus, liveAgentKind: .codex)
                == detector.attentionCue(in: trailingStatus.replacingOccurrences(of: "tick 1", with: "tick 2"), liveAgentKind: .codex))

        let caseSensitive = prompt.replacingOccurrences(of: "swift test", with: "printf 'A'")
        #expect(
            detector.attentionCue(in: caseSensitive, liveAgentKind: .codex)
                != detector.attentionCue(in: caseSensitive.replacingOccurrences(of: "'A'", with: "'a'"), liveAgentKind: .codex))
        let accented = prompt.replacingOccurrences(of: "swift test", with: "printf 'café'")
        #expect(
            detector.attentionCue(in: accented, liveAgentKind: .codex)
                != detector.attentionCue(in: accented.replacingOccurrences(of: "café", with: "cafe"), liveAgentKind: .codex))

    }

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

    @Test("live Codex question overlay is distinct from quoted questions and later UI")
    func codexQuestionOverlay() {
        // Captured from Codex 0.166.0 request_user_input; prose alone must not arm attention.
        let question = """
              Question 1/1 (1 unanswered)
              Does this question highlight the correct awesoMux agent?

              › 1. Yes                The correct awesoMux agent is highlighted.
                2. No                 The correct awesoMux agent is not highlighted.
                3. None of the above  Optionally, add details in notes (tab)

              tab to add notes | enter to submit answer | esc to interrupt
            """
        let notes = question.replacingOccurrences(
            of: "tab to add notes | enter to submit answer | esc to interrupt",
            with: "› Add notes\n\ntab or esc to clear notes | enter to submit answer")
        for liveQuestion in [
            question, notes, question.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2."),
        ] {
            #expect(detector.detectedOutput(in: liveQuestion, liveAgentKind: .codex)?.state == .needsAttention)
            #expect(detector.detectedOutput(in: liveQuestion, liveAgentKind: .codex)?.isLiveCodexQuestion == true)
        }
        for inactive in [
            question + "\n› Ask Codex to do anything",
            question + "\n• Working (3s • esc to interrupt)",
            question.replacingOccurrences(of: "Question 1/1 (1 unanswered)", with: "Question 1/1 (0 unanswered)"),
            question.replacingOccurrences(of: "Question 1/1 (1 unanswered)", with: "Question 2/1 (1 unanswered)"),
            question.replacingOccurrences(of: "Question 1/1 (1 unanswered)", with: "A quoted question:"),
            question.replacingOccurrences(of: "› 1.", with: "  1."),
            question.replacingOccurrences(of: "tab to add notes | enter to submit answer | esc to interrupt", with: ""),
            "Does this question highlight the correct awesoMux agent?\n1. Yes\n2. No",
        ] {
            #expect(detector.detectedOutput(in: inactive, liveAgentKind: .codex)?.state != .needsAttention)
        }
        #expect(detector.detectedOutput(in: question, liveAgentKind: .shell) == nil)

        let composer = "› Ask Codex to do anything\nGPT-6.1-Sol medium · ~/Development\n← for agents · ? for shortcuts"
        for prefix in ["", question + "\n", "Claude Code\nThinking\n"] {
            let idle = detector.detectedOutput(in: prefix + composer, liveAgentKind: .codex)
            #expect(idle?.state == .waiting)
            #expect(idle?.codexUI == .composer)
            #expect(idle?.agentKind == .codex)
        }
        #expect(detector.detectedOutput(in: "• Working (3s • esc to interrupt)\n" + composer, liveAgentKind: .codex)?.state == .thinking)
        #expect(
            detector.detectedOutput(
                in: "• Working (4s • esc to interrupt)\n└ Tip: Use /skills to list available skills.\n" + composer,
                liveAgentKind: .codex)?.state == .thinking)
        #expect(
            detector.detectedOutput(
                in: "• Working (4s • esc to interrupt)\n└ Tip: Use a preset to\n  run a saved prompt.\n\n" + composer,
                liveAgentKind: .codex)?.state == .thinking)
        let warningComposer = composer + "    ⚠ 2 warnings · f2 to view"
        #expect(detector.detectedOutput(in: warningComposer, liveAgentKind: .codex)?.codexUI == .composer)
        #expect(detector.detectedOutput(in: composer + "\nWarning details", liveAgentKind: .codex)?.codexUI != .composer)
        #expect(
            detector.detectedOutput(
                in: "• Working (4s • esc to interrupt)\n\n• Finished explaining that example.\n\n" + composer,
                liveAgentKind: .codex)?.state == .waiting)
        for unknown in ["› 1. Yes\n? for shortcuts", "Warning: MCP connection failed", "› Ask Codex to do anything"] {
            #expect(detector.detectedOutput(in: unknown, liveAgentKind: .codex)?.codexUI != .composer)
        }
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
        #expect(detector.detectedOutput(in: "• Ran swift test\n  └ 42 tests passed", liveAgentKind: .codex) == nil)

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
