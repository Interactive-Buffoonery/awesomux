import Foundation

public struct AgentOutputDetection: Equatable, Sendable {
    public var state: AgentState
    public var agentKind: AgentKind?
    /// Whether the kind was proven by an authoritative source (the live
    /// foreground process `comm`) rather than guessed from scraped viewport
    /// text. Only an authoritative kind may reclaim a pane already tagged with
    /// a different non-shell kind — a scraped signature still sitting in the
    /// scrollback must not. Text detections leave this `false`.
    public var agentKindIsAuthoritative: Bool

    public init(
        state: AgentState,
        agentKind: AgentKind? = nil,
        agentKindIsAuthoritative: Bool = false
    ) {
        self.state = state
        self.agentKind = agentKind
        self.agentKindIsAuthoritative = agentKindIsAuthoritative
    }
}

public struct AgentOutputDetector: Sendable {
    public init() {}

    public func detectedState(in visibleText: String, assumingAgentContext: Bool = false) -> AgentState? {
        detectedOutput(in: visibleText, assumingAgentContext: assumingAgentContext)?.state
    }

    public func detectedOutput(
        in visibleText: String,
        assumingAgentContext: Bool = false
    ) -> AgentOutputDetection? {
        let normalized = visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        guard assumingAgentContext || containsAgentContext(normalized) else {
            return nil
        }

        let hasStatefulAgentContext = containsStatefulAgentContext(normalized)
        let hasGrokIdentity = containsConfidentGrokIdentity(normalized)
        let canEvaluateStateCues = hasStatefulAgentContext
            || (assumingAgentContext && !hasGrokIdentity)
        let canEvaluateAttentionCues = hasStatefulAgentContext
            || assumingAgentContext
            || hasGrokIdentity
        let stateCueAgentKind = inferredAgentKind(
            normalized,
            allowsPromptLaunch: false,
            allowsGrokIdentity: false,
            hasGrokIdentity: hasGrokIdentity
        )
        let attentionCueAgentKind = hasGrokIdentity ? AgentKind.grok : stateCueAgentKind

        // Grok Build currently does not invoke plugin lifecycle hooks (verified
        // against 0.2.x), so the sidebar cannot rely on UserPromptSubmit /
        // PreToolUse for thinking. When the viewport is confidently Grok, honor
        // *live* Grok activity cues only — never past-tense "Thought for …"
        // scrollback, which sticks after the turn ends. Live activity is checked
        // BEFORE attention so a mid-turn subagent transcript that still contains
        // an old `[y/n]` line does not beat an active thinking cue.
        if hasGrokIdentity && containsGrokThinkingCue(normalized) {
            return AgentOutputDetection(state: .thinking, agentKind: .grok)
        }

        if canEvaluateAttentionCues && containsNeedsAttentionPrompt(normalized) {
            return AgentOutputDetection(state: .needsAttention, agentKind: attentionCueAgentKind)
        }

        if canEvaluateStateCues && containsThinkingCue(normalized) {
            return AgentOutputDetection(state: .thinking, agentKind: stateCueAgentKind)
        }

        if canEvaluateStateCues && containsDoneCue(normalized) {
            return AgentOutputDetection(state: .done, agentKind: stateCueAgentKind)
        }

        // Identity without a live activity cue: light the Grok/Codex/… icon and
        // report `.waiting`. For most kinds the reducer treats text-waiting as
        // kind-only (no state change). For Grok, the reducer allows waiting to
        // clear sticky thinking while plugin Stop hooks stay dead (0.2.x).
        let agentKind = inferredAgentKind(
            normalized,
            allowsPromptLaunch: true,
            allowsGrokIdentity: true,
            hasGrokIdentity: hasGrokIdentity
        )
        if let agentKind {
            return AgentOutputDetection(state: .waiting, agentKind: agentKind)
        }

        return nil
    }

    public func observesAgentContext(in visibleText: String) -> Bool {
        containsAgentContext(
            visibleText
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
        )
    }

    public func stateForCommandFinished(
        exitCode: Int16,
        agentWasActive: Bool,
        liveAgentKind: AgentKind = .shell
    ) -> AgentState? {
        guard exitCode >= 0 else {
            return nil
        }

        guard agentWasActive else {
            return nil
        }

        // Hook-capable kinds own turn completion (Stop → waiting). A tool's
        // shell exit must not paint Done while Claude/Codex/Grok/etc. still
        // drive the pane — Grok especially, since its plugin hooks do not fire
        // today and shell exits were the only signal reaching the tile.
        if exitCode == 0, liveAgentKind.usesReliableHooks {
            return nil
        }

        return exitCode == 0 ? .done : .error
    }

    private func containsAgentContext(_ text: String) -> Bool {
        containsStatefulAgentContext(text)
            || containsConfidentGrokIdentity(text)
    }

    private func containsStatefulAgentContext(_ text: String) -> Bool {
        text.contains("claude code")
            || text.contains("claude ·")
            || text.contains("claude >")
            || text.contains("claude ›")
            || text.contains("$ claude")
            || text.contains("❯ claude")
            || containsConfidentOpenCodeIdentity(text, allowsPromptLaunch: true)
            || containsConfidentCodexIdentity(text, allowsPromptLaunch: true)
    }

    // `hasGrokIdentity` is threaded through rather than re-derived here: the
    // caller already scanned for it once (`containsConfidentGrokIdentity` at
    // the top of `detectedOutput`), and this is called twice per sample.
    private func inferredAgentKind(
        _ text: String,
        allowsPromptLaunch: Bool,
        allowsGrokIdentity: Bool,
        hasGrokIdentity: Bool
    ) -> AgentKind? {
        if containsConfidentClaudeIdentity(text) {
            return .claudeCode
        }
        if allowsGrokIdentity, hasGrokIdentity {
            return .grok
        }
        if containsConfidentCodexIdentity(text, allowsPromptLaunch: allowsPromptLaunch) {
            return .codex
        }
        if containsConfidentOpenCodeIdentity(text, allowsPromptLaunch: allowsPromptLaunch) {
            return .openCode
        }
        return nil
    }

    // Prompt-anchored / title-anchored only: a bare "grok" appears in prose,
    // model names, and URLs far too often to tag a session on. Requires a shell
    // prompt (`$`/`❯`) launching `grok`, Grok's own prompt, or the terminal
    // title suffix awesoMux/Grok set (`… - grok`).
    private func containsConfidentGrokIdentity(_ text: String) -> Bool {
        text.contains("$ grok")
            || text.contains("❯ grok")
            || text.contains("grok >")
            || text.contains("grok ›")
            || text.contains(" - grok")
            || text.hasSuffix(" grok")
            || text.contains("\ngrok\n")
    }

    private func containsConfidentClaudeIdentity(_ text: String) -> Bool {
        text.contains("claude code")
            || text.contains("claude ·")
            || text.contains("claude >")
            || text.contains("claude ›")
    }

    // Codex has no status-hook identity at launch: its SessionStart hook event
    // only lands batched with the first prompt, so without a text signature the
    // pane shows the generic shell icon until the user types. Match the Codex
    // splash banner and a prompt-anchored launch. Prompt-anchored (not a bare
    // "codex" substring) so prose/paths naming codex don't mis-tag a shell.
    private func containsConfidentCodexIdentity(
        _ text: String,
        allowsPromptLaunch: Bool
    ) -> Bool {
        if text.contains("openai codex (") {
            return true
        }
        guard allowsPromptLaunch else {
            return false
        }
        return text.contains("$ codex") || text.contains("❯ codex")
    }

    private func containsConfidentOpenCodeIdentity(
        _ text: String,
        allowsPromptLaunch: Bool
    ) -> Bool {
        guard allowsPromptLaunch else {
            return false
        }
        return text.contains("$ opencode") || text.contains("❯ opencode")
    }

    private func containsNeedsAttentionPrompt(_ text: String) -> Bool {
        if text.contains("permission needed")
            || text.contains("permission required")
            || text.contains("needs permission")
            || text.contains("approve pending request") {
            return true
        }

        if text.contains("[y/n]")
            || text.contains("[y/n/a]")
            || text.contains("[y/n/s]")
            || text.contains("[y/n/e]") {
            return true
        }

        let hasSeparateChoices = text.contains("[y]") && text.contains("[n]")
        let promptAsksForAction = text.contains("run ")
            || text.contains("allow")
            || text.contains("approve")
            || text.contains("proceed")
            || text.contains("continue")
        if hasSeparateChoices && promptAsksForAction {
            return true
        }

        return false
    }

    private func containsThinkingCue(_ text: String) -> Bool {
        text.contains("claude · thinking")
            || text.contains("claude is thinking")
            || text.contains("esc to interrupt")
            || text.contains("ctrl-c to interrupt")
    }

    /// *Live* activity lines Grok Build prints while a turn is in flight.
    /// Kept separate from Claude's interrupt cues so leftover Claude scrollback
    /// does not flip a Grok pane (see Grok identity tests).
    ///
    /// Deliberately excluded:
    /// - Past-tense `Thought for Xs` — remains in scrollback after the turn ends
    ///   and would re-arm sticky thinking forever.
    /// - Always-visible footer (`ctrl+c:cancel`) — present at the idle prompt.
    private func containsGrokThinkingCue(_ text: String) -> Bool {
        text.contains("subagent running")
            // Live status / title while a turn is in flight (ASCII + unicode ellipsis).
            || text.contains("thinking...")
            || text.contains("thinking…")
            || text.contains(": thinking")
            || text.contains("- thinking -")
            || text.contains("thinking (grok")
    }

    private func containsDoneCue(_ text: String) -> Bool {
        text.contains("awaiting your review")
            || text.contains("task complete")
            || text.contains("done ·")
            || text.contains("complete ·")
    }
}
