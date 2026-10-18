import AwesoMuxBridgeProtocol

import Foundation
@testable import AwesoMuxCore

@main struct RuntimeJourney {
    @MainActor static func main() {
        var failures = 0
        func check(_ label: String, _ value: Bool) {
            print("\(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        let session = TerminalSession(title: "fixture", workingDirectory: "/tmp", agentKind: .codex)
        let store = SessionStore(groups: [SessionGroup(name: "fixture", sessions: [session])])
        let paneID = session.activePaneID
        let incarnation = AgentForegroundIncarnation(pid: 123, startedAt: 456)
        func sendTrust(_ tracker: AgentClientStatusTracker, kind: AgentKind = .codex) -> AgentForegroundIncarnation? {
            AgentPromptGate.verifiedWaitingForegroundGeneration(agentKind: kind, stamped: incarnation, clientStatusTracker: tracker, now: 1002)
        }
        let legacyStop = AgentRuntimeEvent(source: .codex, kind: .codex, executionState: .waiting, phase: .stop, eventID: "bootstrap-stop", providerSessionID: UUID().uuidString)
        check("legacy Stop remains accepted for display", store.applyAgentRuntimeEvent(legacyStop, to: session.id, paneID: paneID))
        check("legacy Stop retains waiting display", store.session(id: session.id)?.layout.pane(id: paneID)?.agentState == .waiting)
        var bootstrapTracker = AgentClientStatusTracker(observationStartedAt: 1000)
        check("empty tracker plus fresh legacy Stop cannot authorize Codex Send", sendTrust(bootstrapTracker) == nil)
        bootstrapTracker.invalidateObservation(now: 1001)
        check("watch recreation before heartbeat cannot authorize Codex Send", sendTrust(bootstrapTracker) == nil)
        bootstrapTracker = AgentClientStatusTracker(observationStartedAt: 1001)
        check("app recreation before heartbeat cannot authorize Codex Send", sendTrust(bootstrapTracker) == nil)
        let failedCallback = AgentClientStatusEvidence(clientID: UUID().uuidString, sequence: 1, completedTurns: 0, threadEpoch: 1, pid: 123, startedAt: 456, capturedAt: 1000)
        check("first stale callback rejected", !bootstrapTracker.accept(failedCallback, inputReady: true, observedPID: 123, observedStartedAt: 456, foregroundMatchesProvider: true, now: 1002))
        check("failed first callback cannot restore legacy Send", sendTrust(bootstrapTracker) == nil)
        for kind: AgentKind in [.claudeCode, .pi, .openCode] {
            check("legacy \(kind) retains readiness", sendTrust(bootstrapTracker, kind: kind) == incarnation)
        }
        let nativeReady = AgentClientStatusEvidence(clientID: UUID().uuidString, sequence: 1, completedTurns: 0, threadEpoch: 1, pid: 123, startedAt: 456, capturedAt: 1002)
        check("native Ready accepted after bootstrap", bootstrapTracker.accept(nativeReady, inputReady: true, observedPID: 123, observedStartedAt: 456, foregroundMatchesProvider: true, now: 1002))
        check("native Ready enables Codex Send", sendTrust(bootstrapTracker) == incarnation)
        bootstrapTracker.invalidateObservation(now: 1002)
        check("watch rearm revokes native Codex Send", sendTrust(bootstrapTracker) == nil)
        var sequence: UInt64 = 0
        var completedTurns: UInt64 = 0
        var threadEpoch: UInt64 = 1
        let threadA = UUID().uuidString, threadB = UUID().uuidString, clientID = UUID().uuidString
        func report(_ execution: AgentExecutionState?, attention: AttentionReason? = nil, thread: String, phase: AgentRuntimePhase = .notification, completed: UInt64? = nil, epoch: UInt64? = nil) {
            sequence += 1
            if let completed { completedTurns = completed }
            if let epoch { threadEpoch = epoch }
            let evidence = AgentClientStatusEvidence(clientID: clientID, sequence: sequence, completedTurns: completedTurns, threadEpoch: threadEpoch, pid: 123, startedAt: 456, capturedAt: Date().timeIntervalSince1970)
            check("accept native \(sequence)", store.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .codex, kind: .codex, executionState: execution, attentionReason: attention, phase: phase, eventID: UUID().uuidString, providerSessionID: thread, clientStatus: evidence), to: session.id, paneID: paneID))
        }
        report(.thinking, thread: threadA, phase: .sessionStart)
        report(.idle, attention: .userInputRequired, thread: threadA)
        report(.waiting, thread: threadA, completed: 1)
        check("blocked to ready clears attention", store.session(id: session.id)?.layout.pane(id: paneID)?.agentState == .waiting)
        check("ready marks unanswered", store.unansweredTurns[paneID] != nil)
        report(.idle, attention: .userInputRequired, thread: threadA)
        report(nil, thread: threadA)
        check("unavailable preserves attention", store.session(id: session.id)?.layout.pane(id: paneID)?.attentionReason == .userInputRequired)
        check("unavailable preserves execution", store.session(id: session.id)?.layout.pane(id: paneID)?.agentExecutionState == .idle)
        report(.thinking, thread: threadA)
        check("blocked to working clears attention", store.session(id: session.id)?.layout.pane(id: paneID)?.attentionReason == nil)
        check("working retracts unanswered", store.unansweredTurns[paneID] == nil)
        check("working clears unread", store.session(id: session.id)?.layout.pane(id: paneID)?.unreadNotificationCount == 0)
        let epoch = store.runtimeEventReducer.stateByPaneID[paneID]!.identityEpoch
        _ = store.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .codex, kind: .codex, executionState: .thinking, phase: .toolStart, eventID: "old-tool", providerSessionID: threadA), to: session.id, paneID: paneID)
        report(.thinking, thread: threadB, phase: .sessionStart, epoch: 2)
        let state = store.runtimeEventReducer.stateByPaneID[paneID]!
        check("native mid-turn switch changes identity epoch", state.identityEpoch != epoch)
        check("native switch clears old tool IDs", state.activeToolEventIDs.isEmpty)
        check("native switch updates selected thread", state.providerSessionID == threadB)
        let completionSession = TerminalSession(title: "completion", workingDirectory: "/tmp", agentKind: .codex)
        let completionStore = SessionStore(groups: [SessionGroup(name: "completion", sessions: [completionSession])])
        let completionPane = completionSession.activePaneID
        var completionSequence: UInt64 = 0
        var completionCount: UInt64 = 0
        var completionEpoch: UInt64 = 1
        func snapshot(_ execution: AgentExecutionState?, thread: String = threadA, client: String = clientID, focused: Bool = false, completed: UInt64? = nil, epoch: UInt64? = nil) {
            completionSequence += 1
            if let completed { completionCount = completed }
            if let epoch { completionEpoch = epoch }
            let phase: AgentRuntimePhase = completionStore.agentProviderSessionID(for: completionPane) == thread ? .notification : .sessionStart
            let evidence = AgentClientStatusEvidence(clientID: client, sequence: completionSequence, completedTurns: completionCount, threadEpoch: completionEpoch, pid: 789, startedAt: 321, capturedAt: Date().timeIntervalSince1970)
            check("accept completion snapshot \(completionSequence)", completionStore.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .codex, kind: .codex, executionState: execution, phase: phase, eventID: UUID().uuidString, providerSessionID: thread, clientStatus: evidence), to: completionSession.id, paneID: completionPane, terminalIsFocused: focused))
        }
        func unread() -> Int { completionStore.session(id: completionSession.id)!.layout.pane(id: completionPane)!.unreadNotificationCount }
        snapshot(.waiting)
        snapshot(.waiting)
        check("initial ready heartbeats do not mark unanswered", completionStore.unansweredTurns[completionPane] == nil)
        check("initial ready has no unread completion", unread() == 0)
        snapshot(.thinking)
        snapshot(nil)
        snapshot(.waiting, completed: 1)
        check("working through unavailable to ready marks unanswered", completionStore.unansweredTurns[completionPane] != nil)
        check("background completion increments unread exactly once", unread() == 1)
        snapshot(.waiting)
        check("ready heartbeat does not duplicate unread", unread() == 1)
        completionStore.acknowledgeSession(id: completionSession.id)
        snapshot(.waiting)
        check("acknowledged ready heartbeat stays cleared", completionStore.unansweredTurns[completionPane] == nil)
        snapshot(.thinking, focused: true)
        snapshot(.waiting, focused: true, completed: 2)
        check("focused completion creates no unread", unread() == 0)
        snapshot(.thinking)
        snapshot(.waiting, thread: threadB, epoch: 2)
        snapshot(.waiting, thread: threadB)
        check("thread switch ready creates no unread", unread() == 0)
        check("thread switch ready creates no unanswered", completionStore.unansweredTurns[completionPane] == nil)
        snapshot(.thinking, thread: threadB)
        let replacementClient = UUID().uuidString
        snapshot(.waiting, thread: threadB, client: replacementClient, completed: 0, epoch: 1)
        check("replacement client ready creates no completion", unread() == 0)
        snapshot(.waiting, thread: threadB, client: replacementClient, completed: 1)
        check("coalesced working still reports completion", unread() == 1)
        check("coalesced completion marks unanswered", completionStore.unansweredTurns[completionPane] != nil)
        snapshot(.waiting, thread: threadB, client: replacementClient)
        check("coalesced completion heartbeat does not duplicate", unread() == 1)
        completionStore.acknowledgeSession(id: completionSession.id)
        snapshot(.thinking, thread: threadB, client: replacementClient, completed: 3)
        snapshot(.waiting, thread: threadB, client: replacementClient)
        check("intermediate working retains aggregate completion", unread() == 1)
        snapshot(.waiting, thread: threadB, client: replacementClient)
        check("aggregate completion heartbeat does not duplicate", unread() == 1)
        completionStore.acknowledgeSession(id: completionSession.id)
        let epochClient = UUID().uuidString
        snapshot(.waiting, thread: threadB, client: epochClient, completed: 0, epoch: 1)
        snapshot(.waiting, thread: threadB, client: epochClient, completed: 1, epoch: 3)
        check("fully coalesced thread roundtrip creates no unread", unread() == 0)
        check("fully coalesced thread roundtrip creates no unanswered", completionStore.unansweredTurns[completionPane] == nil)
        snapshot(.waiting, thread: threadB, client: epochClient, completed: 2)
        check("same epoch completion remains live", unread() == 1)
        print("RESULT: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
