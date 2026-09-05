import AwesoMuxConfig
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import AwesoMuxCore
@testable import awesoMux

@MainActor
@Suite("Agent transcript completion")
struct AgentTranscriptCompletionTests {
    enum Change: CaseIterable {
        case moved, movedAndOldWorkspaceClosed, closed, workspaceClosed, selectionChanged
    }

    @Test("render completion follows only the initiating pane", arguments: Change.allCases)
    func completionDestination(change: Change) async throws {
        let initiating = TerminalPane(title: "initiating", workingDirectory: "/tmp", executionPlan: .local)
        let sibling = TerminalPane(title: "sibling", workingDirectory: "/tmp", executionPlan: .local)
        let source = TerminalSession(
            title: "source",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical, first: .pane(initiating), second: .pane(sibling)
                )),
            activePaneID: initiating.id
        )
        let unrelated = TerminalSession(title: "unrelated", workingDirectory: "/tmp")
        let store = SessionStore(groups: [SessionGroup(name: "work", sessions: [source, unrelated])])
        let identity = try #require(
            AgentTranscriptIdentity(
                agentKind: .codex, sessionID: "5c4b3a29-1817-4655-9443-2211ffeeddcc"
            ))
        let directory = try TemporaryDirectory(prefix: "transcript-completion")
        defer { withExtendedLifetime(directory) {} }
        let cache = AgentTranscriptStore(cacheDirectoryURL: directory.url.appending(path: "cache"))
        let started = AsyncGate()
        let finishRendering = AsyncGate()
        var completedWrites: [URL] = []
        var pruneCount = 0
        let task = Task { @MainActor in
            started.open()
            await finishRendering.wait()
            let fileURL = try #require(
                cache.write(
                    "# exact transcript", agentKind: identity.agentKind, sessionID: identity.sessionID
                ))
            // Pending writes survive even fresh prunes until completion runs.
            cache.pruneUnreferencedImmediately(keeping: [])
            cache.pruneUnreferencedImmediately(keeping: [])
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            AgentTranscriptCompletion.apply(
                .success(OpenedAgentTranscript(fileURL: fileURL, identity: identity)),
                paneID: initiating.id,
                store: store,
                completeWrite: {
                    completedWrites.append($0)
                    cache.completeWrite(at: $0)
                },
                schedulePrune: { pruneCount += 1 },
                alert: { Issue.record("Unexpected failure: \($0)") }
            )
            return fileURL
        }
        defer { finishRendering.open() }
        await started.wait()
        #expect(finishRendering.waiterCount == 1)
        #expect(store.session(id: source.id)?.layout.firstDocumentGroup == nil)

        var ownerID = source.id
        switch change {
        case .moved, .movedAndOldWorkspaceClosed:
            ownerID = try #require(store.movePaneToNewWorkspace(id: initiating.id, in: source.id))
            if change == .movedAndOldWorkspaceClosed {
                store.closeSession(id: source.id)
            }
        case .closed:
            _ = store.closePane(id: initiating.id, in: source.id)
        case .workspaceClosed:
            store.closeSession(id: source.id)
        case .selectionChanged:
            store.setActivePane(id: sibling.id, in: source.id)
        }
        // A later selection must never become the completion or Resume target.
        store.selectedSessionID = unrelated.id
        finishRendering.open()
        let fileURL = try await task.value
        #expect(completedWrites == [fileURL])
        #expect(pruneCount == 1)
        #expect(store.session(id: unrelated.id)?.layout.firstDocumentGroup == nil)

        if change == .closed || change == .workspaceClosed {
            #expect(store.sessionIDContainingPane(initiating.id) == nil)
            #expect(store.session(id: source.id)?.layout.firstDocumentGroup == nil)
            // Two fresh prunes cross the cache's one-prune retention boundary.
            // An unreleased lease would keep this discarded render forever.
            cache.pruneUnreferencedImmediately(keeping: [])
            cache.pruneUnreferencedImmediately(keeping: [])
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
            return
        }

        if ownerID != source.id {
            #expect(store.session(id: source.id)?.layout.firstDocumentGroup == nil)
        }
        let layout = try #require(store.session(id: ownerID)?.layout)
        let tab = try #require(layout.firstDocumentGroup?.tabs.first)
        #expect(tab.associatedTerminalPaneID == initiating.id)
        #expect(tab.agentTranscriptIdentity == identity)
        #expect(tab.fileURL == fileURL)
        #expect(layout.documentSendTarget(for: tab.id)?.id == initiating.id)

        var sent: [(String, TerminalPane.ID)] = []
        var probed: [TerminalPane.ID] = []
        let outcome = await AgentTranscriptResumeStaging.stage(
            identity: try #require(tab.agentTranscriptIdentity),
            documentID: tab.id,
            layout: layout,
            integrations: AgentIntegrationsConfig(),
            foregroundComm: {
                probed.append($0)
                return "-zsh"
            },
            sendText: {
                sent.append(($0, $1))
                return true
            },
            sessionLogExists: { receivedIdentity, plan, _, _ in
                #expect(receivedIdentity == identity)
                #expect(plan == .local)
                return true
            }
        )
        #expect(outcome == .staged)
        #expect(probed == [initiating.id, initiating.id])
        #expect(sent.count == 1)
        #expect(sent.first?.1 == initiating.id)
        #expect(sent.first?.0 == " codex resume '\(identity.sessionID)'")
        #expect(sent.allSatisfy { !$0.0.contains("\n") && !$0.0.contains("\r") })
    }

    @Test("failed rendering reports failure without finalizing a nonexistent write")
    func failedRender() async {
        let gate = AsyncGate()
        let started = AsyncGate()
        let store = SessionStore(groups: [])
        var failures: [AgentTranscriptOpenFailure] = []
        let task = Task { @MainActor in
            started.open()
            await gate.wait()
            AgentTranscriptCompletion.apply(
                .failure(.cacheWriteFailed),
                paneID: UUID(),
                store: store,
                completeWrite: { _ in Issue.record("No write to complete") },
                schedulePrune: { Issue.record("No write to prune") },
                alert: { failures.append($0) }
            )
        }
        await started.wait()
        gate.open()
        await task.value
        #expect(failures == [.cacheWriteFailed])
    }
}
