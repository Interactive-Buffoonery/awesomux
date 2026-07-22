import AwesoMuxBridgeProtocol
import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("AgentState design-system bridge")
struct AgentStateDesignSystemTests {
    @Test("every AgentState maps to its expected AwState")
    func agentStateMapsToExpectedAwState() {
        // Compiler exhaustiveness guarantees every case is HANDLED, but a wrong
        // arm (e.g. `.needsAttention -> .running`) still compiles. Pin the full
        // table so the only non-trivial arm — `.needsAttention -> .needs` — and
        // every passthrough are locked. Iterating `allCases` against an explicit
        // expectation means a newly added AgentState fails here until it's mapped.
        // Reaches the executable-target extension via `@testable import awesoMux`;
        // bridge extraction into a testable module is tracked in INT-395.
        let expected: [AgentState: AwState] = [
            .idle: .idle,
            .running: .running,
            .waiting: .waiting,
            .thinking: .thinking,
            .output: .output,
            .needsAttention: .needs,
            .done: .done,
            .error: .error
        ]

        for state in AgentState.allCases {
            #expect(state.awState == expected[state])
        }
    }

    @Test("every AgentState carries a non-empty spoken label")
    func everyAgentStateHasASpokenLabel() {
        // The accessibility story rests on each state having a non-color spoken
        // name; a future "simplify the label table" must not silently make a
        // state color-only (WCAG 1.4.1). Pin waiting explicitly as the canary.
        for state in AgentState.allCases {
            #expect(!state.awState.label.isEmpty)
        }
        #expect(AgentState.waiting.awState.label == "Waiting")
    }

    @Test("the domain label and the design-system spoken label agree for every state")
    func domainLabelMatchesAwStateLabel() {
        // Two spoken-label vocabularies exist: `AgentState.label` (domain) and
        // `AwState.label` (design system). Most surfaces speak the AwState wording
        // (sidebar row, peek card); the Workspaces rotor speaks the domain one
        // (INT-318). They MUST stay identical or VoiceOver announces two different
        // words for the same state — `.needsAttention` was "Needs attention" vs
        // "Needs input" until they were unified. Lock the whole table.
        for state in AgentState.allCases {
            #expect(state.label == state.awState.label)
        }
    }

    @Test("every AgentKind maps to its visible tile icon")
    func agentKindMapsToVisibleTileIcon() {
        // The visual identity axis is separate from state: a wrong mapping still
        // compiles, but would put the wrong glyph in sidebar rows and peek cards.
        // Pin every case so newly supported agents must choose an explicit icon.
        let expected: [AgentKind: AwAgentIcon] = [
            .claudeCode: .claude,
            .codex: .codex,
            .openCode: .openCode,
            .pi: .pi,
            .grok: .grok,
            .shell: .shell
        ]

        for kind in AgentKind.allCases {
            #expect(kind.awAgentIcon == expected[kind])
        }
    }
}
