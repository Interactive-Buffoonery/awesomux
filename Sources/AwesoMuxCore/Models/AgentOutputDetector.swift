import AwesoMuxBridgeProtocol
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

    public func detectedState(
        in visibleText: String,
        assumingAgentContext: Bool = false,
        liveAgentKind: AgentKind = .shell
    ) -> AgentState? {
        detectedOutput(
            in: visibleText,
            assumingAgentContext: assumingAgentContext,
            liveAgentKind: liveAgentKind
        )?.state
    }

    public func detectedOutput(
        in visibleText: String,
        assumingAgentContext: Bool = false,
        liveAgentKind: AgentKind = .shell
    ) -> AgentOutputDetection? {
        // locale: nil, not .current — every needle below is ASCII, and a
        // locale-sensitive fold breaks matching outright (Turkish İ/ı turns
        // "THINKING" into "thınkıng"). Case-insensitive folding already
        // lowercases, so no second .lowercased() pass over the viewport.
        let normalized = visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        guard assumingAgentContext || containsAgentContext(normalized, lines: lines) else {
            return nil
        }

        let hasStatefulAgentContext = containsStatefulAgentContext(lines)
        let hasGrokIdentity = containsConfidentGrokIdentity(normalized)
        let hasStrongHermesIdentity = containsStrongHermesIdentity(
            lines,
            allowsPromptLaunch: true
        )
        let hasHermesIdentity =
            hasStrongHermesIdentity || containsHermesConfigPath(normalized)
        // Path-only `/.hermes/` dumps must not suppress Claude cues; splash
        // heading, prompt launch, and a live Hermes process still do.
        let treatAsHermes = hasStrongHermesIdentity || liveAgentKind == .hermes
        let canEvaluateStateCues = hasStatefulAgentContext
            || (assumingAgentContext && !hasGrokIdentity && !hasHermesIdentity)
        let canEvaluateAttentionCues = hasStatefulAgentContext
            || assumingAgentContext
            || hasGrokIdentity
            || hasHermesIdentity
        let stateCueAgentKind = inferredAgentKind(
            lines: lines,
            allowsPromptLaunch: false,
            allowsGrokIdentity: false,
            hasGrokIdentity: hasGrokIdentity,
            hasStrongHermesIdentity: hasStrongHermesIdentity,
            hasHermesIdentity: hasHermesIdentity,
            liveAgentKind: liveAgentKind
        )
        let attentionCueAgentKind =
            hasGrokIdentity
            ? AgentKind.grok
            : (hasStrongHermesIdentity ? AgentKind.hermes : stateCueAgentKind)

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

        if treatAsHermes && containsHermesThinkingCue(lines) {
            return AgentOutputDetection(state: .thinking, agentKind: .hermes)
        }

        if canEvaluateAttentionCues && containsNeedsAttentionPrompt(normalized) {
            return AgentOutputDetection(state: .needsAttention, agentKind: attentionCueAgentKind)
        }

        // Claude thinking/done needles must not drive Hermes (or Grok): leftover
        // Claude chrome is common after SSH, and Hermes has no Stop hooks to
        // clear a false `.thinking` or `.done`. Path-only `/.hermes/` is Hermes
        // for this skip unless the live pane is already Claude — a live Claude
        // pane that merely prints that path must still show Claude thinking.
        let skipClaudeStateCues =
            treatAsHermes
            || hasGrokIdentity
            || liveAgentKind == .grok
            || (hasHermesIdentity && liveAgentKind != .claudeCode)
        if canEvaluateStateCues && !skipClaudeStateCues && containsThinkingCue(normalized) {
            return AgentOutputDetection(state: .thinking, agentKind: stateCueAgentKind)
        }

        if canEvaluateStateCues && !skipClaudeStateCues && containsDoneCue(normalized) {
            return AgentOutputDetection(state: .done, agentKind: stateCueAgentKind)
        }

        // Identity without a live activity cue: light the Grok/Codex/… icon and
        // report `.waiting`. For most kinds the reducer treats text-waiting as
        // kind-only (no state change). For Grok and Hermes, the reducer allows
        // waiting to clear sticky thinking while plugin Stop hooks stay dead.
        let agentKind = inferredAgentKind(
            lines: lines,
            allowsPromptLaunch: true,
            allowsGrokIdentity: true,
            hasGrokIdentity: hasGrokIdentity,
            hasStrongHermesIdentity: hasStrongHermesIdentity,
            hasHermesIdentity: hasHermesIdentity,
            liveAgentKind: liveAgentKind
        )
        if let agentKind {
            return AgentOutputDetection(state: .waiting, agentKind: agentKind)
        }

        return nil
    }

    public func observesAgentContext(in visibleText: String) -> Bool {
        let normalized =
            visibleText
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        return containsAgentContext(normalized, lines: lines)
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

    private func containsAgentContext(_ text: String, lines: [Substring]) -> Bool {
        containsStatefulAgentContext(lines)
            || containsConfidentGrokIdentity(text)
            || containsConfidentHermesIdentity(text, lines: lines, allowsPromptLaunch: true)
    }

    private func containsStatefulAgentContext(_ lines: [Substring]) -> Bool {
        containsConfidentClaudeIdentity(lines, allowsPromptLaunch: true)
            || containsConfidentOpenCodeIdentity(lines)
            || containsConfidentCodexIdentity(lines)
            || containsConfidentGenericIdentity(lines, allowsPromptLaunch: true)
    }

    // `hasGrokIdentity` is threaded through rather than re-derived here: the
    // caller already scanned for it once (`containsConfidentGrokIdentity` at
    // the top of `detectedOutput`), and this is called twice per sample.
    private func inferredAgentKind(
        lines: [Substring],
        allowsPromptLaunch: Bool,
        allowsGrokIdentity: Bool,
        hasGrokIdentity: Bool,
        hasStrongHermesIdentity: Bool,
        hasHermesIdentity: Bool,
        liveAgentKind: AgentKind
    ) -> AgentKind? {
        // Generic checked before Claude so a Muse/Cursor pane that mentions
        // "claude code" in prose does not get hijacked. Generic is prompt-anchored
        // (or banner-anchored for Muse) so plain prose mentioning these CLIs is safe.
        if containsConfidentGenericIdentity(lines, allowsPromptLaunch: allowsPromptLaunch) {
            return .generic
        }
        // Strong Hermes (splash/prompt) before Claude: leftover Claude docs in
        // a Hermes viewport must still first-tag as Hermes. Path-only `/.hermes/`
        // also wins over leftover Claude chrome unless the live pane is Claude.
        if hasStrongHermesIdentity {
            return .hermes
        }
        if hasHermesIdentity, liveAgentKind != .claudeCode {
            return .hermes
        }
        if containsConfidentClaudeIdentity(lines, allowsPromptLaunch: allowsPromptLaunch) {
            return .claudeCode
        }
        if allowsGrokIdentity, hasGrokIdentity {
            return .grok
        }
        if containsConfidentCodexIdentity(lines, allowsPromptLaunch: allowsPromptLaunch) {
            return .codex
        }
        if containsConfidentOpenCodeIdentity(lines, allowsPromptLaunch: allowsPromptLaunch) {
            return .openCode
        }
        if hasHermesIdentity {
            return .hermes
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

    private func containsConfidentClaudeIdentity(
        _ lines: [Substring],
        allowsPromptLaunch: Bool
    ) -> Bool {
        // Banner- and prompt-anchored only. A viewport that merely *mentions*
        // "claude code" or "claude ·" in prose, grep output, or another agent's
        // docs must not first-tag the pane Claude — that was the widest sticky
        // net. Keep genuine Claude Code splash/status lines working.
        if lineHasAnchoredPrefix(
            lines,
            [
                "claude code",
                "claude ·",
                "claude >",
                "claude ›",
            ])
        {
            return true
        }
        guard allowsPromptLaunch else {
            return false
        }
        return lineHasPromptLaunch(lines, command: "claude")
    }

    // Hermes heading / config-path / prompt-anchored launch. Bare "hermes" in
    // prose (NASA, mythology, a package name) is not identity, and neither is
    // a live `Ruminating…` status line on its own.
    private func containsConfidentHermesIdentity(
        _ text: String,
        lines: [Substring],
        allowsPromptLaunch: Bool
    ) -> Bool {
        containsStrongHermesIdentity(lines, allowsPromptLaunch: allowsPromptLaunch)
            || containsHermesConfigPath(text)
    }

    /// Splash heading or a prompt-anchored `hermes` launch. Strong enough to
    /// suppress leftover Claude chrome. A config-path dump is not.
    private func containsStrongHermesIdentity(
        _ lines: [Substring],
        allowsPromptLaunch: Bool
    ) -> Bool {
        if lineIsHermesHeading(lines) {
            return true
        }
        guard allowsPromptLaunch else {
            return false
        }
        return lineHasPromptLaunch(lines, command: "hermes")
    }

    private func containsHermesConfigPath(_ text: String) -> Bool {
        text.contains("~/.hermes") || text.contains("/.hermes/")
    }

    /// Anchored live status only. Mid-line historical "ruminating" in a recap
    /// must not keep Thinking after the status line is gone.
    private func containsHermesThinkingCue(_ lines: [Substring]) -> Bool {
        lineHasAnchoredPrefix(lines, ["ruminating"])
    }

    /// True when a line, after a *narrow* decorative strip, starts with one of
    /// the prefixes at a token boundary. Mid-sentence mentions do not match.
    private func lineHasAnchoredPrefix(_ lines: [Substring], _ prefixes: [String]) -> Bool {
        lines.contains { line in
            let content = dropDecorativePrefix(line)
            return prefixes.contains { prefix in
                hasTokenBoundedPrefix(content, prefix)
            }
        }
    }

    private func lineHasPromptLaunch(_ lines: [Substring], command: String) -> Bool {
        lineHasAnchoredPrefix(lines, ["$ \(command)", "❯ \(command)"])
    }

    /// Folded `hermes`, optionally `agent`, optionally `v0.21.3`-style version.
    /// Ordinary sentences (`hermes is a messaging protocol`) are not identity.
    private func lineIsHermesHeading(_ lines: [Substring]) -> Bool {
        lines.contains { line in
            let content = dropDecorativePrefix(line)
            guard hasTokenBoundedPrefix(content, "hermes") else {
                return false
            }
            var remaining = content.dropFirst("hermes".count).drop(while: \.isWhitespace)
            if remaining.isEmpty {
                return true
            }
            guard hasTokenBoundedPrefix(remaining, "agent") else {
                return false
            }
            remaining = remaining.dropFirst("agent".count).drop(while: \.isWhitespace)
            if remaining.isEmpty {
                return true
            }
            return remainderIsHermesBannerVersion(remaining)
        }
    }

    /// Optional `v` plus dotted digits, then trailing whitespace only.
    private func remainderIsHermesBannerVersion(_ rest: Substring) -> Bool {
        var remaining = rest
        if remaining.first == "v" {
            remaining = remaining.dropFirst()
        }
        guard remaining.first?.isNumber == true else {
            return false
        }
        var expectingDigit = false
        var index = remaining.startIndex
        while index < remaining.endIndex {
            let character = remaining[index]
            if character.isNumber {
                expectingDigit = false
                index = remaining.index(after: index)
                continue
            }
            if character == "." {
                if expectingDigit {
                    return false
                }
                expectingDigit = true
                index = remaining.index(after: index)
                continue
            }
            break
        }
        if expectingDigit {
            return false
        }
        return remaining[index...].allSatisfy(\.isWhitespace)
    }

    /// Needle at the start of the remaining line, not continuing an identifier
    /// (`$ claudecode` must not count as `$ claude`).
    private func hasTokenBoundedPrefix(_ content: Substring, _ prefix: String) -> Bool {
        guard content.hasPrefix(prefix) else {
            return false
        }
        let rest = content.dropFirst(prefix.count)
        guard let next = rest.first else {
            return true
        }
        if prefix.last?.isLetter == true || prefix.last?.isNumber == true {
            return !next.isLetter && !next.isNumber
        }
        return true
    }

    /// Strip leading whitespace and known box-drawing / bullet chrome only.
    /// Quotes, brackets, asterisks, digits, and other punctuation stay so
    /// `(claude code)` / `42 claude code` cannot first-tag.
    private func dropDecorativePrefix(_ line: Substring) -> Substring {
        line.drop(while: { $0.isWhitespace || $0.isAgentDecorativeGlyph })
    }

    // Codex has no status-hook identity at launch: its SessionStart hook event
    // only lands batched with the first prompt, so without a text signature the
    // pane shows the generic shell icon until the user types. Match the Codex
    // splash banner and a prompt-anchored launch. Prompt-anchored (not a bare
    // "codex" substring) so prose/paths naming codex don't mis-tag a shell.
    private func containsConfidentCodexIdentity(
        _ lines: [Substring],
        allowsPromptLaunch: Bool = true
    ) -> Bool {
        if lines.contains(where: { $0.contains("openai codex (") }) {
            return true
        }
        guard allowsPromptLaunch else {
            return false
        }
        return lines.contains { line in
            line.contains("$ codex") || line.contains("❯ codex")
        }
    }

    private func containsConfidentOpenCodeIdentity(
        _ lines: [Substring],
        allowsPromptLaunch: Bool = true
    ) -> Bool {
        guard allowsPromptLaunch else {
            return false
        }
        return lines.contains { line in
            line.contains("$ opencode") || line.contains("❯ opencode")
        }
    }

    private func containsConfidentGenericIdentity(
        _ lines: [Substring],
        allowsPromptLaunch: Bool
    ) -> Bool {
        if containsVersionedMuseBanner(lines) {
            return true
        }
        guard allowsPromptLaunch else {
            return false
        }
        return lines.contains { line in
            ["$ ", "❯ "].contains { marker in
                guard let markerRange = line.range(of: marker) else {
                    return false
                }
                let command = line[markerRange.upperBound...]
                    .prefix { !$0.isWhitespace }
                return AgentProcessRecognition.agentKind(forCommand: String(command)) == .generic
            }
        }
    }

    private func containsVersionedMuseBanner(_ lines: [Substring]) -> Bool {
        lines.contains { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[0] == "muse", parts[1] == "code" else {
                return false
            }
            let rawVersion = parts[2]
            let version = rawVersion.first == "v" ? rawVersion.dropFirst() : rawVersion[...]
            let components = version.split(separator: ".", omittingEmptySubsequences: false)
            return components.count >= 2
                && components.allSatisfy { component in
                    !component.isEmpty && component.allSatisfy { $0.isASCII && $0.isNumber }
                }
        }
    }

    private func containsNeedsAttentionPrompt(_ text: String) -> Bool {
        if text.contains("permission needed")
            || text.contains("permission required")
            || text.contains("needs permission")
            || text.contains("approve pending request")
        {
            return true
        }

        if text.contains("[y/n]")
            || text.contains("[y/n/a]")
            || text.contains("[y/n/s]")
            || text.contains("[y/n/e]")
        {
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

extension Character {
    /// Box-drawing and known bullet/block glyphs used as TUI chrome. Not
    /// arbitrary punctuation or digits — those wrap prose mentions.
    fileprivate var isAgentDecorativeGlyph: Bool {
        unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x2500...0x257F, 0x2580...0x259F:
                true
            case 0x2022, 0x2023, 0x2043, 0x2219,
                0x25AA, 0x25AB, 0x25B8, 0x25B9, 0x25BA,
                0x25C6, 0x25CB, 0x25CF, 0x25E6:
                true
            default:
                false
            }
        }
    }
}
