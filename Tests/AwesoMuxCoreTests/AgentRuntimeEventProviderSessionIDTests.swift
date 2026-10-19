import AwesoMuxBridgeProtocol
import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("Provider session id trust boundary and latch")
struct AgentRuntimeEventProviderSessionIDTests {
    private static let sessionA = "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private static let sessionB = "9a8b7c6d-5e4f-4321-9876-543210fedcba"

    // MARK: - sessionEnd superseded guard

    /// The regression this guard exists for: once every provider reports a
    /// session id, a buffered SessionEnd from the OLD session must not reset the
    /// live one.
    @Test(arguments: [(true, Self.sessionA), (true, nil), (false, Self.sessionA)] as [(Bool, String?)])
    func staleSessionEndWithMismatchedSessionIDIsDropped(sessionIDs: Bool, endID: String?) {
        var context = Self.supersededLifecycle(sessionIDs: sessionIDs)
        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: endID
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == (sessionIDs ? Self.sessionB : nil))
    }

    /// The `.supersededStopped` hole: gating the identity check on
    /// "superseded AND not currently stopped" meant the live session's own
    /// turn-end Stop switched the check off again, and the next stale end
    /// reset a session that is very much alive.
    @Test(arguments: [false, true])
    func staleSessionEndIsDroppedAfterTheLiveSessionStops(resumeTurn: Bool) {
        var context = Self.supersededLifecycle()
        #expect(
            context.apply(
                AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .waiting,
                    phase: .stop,
                    eventID: "stop-b",
                    providerSessionID: Self.sessionB,
                    timestamp: Date(timeIntervalSince1970: 13)
                )
            ) != nil)

        if resumeTurn {
            #expect(
                context.apply(
                    AgentRuntimeEvent(
                        source: .claudeCode, executionState: .thinking, phase: .promptSubmit,
                        eventID: "prompt-b", providerSessionID: Self.sessionB,
                        timestamp: Date(timeIntervalSince1970: resumeTurn ? 15 : 14)
                    )) != nil)
        }

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: resumeTurn ? 15 : 14)
            )
        )

        #expect(decision == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionB)
    }

    /// A same-kind nested child (`claude -p` inside a Bash tool call) exits
    /// while the parent is mid-turn. Its id disagrees with the latch, which is
    /// proof enough on its own — this pane's lifecycle was never superseded.
    @Test(arguments: [AgentRuntimePhase.sessionEnd, .sessionStart])
    func nestedChildSessionEndDoesNotResetTheParent(phase: AgentRuntimePhase) {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-parent",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            #expect(context.apply(event) != nil)
        }

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: phase,
                eventID: "end-child",
                providerSessionID: Self.sessionB,
                timestamp: Date(timeIntervalSince1970: 12)
            )
        )

        if phase == .sessionEnd { #expect(decision == nil) }
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == false)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)
        #expect(context.reducer.lastEndedTranscriptIdentity(for: context.paneID) == nil)
    }

    // MARK: - Last-ended transcript identity

    /// The live latch must still clear on sessionEnd so a new lifecycle cannot
    /// inherit the old id. The ended session's exact identity is kept separately
    /// so Open Agent Transcript can look up that file after the pane is a shell.
    @Test("sessionEnd keeps the ended identity after clearing the live latch")
    func sessionEndKeepsLastEndedIdentity() {
        var context = Context(agentKind: .claudeCode)
        #expect(
            context.apply(
                AgentRuntimeEvent(
                    source: .claudeCode,
                    executionState: .idle,
                    phase: .sessionStart,
                    eventID: "start",
                    providerSessionID: Self.sessionA
                )
            ) != nil)

        let decision = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionEnd,
                eventID: "end",
                providerSessionID: Self.sessionA
            )
        )

        #expect(decision?.update.agentKind == .shell)
        #expect(context.reducer.providerSessionID(for: context.paneID) == nil)
        #expect(context.reducer.lastEndedAgentKind(for: context.paneID) == .claudeCode)
        #expect(
            context.reducer.lastEndedTranscriptIdentity(for: context.paneID)
                == AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: Self.sessionA)
        )
    }

    /// The other half of the unclean-death case. `kill -9` / crash / sleep
    /// writes no Stop and no SessionEnd, so `AgentLivenessPolicy` synthesizes
    /// one from the process table — `source: .unknown`, no session id. It is
    /// the one end that provably cannot be stale, so the proven-mismatch drop
    /// above must never catch it: if it did, the dead id would stay latched
    /// and Resume would stage it beside whatever runs in the pane next.
    @Test("an app-synthesized end from process liveness clears the latch")
    func synthesizedLivenessEndClearsTheLatch() {
        var context = Context(agentKind: .claudeCode)
        for event in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-dead",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .thinking,
                phase: .toolStart,
                eventID: "tool-start",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
        ] {
            #expect(context.apply(event) != nil)
        }
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == Self.sessionA)

        let decision = context.apply(
            AgentRuntimeEvent(source: .unknown, executionState: .idle, phase: .sessionEnd)
        )

        #expect(decision?.update.agentKind == .shell)
        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == nil)
        #expect(context.reducer.stateByPaneID[context.paneID]?.lifecycle.isEnded == true)
        #expect(
            context.reducer.lastEndedTranscriptIdentity(for: context.paneID)
                == AgentTranscriptIdentity(agentKind: .claudeCode, sessionID: Self.sessionA)
        )
    }

    /// Without the pre-latch clear, the transcript surface would resolve the
    /// PREVIOUS session for a brand-new agent that has not reported an id yet.
    @Test(arguments: [(AgentRuntimePhase.stop, nil), (.notification, Self.sessionB)] as [(AgentRuntimePhase, String?)])
    func newLifecycleWithoutSessionIDClearsPreviousLatch(boundary: AgentRuntimePhase, newID: String?) {
        var context = Context(agentKind: .claudeCode)
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-old",
                providerSessionID: Self.sessionA,
                timestamp: Date(timeIntervalSince1970: 10)
            )
        )
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: boundary,
                eventID: "stop-old",
                timestamp: Date(timeIntervalSince1970: 11)
            )
        )
        _ = context.apply(
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-new",
                providerSessionID: newID,
                timestamp: Date(timeIntervalSince1970: 12)
            )
        )

        #expect(context.reducer.stateByPaneID[context.paneID]?.providerSessionID == newID)
    }

    // MARK: - Ingress validation

    @Test(
        "a hostile session id is stripped without dropping the event it rides on",
        arguments: [
            "3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d\nrm -rf ~",
            "../../../tmp/evil",
            String(repeating: "a", count: 512),
            "not-a-uuid",
            "",
        ]
    )
    func hostileSessionIDIsStrippedFromParsedEvent(rawSessionID: String) throws {
        let event = try #require(
            AgentRuntimeEvent.parse(data: Self.line(providerSessionID: rawSessionID))
        )

        #expect(event.providerSessionID == nil)
        #expect(event.phase == .sessionStart)
        #expect(event.executionState == .idle)
        #expect(event.source == .claudeCode)
    }

    // MARK: - Helpers

    private static func line(source: String = "claude-code", providerSessionID: Any) -> Data {
        let payload: [String: Any] = [
            "v": AgentRuntimeEvent.supportedVersion,
            "source": source,
            "execution": "idle",
            "phase": "sessionStart",
            "eventID": "e1",
            "providerSessionID": providerSessionID,
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// A pane whose lifecycle is superseded-but-not-stopped: session A started,
    /// stopped, and session B started on top of it. This is the exact state the
    /// `sessionEnd` guard arbitrates.
    private static func supersededLifecycle(sessionIDs: Bool = true) -> Context {
        var context = Context(agentKind: .claudeCode)
        for (index, event) in [
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-a",
                providerSessionID: sessionIDs ? sessionA : nil,
                timestamp: Date(timeIntervalSince1970: 10)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .waiting,
                phase: .stop,
                eventID: "stop-a",
                timestamp: Date(timeIntervalSince1970: 11)
            ),
            AgentRuntimeEvent(
                source: .claudeCode,
                executionState: .idle,
                phase: .sessionStart,
                eventID: "start-b",
                providerSessionID: sessionIDs ? sessionB : nil,
                timestamp: Date(timeIntervalSince1970: 12)
            ),
        ].enumerated() {
            #expect(context.apply(event) != nil, "setup event \(index) was dropped")
        }
        return context
    }

    private struct Context {
        let session: TerminalSession
        var reducer = AgentRuntimeEventReducer()

        var paneID: TerminalPane.ID { session.activePaneID }

        init(agentKind: AgentKind) {
            session = TerminalSession(
                title: "agent", workingDirectory: "~", agentKind: agentKind
            )
        }

        mutating func apply(_ event: AgentRuntimeEvent) -> AgentRuntimeEventReducer.Decision? {
            reducer.decision(
                for: event,
                currentSession: session,
                paneID: paneID,
                terminalIsFocused: false,
                now: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test(
        arguments: [
            ("claude-code", .text(Self.sessionA), Self.sessionA),
            ("claude-code", .text(Self.sessionA.uppercased()), Self.sessionA),
            ("claude-code", .number(42), nil),
            ("grok", .text("grok-parent"), "grok-parent"),
            ("grok", .text("parent\nrm -rf ~"), nil),
            ("opencode", .text("ses_01JABCdef0123456789XYZ"), "ses_01JABCdef0123456789XYZ"),
            ("opencode", .text("ses_"), nil),
            ("opencode", .text("msg_01JABC"), nil),
            ("opencode", .text("ses_bad/path"), nil),
            ("opencode", .text("ses_bad value"), nil),
            ("pi", .text("019c1234-5678-7abc-8def-0123456789ab"), "019c1234-5678-7abc-8def-0123456789ab"),
            ("pi", .text("project.branch_7"), "project.branch_7"),
            ("pi", .text("-leading"), nil),
            ("pi", .text("trailing-"), nil),
            ("pi", .text("bad/path"), nil),
            ("pi", .text("bad value"), nil),
        ] as [(String, SessionIDValue, String?)])
    func sessionIDParsing(source: String, raw: SessionIDValue, expected: String?) throws {
        let event = try #require(AgentRuntimeEvent.parse(data: Self.line(source: source, providerSessionID: raw.value)))
        #expect(event.providerSessionID == expected)
        #expect(event.phase == .sessionStart)
    }

    enum SessionIDValue: Sendable {
        case text(String)
        case number(Int)

        var value: Any {
            switch self {
            case .text(let text): text
            case .number(let number): number
            }
        }
    }
}
