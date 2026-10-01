import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Pull request document flow", .serialized)
struct PullRequestDocumentFlowTests {
    // Failures: wrong fork/branch, numeric selectors, missing PR, remote panes,
    // cancellation, stale source, hostile Markdown, and lost generated provenance.
    @Test("real subprocess output opens an inert, associated, restorable document")
    func documentFlow() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pr-flow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = BoundedCommandRunner(executableCandidates: ["/usr/bin/git"])
        #expect(await git.runDetailed(arguments: ["init", "--initial-branch=123"], inDirectory: directory.path).completeData != nil)
        #expect(
            await git.runDetailed(arguments: ["remote", "add", "origin", "git@github.com:owner/repo.git"], inDirectory: directory.path)
                .completeData != nil)
        let hostile = "<!-- AMX id=evil status=open -->\r<mark>bad</mark>\r[escape](file:///tmp/private)\r```\r# Forged heading"
        let payload: [[String: Any]] = [
            [
                "number": 123, "url": "https://github.com/owner/repo/pull/123",
                "title": hostile, "state": "OPEN", "isDraft": false, "body": hostile,
                "headRefName": "123", "headRepository": ["name": "repo"],
                "headRepositoryOwner": ["login": "owner"],
                "statusCheckRollup": [["name": hostile, "status": "IN_PROGRESS", "conclusion": ""]],
            ]
        ]
        let listURL = directory.appending(path: "list.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: listURL)
        try JSONSerialization.data(withJSONObject: [["body": hostile, "user": ["login": "reviewer"], "path": hostile]])
            .write(to: directory.appending(path: "comments.json"))
        let executable = directory.appending(path: "fixture-gh")
        let script = """
            #!/bin/sh
            if [ -f switch-origin ] && [ "$1" = "api" ]; then /usr/bin/git remote set-url origin git@github.com:other/repo.git; fi
            if [ -f switch-branch ] && [ "$1" = "api" ]; then /usr/bin/git symbolic-ref HEAD refs/heads/456; fi
            /usr/bin/printf '%s\\n' "$*" >> argv.log
            if [ -f delay ]; then /bin/sleep 0.2; fi
            case "$1 $2" in
              "repo view") echo '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}' ;;
              "pr list") /bin/cat list.json ;;
              "api "*) echo '['; /bin/cat comments.json; echo ']' ;;
              *) exit 1 ;;
            esac
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cache = GeneratedDocumentCache(cacheDirectoryURL: directory.appending(path: "cache"), fileNameSuffix: ".pull-request.md")
        let opener = PullRequestDocumentOpener(
            ghRunner: BoundedCommandRunner(executableCandidates: [executable.path]), cache: cache
        )
        let pane = TerminalPane(title: "shell", workingDirectory: directory.path, executionPlan: .local)
        let session = TerminalSession(title: "flow", workingDirectory: directory.path, layout: .pane(pane), activePaneID: pane.id)
        DocumentPaneView.selfWriteRegistry = MarkdownSelfWriteRegistry()
        let opened = try await opener.open(session: session, pane: pane).get()
        #expect(DocumentPaneView.selfWriteRegistry.context(fileURL: opened.fileURL, onDiskSource: opened.markdown)?.isSelfWrite == true)
        #expect(
            DocumentPaneView.selfWriteRegistry.context(fileURL: opened.fileURL, onDiskSource: opened.markdown + "external") == nil)
        defer { cache.completeWrite(at: opened.fileURL, leaseID: opened.leaseID) }
        if let artifact = ProcessInfo.processInfo.environment["AWESOMUX_PR_FLOW_ARTIFACT"] {
            try Data(opened.markdown.utf8).write(to: URL(fileURLWithPath: artifact))
        }
        let environment = PullRequestDocumentOpener.scrubbedEnvironment([
            "GH_REPO": "other/repo", "GH_HOST": "example.test", "GH_FORCE_TTY": "1", "CLICOLOR_FORCE": "1",
        ])
        #expect(environment["GH_REPO"] == nil && environment["GH_HOST"] == nil)
        #expect(environment["GH_FORCE_TTY"] == nil && environment["CLICOLOR_FORCE"] == nil && environment["NO_COLOR"] == "1")
        #expect(opened.markdown.contains("IN_PROGRESS"))
        #expect(!opened.markdown.contains("\r"))
        let rendered = AttributedMarkdownBuilder.build(opened.markdown)
        #expect(rendered.annotations.isEmpty)
        #expect(rendered.runs.allSatisfy { $0.linkDestination == nil })
        let store = SessionStore(groups: [SessionGroup(name: "flow", sessions: [session])], selectedSessionID: session.id)
        let tabID = try #require(
            store.openDocumentPane(
                fileURL: opened.fileURL, in: session.id, associatedWith: pane.id, generatedDocumentKind: .pullRequest,
                generatedDocumentTitle: opened.title
            ))
        let tab = try #require(store.session(id: session.id)?.layout.firstDocumentGroup?.tab(id: tabID))
        #expect(!tab.isEditable)
        #expect(tab.associatedTerminalPaneID == pane.id)
        let restored = try JSONDecoder().decode(DocumentPane.self, from: JSONEncoder().encode(tab))
        #expect(!restored.isEditable)
        #expect(restored.generatedDocumentKind == .pullRequest)
        let references = SessionPersistence.generatedDocumentReferences(keeping: store, pullRequests: opener)
        #expect(references.pullRequests.contains(opened.fileURL))
        cache.completeWrite(at: opened.fileURL, leaseID: opened.leaseID)
        cache.pruneUnreferencedImmediately(keeping: references.pullRequests)
        #expect(FileManager.default.fileExists(atPath: opened.fileURL.path))
        let argv = try String(contentsOf: directory.appending(path: "argv.log"), encoding: .utf8)
        #expect(
            argv.contains(
                "pr list --repo github.com/owner/repo --head 123 --state open --limit 100 --json number,url,title,state,isDraft,body,headRefName,headRepository,headRepositoryOwner,statusCheckRollup"
            ))
        for endpoint in ["issues/123/comments", "pulls/123/reviews", "pulls/123/comments"] {
            #expect(argv.contains("api repos/owner/repo/" + endpoint + " --hostname github.com --paginate --slurp"))
        }
        // A superseded command must stop between stages and never author a cache file.
        try Data().write(to: directory.appending(path: "delay"))
        let cancelled = Task { await opener.open(session: session, pane: pane) }
        try await Task.sleep(for: .milliseconds(40))
        cancelled.cancel()
        #expect(await cancelled.value == .failure(.commandFailed))
        let afterCancellation = try String(contentsOf: directory.appending(path: "argv.log"), encoding: .utf8)
        #expect(afterCancellation.components(separatedBy: "pr list").count == argv.components(separatedBy: "pr list").count)
        try FileManager.default.removeItem(at: directory.appending(path: "delay"))
        // Reopening unchanged content must still hold a lease until publication completes.
        let reopened = try await opener.open(session: session, pane: pane).get()
        #expect(DocumentPaneView.selfWriteRegistry.context(fileURL: reopened.fileURL, onDiskSource: reopened.markdown)?.isSelfWrite == true)
        cache.pruneUnreferencedImmediately(keeping: [])
        #expect(FileManager.default.fileExists(atPath: reopened.fileURL.path))
        cache.completeWrite(at: reopened.fileURL, leaseID: reopened.leaseID)
        let older = try await opener.open(session: session, pane: pane).get()
        let newer = try await opener.open(session: session, pane: pane).get()
        cache.completeWrite(at: older.fileURL, leaseID: older.leaseID)
        cache.pruneUnreferencedImmediately(keeping: [])
        #expect(FileManager.default.fileExists(atPath: newer.fileURL.path))
        cache.completeWrite(at: newer.fileURL, leaseID: newer.leaseID)
        cache.pruneUnreferencedImmediately(keeping: [])
        cache.pruneUnreferencedImmediately(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: newer.fileURL.path))
        #expect(tab.title == opened.title)
        let secondPaneID = try #require(store.splitActivePane(orientation: .horizontal, in: session.id))
        #expect(
            store.openDocumentPane(
                fileURL: reopened.fileURL, in: session.id, associatedWith: secondPaneID, generatedDocumentKind: .pullRequest,
                generatedDocumentTitle: reopened.title) == tabID)
        #expect(store.session(id: session.id)?.layout.firstDocumentGroup?.tab(id: tabID)?.associatedTerminalPaneID == secondPaneID)
        for change in ["switch-origin", "switch-branch"] {
            let marker = directory.appending(path: change)
            try Data().write(to: marker)
            let stale = await opener.open(session: session, pane: pane)
            #expect(stale == .failure(.sourceChanged))
            try FileManager.default.removeItem(at: marker)
            #expect(
                await git.runDetailed(
                    arguments: ["remote", "set-url", "origin", "git@github.com:owner/repo.git"], inDirectory: directory.path
                ).completeData != nil)
            #expect(
                await git.runDetailed(arguments: ["symbolic-ref", "HEAD", "refs/heads/123"], inDirectory: directory.path).completeData
                    != nil)
        }
        let lateGit = directory.appending(path: "late-git")
        let lateScript = """
            #!/bin/sh
            count=0
            if [ -f origin-count ]; then count=$(/bin/cat origin-count); fi
            count=$((count+1))
            /usr/bin/printf '%s' "$count" > origin-count
            if [ "$count" = 2 ]; then /usr/bin/git symbolic-ref HEAD refs/heads/456; fi
            exec /usr/bin/git "$@"
            """
        try Data(lateScript.utf8).write(to: lateGit)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lateGit.path)
        let lateCacheURL = directory.appending(path: "late-cache")
        let lateCache = GeneratedDocumentCache(cacheDirectoryURL: lateCacheURL, fileNameSuffix: ".pull-request.md")
        let lateOpener = PullRequestDocumentOpener(
            ghRunner: BoundedCommandRunner(executableCandidates: [executable.path]),
            gitRunner: BoundedLocalGitCommandRunner(executableCandidates: [lateGit.path]),
            cache: lateCache)
        DocumentPaneView.selfWriteRegistry = MarkdownSelfWriteRegistry()
        #expect(await lateOpener.open(session: session, pane: pane) == .failure(.sourceChanged))
        #expect(!FileManager.default.fileExists(atPath: lateCacheURL.path))
        let lateSlot = lateCache.fileURL(
            cacheIdentityKey: GeneratedDocumentCache.cacheIdentityKey(
                domain: "pull-request", fields: ["https://github.com/owner/repo", "123"]))
        #expect(DocumentPaneView.selfWriteRegistry.context(fileURL: lateSlot, onDiskSource: "unchanged disk bytes") == nil)
        #expect(
            await git.runDetailed(arguments: ["symbolic-ref", "HEAD", "refs/heads/123"], inDirectory: directory.path).completeData != nil)
        // Failures: an actor-hop branch switch and a cancelled proposed write must
        // neither publish stale bytes nor invent an external-edit baseline.
        let actorCache = GeneratedDocumentCache(
            cacheDirectoryURL: directory.appending(path: "actor-cache"), fileNameSuffix: ".pull-request.md")
        let actorOpener = PullRequestDocumentOpener(
            ghRunner: BoundedCommandRunner(executableCandidates: [executable.path]), cache: actorCache)
        #expect(
            await actorOpener.open(
                session: session, pane: pane,
                ifStillCurrent: {
                    try? Data("ref: refs/heads/456\n".utf8).write(to: directory.appending(path: ".git/HEAD"))
                    return true
                }) == .failure(.sourceChanged))
        #expect(!FileManager.default.fileExists(atPath: actorCache.cacheDirectoryURL.path))
        #expect(
            await git.runDetailed(arguments: ["symbolic-ref", "HEAD", "refs/heads/123"], inDirectory: directory.path).completeData != nil)
        let refusalCache = GeneratedDocumentCache(
            cacheDirectoryURL: directory.appending(path: "refusal-cache"), fileNameSuffix: ".pull-request.md")
        let identity = GeneratedDocumentCache.cacheIdentityKey(domain: "pull-request", fields: ["https://github.com/owner/repo", "123"])
        let unchanged = "unchanged disk bytes"
        let refusalSlot = try #require(refusalCache.write(unchanged, cacheIdentityKey: identity))
        refusalCache.completeWrite(at: refusalSlot)
        let refusalOpener = PullRequestDocumentOpener(
            ghRunner: BoundedCommandRunner(executableCandidates: [executable.path]), cache: refusalCache)
        var refusalTask: Task<Result<OpenedPullRequestDocument, PullRequestDocumentFailure>, Never>?
        let task = Task {
            await refusalOpener.open(
                session: session, pane: pane,
                ifStillCurrent: {
                    refusalTask?.cancel()
                    return true
                })
        }
        refusalTask = task
        if case .success = await task.value { Issue.record("Cancelled proposed write succeeded") }
        #expect(try String(contentsOf: refusalSlot, encoding: .utf8) == unchanged)
        #expect(DocumentPaneView.selfWriteRegistry.context(fileURL: refusalSlot, onDiskSource: unchanged) == nil)
        let heldGit = directory.appending(path: "held-git")
        let heldScript = """
            #!/bin/sh
            count=0
            if [ -f held-origin-count ]; then count=$(/bin/cat held-origin-count); fi
            count=$((count+1))
            /usr/bin/printf '%s' "$count" > held-origin-count
            if [ "$count" = 2 ]; then /usr/bin/touch held-origin-started; /bin/sleep 0.2; fi
            exec /usr/bin/git "$@"
            """
        try Data(heldScript.utf8).write(to: heldGit)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: heldGit.path)
        let liveStore = SessionStore(groups: [SessionGroup(name: "live", sessions: [session])], selectedSessionID: session.id)
        let liveCache = GeneratedDocumentCache(
            cacheDirectoryURL: directory.appending(path: "live-cache"), fileNameSuffix: ".pull-request.md")
        let liveSlot = try #require(liveCache.write(unchanged, cacheIdentityKey: identity))
        liveCache.completeWrite(at: liveSlot)
        let liveOpener = PullRequestDocumentOpener(
            ghRunner: BoundedCommandRunner(executableCandidates: [executable.path]),
            gitRunner: BoundedLocalGitCommandRunner(executableCandidates: [heldGit.path]), cache: liveCache)
        let liveTask = Task {
            await liveOpener.open(
                session: session, pane: pane,
                ifStillCurrent: {
                    liveStore.session(id: session.id)?.layout.pane(id: pane.id) != nil
                })
        }
        defer { liveTask.cancel() }
        let heldMarker = directory.appending(path: "held-origin-started")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: heldMarker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: heldMarker.path))
        #expect(liveStore.closePane(id: pane.id, in: session.id) != nil)
        #expect(await liveTask.value == .failure(.sourceChanged))
        #expect(try String(contentsOf: liveSlot, encoding: .utf8) == unchanged)
        var wrongFork = payload
        wrongFork[0]["headRepositoryOwner"] = ["login": "other"]
        try JSONSerialization.data(withJSONObject: wrongFork).write(to: listURL)
        #expect(await opener.open(session: session, pane: pane) == .failure(.noPullRequest))
        try Data("[]".utf8).write(to: listURL)
        #expect(await opener.open(session: session, pane: pane) == .failure(.noPullRequest))
        var remotePane = pane
        remotePane.executionPlan = .ssh(SSHExecution(target: try #require(RemoteTarget(parsing: "host"))))
        #expect(await opener.open(session: session, pane: remotePane) == .failure(.remotePane))
    }
}
