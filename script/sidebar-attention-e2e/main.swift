import AwesoMuxBridgeProtocol

import AwesoMuxCore
import Foundation

// Public store + production projection journey; no view, terminal, or hook transport is simulated.
@main struct Journey {
    @MainActor static func main() throws {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            checks.append(["name": name, "passed": condition])
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let home = TerminalSession(title: "Home", workingDirectory: "/tmp")
        let codex = TerminalSession(title: "Codex", workingDirectory: "/tmp", agentKind: .codex)
        let claude = TerminalSession(title: "Claude", workingDirectory: "/tmp", agentKind: .claudeCode)
        let store = SessionStore(groups: [SessionGroup(name: "First", sessions: [home]), SessionGroup(name: "Agents", sessions: [codex, claude])], selectedSessionID: home.id)
        store.needsInputSectionEnabled = true
        func visible(_ query: String = "") -> (attention: [UUID], pinned: [UUID], rest: [UUID], top: UUID?, rotor: [String]) {
            let search = SidebarSearchProjection.project(groups: store.groups, query: query) {
                SidebarSearchHaystacks(title: $0.title, location: $0.workingDirectory, agentState: .idle)
            }
            let pinned = SidebarPinnedProjection.apply(entries: search.entries, pinnedSessionIDs: store.pinnedSessionIDs, isFiltering: !query.isEmpty, searchTopMatch: search.topMatch)
            let attention = SidebarAttentionProjection.apply(entries: pinned.entries, liftedSessionIDs: store.liftedSessionIDs, isFiltering: !query.isEmpty, searchTopMatch: pinned.topMatch)
            let a = attention.attention.map { $0.entry.session.id }
            let p = pinned.pinned.map { $0.entry.session.id }
            let r = attention.entries.flatMap(\.sessions).map { $0.session.id }
            if query.isEmpty {
                check("projection matches navigation", a + p + r == WorkspaceNavigationOrder.liftedFirstSessionIDs(in: store.groups, liftedSessionIDs: store.liftedSessionIDs, pinnedSessionIDs: store.pinnedSessionIDs))
            }
            return (a, p, r, attention.topMatch, SidebarVisibleRows.rotorEntries(attention: attention.attention, pinned: pinned.pinned, for: attention.entries).map(\.label))
        }
        func event(_ phase: AgentRuntimePhase, session: TerminalSession, pane: UUID? = nil, source: AgentRuntimeSource = .codex, execution: AgentExecutionState = .waiting) {
            check("event accepted: \(source) \(phase)", store.applyAgentRuntimeEvent(AgentRuntimeEvent(source: source, executionState: execution, phase: phase, providerSessionID: source.rawValue), to: session.id, paneID: pane ?? session.activePaneID))
        }
        store.markSessionNeedsAttention(id: codex.id)
        check("generic orange attention lifts", visible().attention == [codex.id])
        check("lifted rotor identifies Needs Attention", visible().rotor.first?.contains("Needs attention, from") == true)
        check("generic reason stays unknown", store.session(id: codex.id)?.layout.pane(id: codex.activePaneID)?.attentionReason == .unknown)
        store.selectedSessionID = codex.id
        store.acknowledgeSession(id: codex.id, releasesAttentionSticky: false, answersUnansweredTurn: false)
        check("row stays while being read", visible().attention == [codex.id])
        store.selectedSessionID = home.id
        check("read row returns to original order", visible().rest == [home.id, codex.id, claude.id])
        event(.stop, session: codex)
        check("Codex completed response lifts", visible().attention == [codex.id])
        check("Codex completion does not invent attention", store.session(id: codex.id)?.layout.pane(id: codex.activePaneID)?.attentionReason == nil)
        check("search preserves lifted match", visible("Codex").attention == [codex.id] && visible("Codex").top == codex.id)
        store.togglePin(sessionID: codex.id)
        let pinned = visible()
        check("pin wins without duplicate", pinned.attention.isEmpty && pinned.pinned == [codex.id] && !pinned.rest.contains(codex.id))
        store.togglePin(sessionID: codex.id)
        event(.toolStart, session: codex, execution: .running)
        check("Codex continuation retracts completion", visible().attention.isEmpty && store.unansweredTurnPaneIDs.isEmpty)
        event(.stop, session: codex)
        check("continued Codex completion lifts again", visible().attention == [codex.id])
        event(.promptSubmit, session: codex, execution: .running)
        check("answer restores group order", visible().attention.isEmpty && visible().rest == [home.id, codex.id, claude.id])
        store.selectedSessionID = codex.id
        event(.stop, session: codex)
        check("selected quiet completion lifts", visible().attention == [codex.id])
        event(.promptSubmit, session: codex, execution: .running)
        check("selected answer releases quiet completion immediately", visible().attention.isEmpty)
        store.selectedSessionID = home.id
        check("bell event accepted", store.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .codex, attentionReason: .bell, phase: .notification), to: codex.id, paneID: codex.activePaneID))
        check("bell attention lifts", visible().attention == [codex.id])
        store.acknowledgeAllPanes(in: codex.id)
        store.updatePermissionPromptAttention(sessionID: codex.id, paneID: codex.activePaneID, countDelta: 1, hasPending: true)
        check("permission request lifts", visible().attention == [codex.id])
        store.selectedSessionID = codex.id
        check("selecting preserves permission request", visible().attention == [codex.id] && store.session(id: codex.id)?.layout.pane(id: codex.activePaneID)?.attentionReason == .permissionPrompt)
        store.updatePermissionPromptAttention(sessionID: codex.id, paneID: codex.activePaneID, countDelta: 0, hasPending: false)
        store.acknowledgeAllPanes(in: codex.id)
        store.selectedSessionID = home.id
        check("resolved permission returns to group", visible().attention.isEmpty)
        event(.stop, session: claude, source: .claudeCode)
        check("Claude bare stop remains unlifted", !visible().attention.contains(claude.id))
        let split = store.splitActivePane(orientation: .horizontal, in: codex.id)!
        event(.stop, session: codex, pane: split)
        check("split pane completion lifts workspace once", visible().attention == [codex.id])
        store.needsInputSectionEnabled = false
        check("disable restores original order", visible().attention.isEmpty && visible().rest == [home.id, codex.id, claude.id])
        store.needsInputSectionEnabled = true
        store.acknowledgeAllPanes(in: codex.id)
        check("explicit clear removes split completion", visible().attention.isEmpty)
        let ended = TerminalSession(title: "Ended", workingDirectory: "/tmp", agentKind: .codex, agentExecutionState: .done, attentionReason: .bell)
        let endedStore = SessionStore(groups: [SessionGroup(name: "Ended", sessions: [ended])])
        endedStore.needsInputSectionEnabled = true
        check("hidden low-priority reason does not lift", ended.effectiveChromeState != .needsAttention && endedStore.liftedSessionIDs.isEmpty)
        for replacementID: String? in ["replacement", nil] {
            let prior = TerminalSession(title: "Prior", workingDirectory: "/tmp", agentKind: .claudeCode)
            let lifecycleStore = SessionStore(groups: [SessionGroup(name: "Lifecycle", sessions: [home, prior])], selectedSessionID: home.id)
            lifecycleStore.needsInputSectionEnabled = true
            func applyLifecycle(_ phase: AgentRuntimePhase, id: String?, execution: AgentExecutionState, eventID: String? = nil) {
                check("lifecycle event accepted: \(phase)", lifecycleStore.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .claudeCode, executionState: execution, phase: phase, eventID: eventID, providerSessionID: id), to: prior.id, paneID: prior.activePaneID))
            }
            applyLifecycle(.sessionStart, id: "parent", execution: .running)
            applyLifecycle(.notification, id: "parent", execution: .waiting)
            check("prior lifecycle completed turn lifts", lifecycleStore.liftedSessionIDs == [prior.id])
            applyLifecycle(.toolStart, id: "parent", execution: .running, eventID: "parent-tool")
            applyLifecycle(.sessionStart, id: "nested-child", execution: .running)
            check("nested child preserves parent unanswered turn", lifecycleStore.liftedSessionIDs == [prior.id] && lifecycleStore.agentProviderSessionID(for: prior.activePaneID) == "parent")
            applyLifecycle(.stop, id: "parent", execution: .waiting, eventID: "parent-stop")
            applyLifecycle(.sessionStart, id: replacementID, execution: .running)
            check("replacement lifecycle clears old completion (\(replacementID ?? "no ID"))", lifecycleStore.liftedSessionIDs.isEmpty && lifecycleStore.unansweredTurnPaneIDs.isEmpty && lifecycleStore.session(id: prior.id)?.activePane?.attentionReason == nil)
        }
        let late = TerminalSession(title: "Late Stop", workingDirectory: "/tmp", agentKind: .codex)
        let lateStore = SessionStore(groups: [SessionGroup(name: "Late", sessions: [home, late])], selectedSessionID: home.id)
        lateStore.needsInputSectionEnabled = true
        for phase: AgentRuntimePhase in [.sessionStart, .sessionEnd, .stop] {
            check("late lifecycle event accepted: \(phase)", lateStore.applyAgentRuntimeEvent(AgentRuntimeEvent(source: .codex, executionState: phase == .sessionStart ? .running : .waiting, phase: phase, providerSessionID: "ended"), to: late.id, paneID: late.activePaneID))
        }
        check("timestamp-less Stop after SessionEnd stays unlifted", lateStore.liftedSessionIDs.isEmpty && lateStore.unansweredTurnPaneIDs.isEmpty)
        let report: [String: Any] = ["scope": "public SessionStore through real sidebar projections and navigation; no physical UI or hook transport proof", "checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true }]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if checks.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
    }
}
