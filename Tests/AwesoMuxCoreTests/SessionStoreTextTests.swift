import Testing
@testable import AwesoMuxCore

@Suite("SessionStoreText")
struct SessionStoreTextTests {
    @Test("synthetic title lets the selected locale own word order")
    func syntheticTitleUsesLocalizedGrammar() throws {
        let bundle = try #require(INT612LocalizationTestSupport.bundle)

        #expect(
            SyntheticSessionTitle(agentKind: .shell, index: 2).localizedTitle(
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ) == "⟦2:⟦shell⟧⟧")
    }
    @Test("synthetic shell prefix resolves from the app-owned catalog")
    func syntheticShellPrefixUsesAppBundle() throws {
        #expect(SessionStoreText.syntheticSessionTitlePrefix(for: .shell) == "shell")
    }

    @Test("non-shell agent kinds pass their brand name through untranslated")
    func nonShellAgentKindsUseBrandNameVerbatim() throws {
        #expect(SessionStoreText.syntheticSessionTitlePrefix(for: .claudeCode) == "Claude")
        #expect(SessionStoreText.syntheticSessionTitlePrefix(for: .codex) == "Codex")
        #expect(SessionStoreText.syntheticSessionTitlePrefix(for: .openCode) == "OpenCode")
        #expect(SessionStoreText.syntheticSessionTitlePrefix(for: .pi) == "Pi")
    }

    @Test("syntheticSessionTitle composes the prefix and index for all three fallback call sites")
    func syntheticSessionTitleComposesPrefixAndIndex() throws {
        #expect(SessionStoreText.syntheticSessionTitle(for: .shell, index: 1) == "shell 1")
        #expect(SessionStoreText.syntheticSessionTitle(for: .codex, index: 2) == "Codex 2")
    }

    @Test("restoredTitle composes the synthetic prefix with the fallback index")
    func restoredTitleComposesPrefixAndIndex() throws {
        #expect(
            SessionStoreText.restoredTitle("", fallbackForAgent: .shell, index: 3) == "shell 3"
        )
        #expect(
            SessionStoreText.restoredTitle("", fallbackForAgent: .codex, index: 2) == "Codex 2"
        )
    }

    @Test("AgentKind.shortName's shell case resolves from the app-owned catalog")
    func agentKindShortNameShellUsesAppBundle() throws {
        #expect(AgentKind.shell.shortName == "Shell")
    }

    @Test("AgentKind.spokenName uses the localized shell name but the full brand rawValue elsewhere")
    func spokenNamePicksLocalizedShellOrFullRawValue() throws {
        // WorkspaceAttentionAnnouncementTracker speaks this value directly — it must
        // route .shell through the same localized text as shortName (PR-review finding),
        // while non-shell kinds keep their full rawValue brand name ("Claude Code", not
        // the shortened "Claude"), matching WorkspaceAttentionAnnouncementTrackerTests'
        // existing "Claude Code in ..." expectations.
        #expect(AgentKind.shell.spokenName == AgentKind.shell.shortName)
        #expect(AgentKind.claudeCode.spokenName == "Claude Code")
        #expect(AgentKind.codex.spokenName == "Codex")
        #expect(AgentKind.openCode.spokenName == "OpenCode")
        #expect(AgentKind.pi.spokenName == "Pi")
    }
}
