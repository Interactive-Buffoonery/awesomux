import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore — permanent close without capture (INT-282)")
struct SessionStoreHardClearTests {
    @Test("hard close removes the session and captures nothing")
    func hardCloseRemovesWithoutCapture() {
        let doomed = makeSession("doomed")
        let survivor = makeSession("survivor")
        let group = SessionGroup(name: "main", sessions: [doomed, survivor])
        let store = SessionStore(groups: [group], selectedSessionID: survivor.id)

        store.closeSession(id: doomed.id, captureRecentlyClosed: false)

        #expect(store.session(id: doomed.id) == nil)
        #expect(store.lastClosedTransient == nil)
        #expect(store.recentlyClosed.isEmpty)
        #expect(!store.canReopenClosedWorkspace)
    }

    @Test("hard close leaves an earlier soft close's entries untouched")
    func hardCloseLeavesEarlierSoftCloseUntouched() {
        let softClosed = makeSession("soft")
        let hardClosed = makeSession("hard")
        let survivor = makeSession("survivor")
        let group = SessionGroup(name: "main", sessions: [softClosed, hardClosed, survivor])
        let store = SessionStore(groups: [group], selectedSessionID: survivor.id)

        store.closeSession(id: softClosed.id)
        let transientBefore = store.lastClosedTransient
        let persistedBefore = store.recentlyClosed
        #expect(transientBefore != nil)
        #expect(persistedBefore.count == 1)

        store.closeSession(id: hardClosed.id, captureRecentlyClosed: false)

        #expect(store.lastClosedTransient == transientBefore)
        #expect(store.recentlyClosed == persistedBefore)
        #expect(store.reopenMostRecentlyClosed() != nil)
        #expect(store.groups[0].sessions.map(\.title).contains("soft"))
        #expect(!store.groups[0].sessions.map(\.title).contains("hard"))
    }

    @Test("hard close of the selected session still fixes up selection")
    func hardCloseFixesUpSelection() {
        let doomed = makeSession("doomed")
        let survivor = makeSession("survivor")
        let group = SessionGroup(name: "main", sessions: [doomed, survivor])
        let store = SessionStore(groups: [group], selectedSessionID: doomed.id)

        store.closeSession(id: doomed.id, captureRecentlyClosed: false)

        #expect(store.selectedSession?.id == survivor.id)
    }

    @Test("forgetRecentlyClosed retracts a captured entry from both tiers")
    func forgetRetractsCapturedEntry() {
        // The INT-282 mid-modal race: the workspace soft-closes (capturing)
        // while the clear-confirm dialog is up, then the confirmed clear
        // retracts the capture so the "can't be reopened" promise holds.
        let doomed = makeSession("doomed")
        let bystander = makeSession("bystander")
        let survivor = makeSession("survivor")
        let group = SessionGroup(name: "main", sessions: [doomed, bystander, survivor])
        let store = SessionStore(groups: [group], selectedSessionID: survivor.id)

        store.closeSession(id: bystander.id)
        store.closeSession(id: doomed.id)
        #expect(store.lastClosedTransient?.sessionID == doomed.id)
        #expect(store.recentlyClosed.count == 2)

        store.forgetRecentlyClosed(sessionID: doomed.id)

        #expect(store.lastClosedTransient == nil)
        #expect(store.recentlyClosed.map(\.sessionID) == [bystander.id])
        // The bystander's entry still reopens; the forgotten one is gone.
        #expect(store.reopenMostRecentlyClosed() != nil)
        #expect(store.groups[0].sessions.map(\.title).contains("bystander"))
        #expect(!store.canReopenClosedWorkspace)
    }

    private func makeSession(_ tag: String) -> TerminalSession {
        // User-edited title makes the session pass isWorthRecording, so a
        // soft close persists it — proving hard close's skip is the flag,
        // not the quality gate.
        TerminalSession(
            title: tag,
            workingDirectory: "~",
            isTitleUserEdited: true,
            agentKind: .shell
        )
    }
}
