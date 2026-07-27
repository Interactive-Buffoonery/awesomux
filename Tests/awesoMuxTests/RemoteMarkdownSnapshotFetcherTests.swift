import Foundation
import Testing
@testable import AwesoMuxCore
@testable import awesoMux

@Suite
struct RemoteMarkdownReferenceTests {
    private enum ExpectationFailure: Error {
        case notAFailureDocument
    }

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

    @Test func relativeRemoteMarkdownStripsSourceLocationSuffixesBeforeSchemeDetection() throws {
        for payload in ["README.md:12", "docs/readme.md:12:5", "docs/readme.md#anchor"] {
            #expect(RemoteMarkdownReference.isPotentialPayload(payload))
        }

        let lineReference = try #require(
            RemoteMarkdownReference.make(
                payload: "README.md:12",
                pane: remotePane(remoteWorkingDirectory: "/srv/project")
            )
        )
        #expect(lineReference.remotePath == "/srv/project/README.md")

        let anchorReference = try #require(
            RemoteMarkdownReference.make(
                payload: "docs/readme.md#anchor",
                pane: remotePane(remoteWorkingDirectory: "/srv/project")
            )
        )
        #expect(anchorReference.remotePath == "/srv/project/docs/readme.md")
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

    /// The slot name must be preimage-resistant, not merely well-distributed:
    /// the remote path arrives in an OSC payload any process in the SSH'd pane
    /// can emit, so an invertible hash lets an attacker aim their content at a
    /// victim path's slot and have it served back as that victim's snapshot.
    /// 64-bit FNV-1a produced a variable-length 16-hex-max digest; this pins the
    /// full 128-bit width a truncated SHA-256 gives.
    @Test func cacheFileNamesUseAWideDigestNotAnInvertibleHash() throws {
        let fetcher = RemoteMarkdownSnapshotFetcher()
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let digest = fetcher.cacheFileName(for: reference).replacingOccurrences(of: ".md", with: "")

        #expect(digest.count == 32, "expected 128 bits of hex, got \(digest)")
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
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
            fetchOverride: { _ in .success(Data("private plan".utf8)) }
        )

        let outcome = try #require(await fetcher.fetch(reference))
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: cacheDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: outcome.snapshot.fileURL.path
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

    /// The remote script and the Swift classifier are one contract. This pins
    /// the shell half to the same symbols the classifier matches, and pins both
    /// clear of the statuses `/bin/sh` and ssh claim for themselves — a remote
    /// with a broken shell must never be reported as a verdict about the file.
    @Test func theRemoteScriptReportsTheSameExitStatusesTheClassifierMatches() {
        let notReadable = RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileNotReadable
        let tooLarge = RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileTooLarge
        let arguments = RemoteMarkdownSnapshotFetcher.sshArguments(
            target: "my-purple",
            path: "/repo/README.md"
        )
        let command = arguments.last ?? ""

        #expect(command.contains("|| exit \(notReadable);"))
        #expect(command.contains("|| exit \(tooLarge);"))
        for reserved: Int32 in [1, 2, 126, 127, 255] {
            #expect(notReadable != reserved)
            #expect(tooLarge != reserved)
        }
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
            fetchOverride: { _ in .success(Data("last successful snapshot".utf8)) }
        )
        let failing = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .nonZeroExit(1) }
        )

        let first = try #require(await successful.fetch(reference))
        let refetched = try #require(await failing.fetch(reference))

        #expect(refetched == .cached(first.snapshot))
        #expect(try Data(contentsOf: refetched.snapshot.fileURL) == Data("last successful snapshot".utf8))
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
            fetchOverride: { _ in .nonZeroExit(1) }
        )

        let outcome = try #require(await fetcher.fetch(reference))
        let content = try String(contentsOf: outcome.snapshot.fileURL, encoding: .utf8)

        #expect(outcome == .failureDocument(outcome.snapshot, reason: .connection))
        #expect(content.contains("# Couldn't fetch remote Markdown"))
    }

    @Test func repeatedFailuresNeverServeTheFailureDocumentAsACachedSnapshot() async throws {
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
            fetchOverride: { _ in .nonZeroExit(1) }
        )

        let first = try #require(await fetcher.fetch(reference))
        let second = try #require(await fetcher.fetch(reference))

        #expect(second == .failureDocument(second.snapshot, reason: .connection))
        #expect(first.snapshot.fileURL == second.snapshot.fileURL)
        #expect(
            second.snapshot.fileURL.lastPathComponent != fetcher.cacheFileName(for: reference)
        )
    }

    /// A cache written by a build that put the failure page at the snapshot path
    /// keeps being served back as a point-in-time copy of the user's file. The
    /// bug can only be observed by seeding that state, not by driving the
    /// current implementation, which never writes there.
    @Test func aLegacyFailurePageSittingAtTheSnapshotPathIsEvictedNotServed() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let fetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .nonZeroExit(1) }
        )
        let poisonedURL = cacheDirectory.appending(path: fetcher.cacheFileName(for: reference))
        try Data(
            """
            # Couldn't fetch remote Markdown

            awesoMux could not read `my-purple:/repo/README.md` using SSH.
            """.utf8
        ).write(to: poisonedURL)

        let outcome = try #require(await fetcher.fetch(reference))

        #expect(outcome == .failureDocument(outcome.snapshot, reason: .connection))
        #expect(outcome.snapshot.fileURL != poisonedURL)
        #expect(!FileManager.default.fileExists(atPath: poisonedURL.path))
    }

    /// A real snapshot must survive the legacy-page sweep: the sniff keys on the
    /// app-authored preamble, so ordinary Markdown that merely mentions the
    /// remote must still be served.
    @Test func aRealCachedSnapshotIsNotMistakenForALegacyFailurePage() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let successful = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .success(Data("# Couldn't fetch remote Markdown, a note about that".utf8)) }
        )
        let failing = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .nonZeroExit(1) }
        )

        let fresh = try #require(await successful.fetch(reference))
        let refetched = try #require(await failing.fetch(reference))

        #expect(refetched == .cached(fresh.snapshot))
    }

    /// The panel's missing multi-call journey: a first fetch fails, a later one
    /// succeeds. The outcome must flip to the snapshot path, and the failure
    /// page it leaves behind must not be reachable as a snapshot.
    @Test func aSuccessfulRefetchAfterAFailureMovesBackToTheSnapshotPath() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let failing = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileNotReadable) }
        )
        let successful = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .success(Data("recovered".utf8)) }
        )

        let failed = try #require(await failing.fetch(reference))
        let recovered = try #require(await successful.fetch(reference))

        #expect(failed == .failureDocument(failed.snapshot, reason: .notFound))
        #expect(recovered == .fresh(recovered.snapshot))
        #expect(recovered.snapshot.fileURL != failed.snapshot.fileURL)
        #expect(recovered.snapshot.fileURL.lastPathComponent == failing.cacheFileName(for: reference))
        #expect(try Data(contentsOf: recovered.snapshot.fileURL) == Data("recovered".utf8))
        // The orphaned failure page stays on disk until the prune sweep runs,
        // but it is at a name `cachedSnapshot` never looks up, so it can never
        // be served as the user's file.
        #expect(FileManager.default.fileExists(atPath: failed.snapshot.fileURL.path))
    }

    @Test func oversizeExitCodeExplainsTheSizeCapInsteadOfConnectivity() async throws {
        let (content, reason) = try await failureDocument(
            for: .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileTooLarge)
        )

        #expect(reason == .oversize)
        #expect(content.contains("# Remote Markdown is too large"))
        #expect(content.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB size limit"))
        #expect(!content.contains("host is reachable"))
    }

    /// Exit 1 and 2 are what a broken remote shell reports for its own syntax
    /// and startup failures, so neither may be read as a verdict about the file.
    @Test(
        "shell-reserved exit statuses stay connection failures",
        arguments: [Int32(1), 2, 126, 127, 255])
    func shellReservedExitStatusesAreNotFileVerdicts(status: Int32) async throws {
        let (content, reason) = try await failureDocument(for: .nonZeroExit(status))

        #expect(reason == .connection)
        #expect(content.contains("# Couldn't fetch remote Markdown"))
    }

    /// `exit RemoteReadExit.fileNotReadable` is reached only after ssh connected
    /// and a remote shell ran — ssh reports its own connection failures as 255 —
    /// so blaming the network here sends the reader to fix the wrong thing.
    @Test func aMissingRemoteFileNamesTheFileNotTheNetwork() async throws {
        let (content, reason) = try await failureDocument(
            for: .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileNotReadable)
        )

        #expect(reason == .notFound)
        #expect(content.contains("# Remote Markdown file not found"))
        #expect(content.contains("Check that the file still exists at that path"))
        #expect(!content.contains("host is reachable"))
    }

    @Test func truncatedOutputIsTreatedAsOversizeNotAConnectionFailure() async throws {
        let (content, reason) = try await failureDocument(
            for: .outputTruncated(Data(repeating: 0x23, count: 8))
        )

        #expect(reason == .oversize)
        #expect(content.contains("# Remote Markdown is too large"))
        #expect(content.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB size limit"))
    }

    /// The runner classifies timeout ahead of truncation, so a read that blew
    /// the cap and then missed the deadline arrives as `.timedOut`. The cap
    /// breach is still proven, and it is the answer the reader needs.
    @Test func aTimeoutThatAlreadyBreachedTheCapIsOversizeNotConnectivity() async throws {
        let (content, reason) = try await failureDocument(for: .timedOut(outputTruncated: true))

        #expect(reason == .oversize)
        #expect(content.contains("# Remote Markdown is too large"))
    }

    @Test func aTimeoutWithoutACapBreachStaysAConnectionFailure() async throws {
        let (content, reason) = try await failureDocument(for: .timedOut(outputTruncated: false))

        #expect(reason == .connection)
        #expect(content.contains("# Couldn't fetch remote Markdown"))
    }

    @Test func cleanReadOverTheCapIsTreatedAsOversize() async throws {
        let (content, reason) = try await failureDocument(
            for: .success(
                Data(repeating: 0x23, count: DocumentURLValidator.maxFileSizeBytes + 1)
            )
        )

        #expect(reason == .oversize)
        #expect(content.contains("# Remote Markdown is too large"))
    }

    private func failureDocument(
        for result: BoundedCommandResult
    ) async throws -> (content: String, reason: RemoteMarkdownFailureReason) {
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
            fetchOverride: { _ in result }
        )

        let outcome = try #require(await fetcher.fetch(reference))
        guard case .failureDocument(let snapshot, let reason) = outcome else {
            Issue.record("Expected a failure document, got \(outcome)")
            throw ExpectationFailure.notAFailureDocument
        }
        let content = try String(contentsOf: snapshot.fileURL, encoding: .utf8)
        // Catches a literal that carries a `%arg` marker of its own, nothing
        // more. It is NOT catalog coverage: the catalog is not a declared
        // SwiftPM resource, so under `swift test` `String(localized:)` always
        // formats the literal and this would pass with the catalog entry
        // correct, malformed, or missing. `RemoteMarkdownLocalizationCatalogTests`
        // is what actually checks the catalog.
        #expect(!content.contains("%arg"), "a source literal carried a placeholder marker: \(content)")
        #expect(content.contains("README.md"), "the page should name the file it is about: \(content)")
        // The code span around the origin is the seal on an attacker-influenced
        // value; `markdownInlineCode` only strips backticks, so an unbalanced
        // pair would let bracket/paren syntax through as a live link.
        #expect(
            content.contains("`my-purple:/repo/README.md`"),
            "the origin must reach the page inside a balanced code span: \(content)")
        return (content, reason)
    }

    @Test func symlinkedCacheRootRejectsCachedReuseAndWrites() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = root.appending(path: "destination", directoryHint: .isDirectory)
        let cacheDirectory = root.appending(path: "remote-markdown", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cacheDirectory, withDestinationURL: destination)
        let seededFetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: destination,
            fetchOverride: { _ in .success(Data("seeded".utf8)) }
        )
        let seeded = try #require(await seededFetcher.fetch(reference))
        let seededURL = seeded.snapshot.fileURL
        #expect(FileManager.default.fileExists(atPath: seededURL.path))

        let failed = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .nonZeroExit(1) }
        )
        let successful = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in .success(Data("replacement".utf8)) }
        )

        #expect(await failed.fetch(reference) == nil)
        #expect(await successful.fetch(reference) == nil)
        #expect(try Data(contentsOf: seededURL) != Data("replacement".utf8))
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
                return .success(Data("current".utf8))
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
        #expect(results[0]?.snapshot.fileURL == results[1]?.snapshot.fileURL)
        #expect(try Data(contentsOf: #require(results[0]?.snapshot.fileURL)) == Data("current".utf8))
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
                return .success(Data("first".utf8))
            }
        )
        let second = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: root.appending(path: "second", directoryHint: .isDirectory),
            fetchOverride: { _ in
                await counter.record()
                await operationGate.enterAndWait()
                return .success(Data("second".utf8))
            }
        )

        let firstResult = Task { await first.fetch(reference) }
        let secondResult = Task { await second.fetch(reference) }
        await operationGate.waitForEntries(2)
        await operationGate.release()
        let results = await [firstResult.value, secondResult.value]

        #expect(await counter.count == 2)
        #expect(results[0]?.snapshot.fileURL.deletingLastPathComponent().lastPathComponent == "first")
        #expect(results[1]?.snapshot.fileURL.deletingLastPathComponent().lastPathComponent == "second")
    }
}

/// `Resources/Localizable.xcstrings` is not a declared SwiftPM resource
/// (`Package.swift` bundles only `Resources/Fonts`); `build_and_run.sh` compiles
/// it into the `.app`. Under `swift test` there is therefore no catalog to miss,
/// so `String(localized:)` always falls back to formatting the literal — which
/// makes any assertion on the *rendered* string pass whether the catalog entry
/// is correct, malformed, or absent entirely.
///
/// This checks the thing that assertion cannot: every localized literal in the
/// remote-Markdown sources has a matching key in the catalog the shipped app
/// actually loads. It reads the source rather than a hand-copied list so a
/// literal added later is covered without anyone remembering to add it here.
@Suite("Remote Markdown localization catalog coverage")
struct RemoteMarkdownLocalizationCatalogTests {

    @Test(
        arguments: [
            "Sources/awesoMux/Services/RemoteMarkdownSnapshotFetcher.swift"
        ])
    func everyLocalizedLiteralInTheSourceIsACatalogKey(relativePath: String) throws {
        let keys = try AwesoMuxStringCatalog.keys()
        let literals = try AwesoMuxStringCatalog.localizedLiterals(in: relativePath)

        #expect(!literals.isEmpty, "found no localized literals in \(relativePath) — parser drift?")
        for literal in literals {
            #expect(
                keys.contains(literal),
                "\(relativePath) localizes \"\(literal)\" but Localizable.xcstrings has no such key")
        }
    }

    /// Listed explicitly: the announcer file localizes far more than the remote
    /// Markdown outcomes, and these are the ones this surface owns. All four
    /// pre-existing entries were absent from the catalog when this check was
    /// written — `String(localized:)` falls back to the literal, so they shipped
    /// readable in English and untranslatable everywhere else, with nothing to
    /// notice.
    @Test func theOutcomeAnnouncementsAreCatalogKeys() throws {
        let keys = try AwesoMuxStringCatalog.keys()

        for literal in [
            "Loading remote Markdown.",
            "Remote Markdown loaded.",
            "Remote Markdown refresh failed. Showing the saved cached copy, which may be stale.",
            "Remote Markdown fetch failed. Opening the failure document.",
            "Remote Markdown is too large to open. Opening an explanation instead.",
            "Remote Markdown file not found on the host. Opening an explanation instead.",
        ] {
            #expect(keys.contains(literal), "Localizable.xcstrings has no key \"\(literal)\"")
        }
    }
}
