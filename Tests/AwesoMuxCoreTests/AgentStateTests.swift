import AwesoMuxBridgeProtocol
import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Agent state")
struct AgentStateTests {
    @Test
    func testStateLabelsResolveFromExplicitBundleAndLocale() throws {
        let bundle = try #require(INT612LocalizationTestSupport.bundle)

        #expect(
            AgentState.idle.localizedLabel(
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ) == "⟦idle⟧"
        )
        #expect(
            AgentState.needsAttention.localizedLabel(
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ) == "⟦needs-input⟧"
        )
    }

    @Test
    func testExecutionVocabularyMatchesRuntimeContract() {
        #expect(
            AgentExecutionState.allCases == [
                .idle,
                .running,
                .waiting,
                .thinking,
                .output,
                .done,
                .error,
            ]
        )
    }

    @Test
    func testAttentionVocabularyMatchesRuntimeContract() {
        #expect(
            AttentionReason.allCases == [
                .bell,
                .desktopNotification,
                .permissionPrompt,
                .userInputRequired,
                .processError,
                .unknown,
            ]
        )
    }

    @Test
    func testStateVocabularyMatchesDesignContract() {
        #expect(
            AgentState.allCases == [
                .idle,
                .running,
                .waiting,
                .thinking,
                .output,
                .needsAttention,
                .done,
                .error,
            ]
        )
    }

    @Test
    func testLabelsMatchUserFacingVocabulary() {
        #expect(AgentState.idle.label == "Idle")
        #expect(AgentState.running.label == "Running")
        #expect(AgentState.waiting.label == "Waiting")
        #expect(AgentState.thinking.label == "Thinking")
        #expect(AgentState.output.label == "Output")
        #expect(AgentState.needsAttention.label == "Needs input")
        #expect(AgentState.done.label == "Done")
        #expect(AgentState.error.label == "Error")
    }

    @Test
    func testOnlyNeedsAttentionTriggersNotifications() {
        for state in AgentState.allCases {
            #expect(state.triggersNotification == (state == .needsAttention))
        }
    }

    @Test
    func testDisplayStateProjectsExecutionWithoutAttention() {
        #expect(
            AgentDisplayState(executionState: .waiting, attentionReason: nil) == .waiting
        )
        #expect(
            AgentDisplayState(executionState: .thinking, attentionReason: nil) == .thinking
        )
    }

    @Test
    func testDisplayStateProjectsAttentionOverExecution() {
        #expect(
            AgentDisplayState(executionState: .waiting, attentionReason: .permissionPrompt) == .needsAttention
        )
        #expect(
            AgentDisplayState(executionState: .running, attentionReason: .bell) == .needsAttention
        )
    }

    @Test
    func testDisplayStateLetsDeadExecutionThroughLowPriorityAttention() {
        // INT-506: a dead pane's recovery hint must show through a lingering
        // low-priority attentionReason from before the exit.
        #expect(
            AgentDisplayState(executionState: .done, attentionReason: .bell) == .done
        )
        #expect(
            AgentDisplayState(executionState: .error, attentionReason: .bell) == .error
        )
        #expect(
            AgentDisplayState(executionState: .error, attentionReason: .processError) == .error
        )
    }

    @Test
    func testDisplayStateKeepsHighPriorityAttentionLoudOnDeadPanes() {
        // An unanswered permission request outranks the recovery hint even on
        // a dead pane — the glanceable amber cues must survive.
        #expect(
            AgentDisplayState(executionState: .done, attentionReason: .permissionPrompt) == .needsAttention
        )
        #expect(
            AgentDisplayState(executionState: .error, attentionReason: .userInputRequired) == .needsAttention
        )
    }

    @Test
    func testPrioritySortsLoudStatesFirst() {
        let states: [AgentState] = [.running, .idle, .waiting, .output, .done, .thinking, .error, .needsAttention]

        #expect(
            states.sorted { $0.priority < $1.priority }
                == [.needsAttention, .error, .thinking, .done, .output, .waiting, .running, .idle]
        )
    }

    @Test
    func testUrgencyComparisonUsesPresentationPriority() {
        #expect(AgentState.needsAttention.isAtLeastAsUrgent(as: .error))
        #expect(AgentState.error.isAtLeastAsUrgent(as: .error))
        #expect(AgentState.thinking.isAtLeastAsUrgent(as: .output))
        #expect(!AgentState.running.isAtLeastAsUrgent(as: .waiting))
        #expect(!AgentState.idle.isAtLeastAsUrgent(as: .needsAttention))
    }

    @Test
    func testDecodesLegacyFinishedRawValueAsDone() throws {
        let json = Data(#""finished""#.utf8)
        let decoded = try JSONDecoder().decode(AgentState.self, from: json)
        #expect(decoded == .done)
    }

    @Test
    func testRoundTripsAllCurrentRawValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in AgentState.allCases {
            let encoded = try encoder.encode(state)
            let decoded = try decoder.decode(AgentState.self, from: encoded)
            #expect(decoded == state)
        }
    }

    @Test
    func testRejectsUnknownRawValue() {
        let json = Data(#""bogus""#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentState.self, from: json)
        }
    }

    @Test
    func testTerminalSessionDecodesLegacyNeedsAttentionWithoutLosingExecutionDefault() throws {
        let id = UUID()
        let json = Data(
            """
            {
              "id": "\(id.uuidString)",
              "title": "agent",
              "workingDirectory": "~",
              "agentKind": "Claude Code",
              "agentState": "needsAttention",
              "unreadNotificationCount": 1
            }
            """.utf8
        )

        let session = try JSONDecoder().decode(TerminalSession.self, from: json)

        #expect(session.agentExecutionState == .running)
        #expect(session.attentionReason == .unknown)
        #expect(session.agentState == .needsAttention)
    }

    @Test
    func testAgentExecutionStateDecodesLegacyFinishedAsDone() throws {
        // The new closed execution enum carries the same v0 `finished`→`done`
        // rename as the display enum, so a hand-edited or migrated snapshot
        // storing the new key with the old value still loads.
        let decoded = try JSONDecoder().decode(
            AgentExecutionState.self,
            from: Data(#""finished""#.utf8)
        )
        #expect(decoded == .done)
    }

    @Test
    func testTerminalSessionDecodesLegacyExecutionStatesFromAgentStateKey() throws {
        // The only snapshot shape that exists in the wild before this split is
        // one with a single `agentState` key. Walk the non-attention execution
        // states end-to-end through the real JSON decoder so the back-compat
        // memberwise fallback (`agentState?.executionState`) can't silently
        // regress a restored `.error`/`.done`/`.waiting` to `.idle`.
        let cases: [(legacy: String, execution: AgentExecutionState)] = [
            ("error", .error),
            ("done", .done),
            ("waiting", .waiting),
            ("idle", .idle),
            ("thinking", .thinking),
        ]

        for (legacy, execution) in cases {
            let json = Data(
                """
                {
                  "id": "\(UUID().uuidString)",
                  "title": "agent",
                  "workingDirectory": "~",
                  "agentKind": "Claude Code",
                  "agentState": "\(legacy)"
                }
                """.utf8
            )

            let session = try JSONDecoder().decode(TerminalSession.self, from: json)

            #expect(session.agentExecutionState == execution, "legacy \(legacy)")
            #expect(session.attentionReason == nil, "legacy \(legacy) carries no attention")
            #expect(session.agentState == AgentState(rawValue: legacy), "legacy \(legacy) display")
        }
    }

    @Test
    func testTerminalSessionEncodesSplitAgentStateKeysAndProjectsAttention() throws {
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .output,
            attentionReason: .bell
        )

        let encoded = try JSONEncoder().encode(session)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains(#""agentExecutionState""#))
        #expect(json.contains(#""attentionReason""#))
        #expect(!json.contains(#""agentState""#))

        let decoded = try JSONDecoder().decode(TerminalSession.self, from: encoded)
        #expect(decoded.agentExecutionState == .output)
        #expect(decoded.attentionReason == .bell)
        #expect(decoded.agentState == .needsAttention)
    }
}
