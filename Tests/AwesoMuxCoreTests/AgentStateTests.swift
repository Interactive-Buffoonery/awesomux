import Foundation
import XCTest
@testable import AwesoMuxCore

final class AgentStateTests: XCTestCase {
    func testStateLabelsResolveFromExplicitBundleAndLocale() throws {
        let bundle = try XCTUnwrap(INT612LocalizationTestSupport.bundle)

        XCTAssertEqual(
            AgentState.idle.localizedLabel(
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ),
            "⟦idle⟧"
        )
        XCTAssertEqual(
            AgentState.needsAttention.localizedLabel(
                bundle: bundle,
                locale: INT612LocalizationTestSupport.pseudoLocale
            ),
            "⟦needs-input⟧"
        )
    }
    func testExecutionVocabularyMatchesRuntimeContract() {
        XCTAssertEqual(
            AgentExecutionState.allCases,
            [
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

    func testAttentionVocabularyMatchesRuntimeContract() {
        XCTAssertEqual(
            AttentionReason.allCases,
            [
                .bell,
                .desktopNotification,
                .permissionPrompt,
                .userInputRequired,
                .processError,
                .unknown,
            ]
        )
    }

    func testStateVocabularyMatchesDesignContract() {
        XCTAssertEqual(
            AgentState.allCases,
            [
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

    func testLabelsMatchUserFacingVocabulary() {
        XCTAssertEqual(AgentState.idle.label, "Idle")
        XCTAssertEqual(AgentState.running.label, "Running")
        XCTAssertEqual(AgentState.waiting.label, "Waiting")
        XCTAssertEqual(AgentState.thinking.label, "Thinking")
        XCTAssertEqual(AgentState.output.label, "Output")
        XCTAssertEqual(AgentState.needsAttention.label, "Needs input")
        XCTAssertEqual(AgentState.done.label, "Done")
        XCTAssertEqual(AgentState.error.label, "Error")
    }

    func testOnlyNeedsAttentionTriggersNotifications() {
        for state in AgentState.allCases {
            XCTAssertEqual(state.triggersNotification, state == .needsAttention)
        }
    }

    func testDisplayStateProjectsExecutionWithoutAttention() {
        XCTAssertEqual(
            AgentDisplayState(executionState: .waiting, attentionReason: nil),
            .waiting
        )
        XCTAssertEqual(
            AgentDisplayState(executionState: .thinking, attentionReason: nil),
            .thinking
        )
    }

    func testDisplayStateProjectsAttentionOverExecution() {
        XCTAssertEqual(
            AgentDisplayState(executionState: .waiting, attentionReason: .permissionPrompt),
            .needsAttention
        )
        XCTAssertEqual(
            AgentDisplayState(executionState: .running, attentionReason: .bell),
            .needsAttention
        )
    }

    func testDisplayStateLetsDeadExecutionThroughLowPriorityAttention() {
        // INT-506: a dead pane's recovery hint must show through a lingering
        // low-priority attentionReason from before the exit.
        XCTAssertEqual(
            AgentDisplayState(executionState: .done, attentionReason: .bell),
            .done
        )
        XCTAssertEqual(
            AgentDisplayState(executionState: .error, attentionReason: .bell),
            .error
        )
        XCTAssertEqual(
            AgentDisplayState(executionState: .error, attentionReason: .processError),
            .error
        )
    }

    func testDisplayStateKeepsHighPriorityAttentionLoudOnDeadPanes() {
        // An unanswered permission request outranks the recovery hint even on
        // a dead pane — the glanceable amber cues must survive.
        XCTAssertEqual(
            AgentDisplayState(executionState: .done, attentionReason: .permissionPrompt),
            .needsAttention
        )
        XCTAssertEqual(
            AgentDisplayState(executionState: .error, attentionReason: .userInputRequired),
            .needsAttention
        )
    }

    func testPrioritySortsLoudStatesFirst() {
        let states: [AgentState] = [.running, .idle, .waiting, .output, .done, .thinking, .error, .needsAttention]

        XCTAssertEqual(
            states.sorted { $0.priority < $1.priority },
            [.needsAttention, .error, .thinking, .done, .output, .waiting, .running, .idle]
        )
    }

    func testUrgencyComparisonUsesPresentationPriority() {
        XCTAssertTrue(AgentState.needsAttention.isAtLeastAsUrgent(as: .error))
        XCTAssertTrue(AgentState.error.isAtLeastAsUrgent(as: .error))
        XCTAssertTrue(AgentState.thinking.isAtLeastAsUrgent(as: .output))
        XCTAssertFalse(AgentState.running.isAtLeastAsUrgent(as: .waiting))
        XCTAssertFalse(AgentState.idle.isAtLeastAsUrgent(as: .needsAttention))
    }

    func testDecodesLegacyFinishedRawValueAsDone() throws {
        let json = Data(#""finished""#.utf8)
        let decoded = try JSONDecoder().decode(AgentState.self, from: json)
        XCTAssertEqual(decoded, .done)
    }

    func testRoundTripsAllCurrentRawValues() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in AgentState.allCases {
            let encoded = try encoder.encode(state)
            let decoded = try decoder.decode(AgentState.self, from: encoded)
            XCTAssertEqual(decoded, state)
        }
    }

    func testRejectsUnknownRawValue() {
        let json = Data(#""bogus""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentState.self, from: json))
    }

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

        XCTAssertEqual(session.agentExecutionState, .running)
        XCTAssertEqual(session.attentionReason, .unknown)
        XCTAssertEqual(session.agentState, .needsAttention)
    }

    func testAgentExecutionStateDecodesLegacyFinishedAsDone() throws {
        // The new closed execution enum carries the same v0 `finished`→`done`
        // rename as the display enum, so a hand-edited or migrated snapshot
        // storing the new key with the old value still loads.
        let decoded = try JSONDecoder().decode(
            AgentExecutionState.self,
            from: Data(#""finished""#.utf8)
        )
        XCTAssertEqual(decoded, .done)
    }

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

            XCTAssertEqual(session.agentExecutionState, execution, "legacy \(legacy)")
            XCTAssertNil(session.attentionReason, "legacy \(legacy) carries no attention")
            XCTAssertEqual(session.agentState, AgentState(rawValue: legacy), "legacy \(legacy) display")
        }
    }

    func testTerminalSessionEncodesSplitAgentStateKeysAndProjectsAttention() throws {
        let session = TerminalSession(
            title: "agent",
            workingDirectory: "~",
            agentKind: .codex,
            agentExecutionState: .output,
            attentionReason: .bell
        )

        let encoded = try JSONEncoder().encode(session)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains(#""agentExecutionState""#))
        XCTAssertTrue(json.contains(#""attentionReason""#))
        XCTAssertFalse(json.contains(#""agentState""#))

        let decoded = try JSONDecoder().decode(TerminalSession.self, from: encoded)
        XCTAssertEqual(decoded.agentExecutionState, .output)
        XCTAssertEqual(decoded.attentionReason, .bell)
        XCTAssertEqual(decoded.agentState, .needsAttention)
    }
}
