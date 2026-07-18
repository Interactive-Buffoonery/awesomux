import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite
struct RemoteMarkdownReferenceTests {
    private actor CallCounter {
        private(set) var count = 0

        func record() {
            count += 1
        }
    }

    private actor AsyncGate {
        private var entryCount = 0
        private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false

        func enterAndWait() async {
            entryCount += 1
            let ready = entryWaiters.filter { entryCount >= $0.count }
            entryWaiters.removeAll { entryCount >= $0.count }
            ready.forEach { $0.continuation.resume() }
            guard !isReleased else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitForEntries(_ count: Int) async {
            guard entryCount < count else { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append((count, continuation))
            }
        }

        func release() {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private actor AsyncSignal {
        private var isSignaled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            isSignaled = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }

        func wait() async {
            guard !isSignaled else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private func remotePane(
        target: String = "my-purple",
        title: String = "alice@devbox:/repo",
        remoteHost: String? = "devbox",
        remoteSSHTarget: String? = nil,
        remoteWorkingDirectory: String? = nil
    ) -> TerminalPane {
        TerminalPane(
            title: title,
            workingDirectory: "/local",
            remoteHost: remoteHost,
            remoteSSHTarget: remoteSSHTarget,
            remoteWorkingDirectory: remoteWorkingDirectory,
            liveTerminalTitle: title,
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(parsing: target)!))
        )
    }

    @Test func absoluteRemoteMarkdownUsesDeclaredAlias() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))

        #expect(reference.sshTarget == "my-purple")
        #expect(reference.remotePath == "/repo/README.md")
        #expect(reference.origin == "my-purple:/repo/README.md")
    }

    @Test func declaredUserAndAliasArePassedExactly() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "alice@my-purple")
            ))

        #expect(reference.sshTarget == "alice@my-purple")
    }

    @Test func titleAndSubmittedTargetCannotRetargetDeclaredPane() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(
                    title: "mallory@spoofed:/private",
                    remoteHost: "spoofed",
                    remoteSSHTarget: "submitted-target"
                )
            ))

        #expect(reference.sshTarget == "my-purple")
        #expect(reference.remotePath == "/repo/README.md")
    }

    @Test func localPaneWithRemotePresentationCannotFetch() {
        let pane = TerminalPane(
            title: "alice@devbox:/repo",
            workingDirectory: "/local",
            remoteHost: "devbox",
            remoteSSHTarget: "devbox",
            liveTerminalTitle: "alice@devbox:/repo",
            executionPlan: .local
        )

        #expect(RemoteMarkdownReference.make(payload: "/repo/README.md", pane: pane) == nil)
    }

    @Test func declaredRemoteWorksWithoutObservedHost() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(remoteHost: nil)
            ))

        #expect(reference.sshTarget == "my-purple")
    }

    @Test func absoluteRemoteMarkdownStripsTrailingSentencePeriod() throws {
        #expect(RemoteMarkdownReference.isPotentialPayload("/repo/README.md."))
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md.",
                pane: remotePane()
            ))
        #expect(reference.remotePath == "/repo/README.md")
    }

    @Test func relativeRemoteMarkdownUsesReportedRemoteDirectory() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "docs/plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ))

        #expect(reference.remotePath == "~/repo/docs/plan.md")
    }

    @Test func relativeRemoteMarkdownIgnoresTitleDirectory() {
        let pane = remotePane(title: "alice@devbox:~/repo")
        #expect(RemoteMarkdownReference.make(payload: "docs/plan.md", pane: pane) == nil)
    }

    @Test func relativeRemoteMarkdownRejectsInvalidReportedDirectories() {
        for directory in [nil, "repo", "~other/repo", ""] as [String?] {
            #expect(
                RemoteMarkdownReference.make(
                    payload: "docs/plan.md",
                    pane: remotePane(remoteWorkingDirectory: directory)
                ) == nil)
        }
    }

    @Test func relativeRemoteMarkdownNormalizesWithoutEscapingTildeRoot() throws {
        let normalized = try #require(
            RemoteMarkdownReference.make(
                payload: "docs/../plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ))
        #expect(normalized.remotePath == "~/repo/plan.md")

        #expect(
            RemoteMarkdownReference.make(
                payload: "../../plan.md",
                pane: remotePane(remoteWorkingDirectory: "~/repo")
            ) == nil)
    }

    @Test func remoteMarkdownRejectsUnsafeOrUnsupportedPaths() {
        let pane = remotePane()
        #expect(RemoteMarkdownReference.make(payload: "/repo/script.sh", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "/repo/e\u{202E}vil.md", pane: pane) == nil)
        #expect(RemoteMarkdownReference.make(payload: "~other/notes.md", pane: pane) == nil)
    }

    @Test func dashLeadingDeclaredTargetIsRejected() {
        let pane = remotePane(target: "-i@devbox")
        #expect(RemoteMarkdownReference.make(payload: "/repo/README.md", pane: pane) == nil)
    }

    @Test func fileURLPayloadUsesRemotePath() throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "file:///repo/docs/plan.markdown",
                pane: remotePane()
            ))
        #expect(reference.remotePath == "/repo/docs/plan.markdown")
    }

    @Test func cacheIdentitySeparatesHostsAndUsers() throws {
        let fetcher = RemoteMarkdownSnapshotFetcher()
        let hostA = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "host-a")
            ))
        let hostB = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "host-b")
            ))
        let userA = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane(target: "alice@host-a")
            ))

        #expect(fetcher.cacheFileName(for: hostA) != fetcher.cacheFileName(for: hostB))
        #expect(fetcher.cacheFileName(for: hostA) != fetcher.cacheFileName(for: userA))
    }

    @Test func fetchedSnapshotsUsePrivateFilesystemPermissions() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let fetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in Data("private plan".utf8) }
        )

        let snapshot = try #require(await fetcher.fetch(reference))
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: cacheDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: snapshot.fileURL.path
        )

        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func shellSingleQuoteEscapesQuotes() {
        #expect(RemoteMarkdownSnapshotFetcher.shellSingleQuoted("a'b.md") == "'a'\\''b.md'")
    }

    @Test func sshOptionParsingEndsBeforeDestination() throws {
        let arguments = RemoteMarkdownSnapshotFetcher.sshArguments(
            target: "-oProxyCommand=example",
            path: "/repo/README.md"
        )
        let delimiterIndex = try #require(arguments.firstIndex(of: "--"))

        #expect(arguments[delimiterIndex + 1] == "-oProxyCommand=example")
    }

    @Test func markdownInlineCodeStripsBackticks() {
        #expect(RemoteMarkdownSnapshotFetcher.markdownInlineCode("dev:/tmp/a`b.md") == "dev:/tmp/ab.md")
    }

    @Test func failedRefetchPreservesSuccessfulCachedSnapshot() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let successful = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in Data("last successful snapshot".utf8) }
        )
        let failing = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in nil }
        )

        let first = try #require(await successful.fetch(reference))
        let refetched = try #require(await failing.fetch(reference))

        #expect(refetched == first)
        #expect(try Data(contentsOf: refetched.fileURL) == Data("last successful snapshot".utf8))
    }

    @Test func initialFetchFailureStillCreatesFailureSnapshot() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let fetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in nil }
        )

        let snapshot = try #require(await fetcher.fetch(reference))
        let content = try String(contentsOf: snapshot.fileURL, encoding: .utf8)

        #expect(content.contains("# Couldn't fetch remote Markdown"))
    }

    @Test func concurrentFetchesForSameIdentityAreCoalesced() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))
        let counter = CallCounter()
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let operationGate = AsyncGate()
        let coalesced = AsyncSignal()
        let fetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in
                await counter.record()
                await operationGate.enterAndWait()
                return Data("current".utf8)
            },
            onCoalescedFetch: { await coalesced.signal() }
        )

        let first = Task { await fetcher.fetch(reference) }
        await operationGate.waitForEntries(1)
        let second = Task { await fetcher.fetch(reference) }
        await coalesced.wait()
        await operationGate.release()
        let results = await [first.value, second.value]

        #expect(await counter.count == 1)
        #expect(results[0]?.fileURL == results[1]?.fileURL)
        #expect(try Data(contentsOf: #require(results[0]?.fileURL)) == Data("current".utf8))
    }

    @Test func differentCacheDirectoriesDoNotShareInFlightResults() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(
                payload: "/repo/README.md",
                pane: remotePane()
            ))
        let counter = CallCounter()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let operationGate = AsyncGate()
        let first = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: root.appending(path: "first", directoryHint: .isDirectory),
            fetchOverride: { _ in
                await counter.record()
                await operationGate.enterAndWait()
                return Data("first".utf8)
            }
        )
        let second = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: root.appending(path: "second", directoryHint: .isDirectory),
            fetchOverride: { _ in
                await counter.record()
                await operationGate.enterAndWait()
                return Data("second".utf8)
            }
        )

        let firstResult = Task { await first.fetch(reference) }
        let secondResult = Task { await second.fetch(reference) }
        await operationGate.waitForEntries(2)
        await operationGate.release()
        let results = await [firstResult.value, secondResult.value]

        #expect(await counter.count == 2)
        #expect(results[0]?.fileURL.deletingLastPathComponent().lastPathComponent == "first")
        #expect(results[1]?.fileURL.deletingLastPathComponent().lastPathComponent == "second")
    }
}
