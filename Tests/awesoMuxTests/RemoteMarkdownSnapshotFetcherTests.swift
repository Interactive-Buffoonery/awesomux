import AwesoMuxTestSupport
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
        private var entryWaiters: [(count: Int, continuation: SignalResumer)] = []
        private var releaseWaiters: [SignalResumer] = []
        private var isReleased = false

        func enterAndWait() async {
            entryCount += 1
            let ready = entryWaiters.filter { entryCount >= $0.count }
            entryWaiters.removeAll { entryCount >= $0.count }
            ready.forEach { $0.continuation.resume() }
            guard !isReleased else { return }
            await awaitSignal { releaseWaiters.append($0) }
        }

        func waitForEntries(_ count: Int) async {
            guard entryCount < count else { return }
            await awaitSignal { continuation in
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
        private var waiters: [SignalResumer] = []

        func signal() {
            isSignaled = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }

        func wait() async {
            guard !isSignaled else { return }
            await awaitSignal { waiters.append($0) }
        }

        func wasSignaled() -> Bool {
            isSignaled
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

    @Test(
        "payload paths require a safe remote directory and supported normalized path",
        arguments: [
            "absoluteRemoteMarkdownStripsTrailingSentencePeriod", "relativeRemoteMarkdownUsesReportedRemoteDirectory",
            "relativeRemoteMarkdownStripsSourceLocationSuffixesBeforeSchemeDetection", "relativeRemoteMarkdownIgnoresTitleDirectory",
            "relativeRemoteMarkdownRejectsInvalidReportedDirectories", "relativeRemoteMarkdownNormalizesWithoutEscapingTildeRoot",
            "remoteMarkdownRejectsUnsafeOrUnsupportedPaths", "fileURLPayloadUsesRemotePath",
        ])
    func payloadPathGate(scenario: String) async throws {
        switch scenario {
        case "absoluteRemoteMarkdownStripsTrailingSentencePeriod":
            #expect(RemoteMarkdownReference.isPotentialPayload("/repo/README.md."))
            let reference = try #require(
                RemoteMarkdownReference.make(
                    payload: "/repo/README.md.",
                    pane: remotePane()
                ))
            #expect(reference.remotePath == "/repo/README.md")
        case "relativeRemoteMarkdownUsesReportedRemoteDirectory":
            let reference = try #require(
                RemoteMarkdownReference.make(
                    payload: "docs/plan.md",
                    pane: remotePane(remoteWorkingDirectory: "~/repo")
                ))

            #expect(reference.remotePath == "~/repo/docs/plan.md")
        case "relativeRemoteMarkdownStripsSourceLocationSuffixesBeforeSchemeDetection":
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
        case "relativeRemoteMarkdownIgnoresTitleDirectory":
            let pane = remotePane(title: "alice@devbox:~/repo")
            #expect(RemoteMarkdownReference.make(payload: "docs/plan.md", pane: pane) == nil)
        case "relativeRemoteMarkdownRejectsInvalidReportedDirectories":
            for directory in [nil, "repo", "~other/repo", ""] as [String?] {
                #expect(
                    RemoteMarkdownReference.make(
                        payload: "docs/plan.md",
                        pane: remotePane(remoteWorkingDirectory: directory)
                    ) == nil)
            }
        case "relativeRemoteMarkdownNormalizesWithoutEscapingTildeRoot":
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
        case "remoteMarkdownRejectsUnsafeOrUnsupportedPaths":
            let pane = remotePane()
            #expect(RemoteMarkdownReference.make(payload: "/repo/script.sh", pane: pane) == nil)
            #expect(RemoteMarkdownReference.make(payload: "/repo/e\u{202E}vil.md", pane: pane) == nil)
            #expect(RemoteMarkdownReference.make(payload: "~other/notes.md", pane: pane) == nil)
        case "fileURLPayloadUsesRemotePath":
            let reference = try #require(
                RemoteMarkdownReference.make(
                    payload: "file:///repo/docs/plan.markdown",
                    pane: remotePane()
                ))
            #expect(reference.remotePath == "/repo/docs/plan.markdown")
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    @Test(
        "document destinations stay within the source directory",
        arguments: [
            "markdownDestinationResolvesAgainstSourceDocumentDirectory", "markdownDestinationCannotEscapeSourceDirectory",
            "markdownDestinationRejectsQueryAndSupportsTildeSource",
        ])
    func destinations(scenario: String) async throws {
        switch scenario {
        case "markdownDestinationResolvesAgainstSourceDocumentDirectory":
            let source = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "my-purple")!),
                path: ResourcePath(rawValue: "/repo/docs/README.md")
            )
            let reference = try #require(
                RemoteMarkdownReference.make(
                    markdownDestination: "guide.md#install",
                    relativeTo: source
                )
            )
            #expect(reference.remotePath == "/repo/docs/guide.md")
            #expect(reference.sshTarget == "my-purple")
            #expect(reference.identity.location == source.location)
        case "markdownDestinationCannotEscapeSourceDirectory":
            let source = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "my-purple")!),
                path: ResourcePath(rawValue: "/repo/docs/README.md")
            )
            #expect(
                RemoteMarkdownReference.make(
                    markdownDestination: "../secret.md",
                    relativeTo: source
                ) == nil
            )
        case "markdownDestinationRejectsQueryAndSupportsTildeSource":
            let source = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "alice@my-purple")!),
                path: ResourcePath(rawValue: "~/repo/docs/README.md")
            )
            #expect(
                RemoteMarkdownReference.make(
                    markdownDestination: "guide.md?raw=1",
                    relativeTo: source
                ) == nil
            )
            let reference = try #require(
                RemoteMarkdownReference.make(
                    markdownDestination: "guide.md",
                    relativeTo: source
                )
            )
            #expect(reference.remotePath == "~/repo/docs/guide.md")
            #expect(reference.sshTarget == "alice@my-purple")

            let link = try #require(
                RemoteMarkdownReference.linkURL(
                    forMarkdownDestination: "guide.md",
                    relativeTo: source
                )
            )
            #expect(link.scheme == RemoteMarkdownReference.remoteMarkdownLinkScheme)

            let reopened = try #require(
                RemoteMarkdownReference.make(openedLinkURL: link, relativeTo: source)
            )
            #expect(reopened.remotePath == "~/repo/docs/guide.md")
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    @Test(
        "opened links normalize containment and round trip remote identities",
        arguments: [
            "openedLinkURLAcceptsContainedAbsolutePath", "openedLinkURLRejectsCraftedParentTraversalUnderPrefix",
        ])
    func openedLinks(scenario: String) async throws {
        switch scenario {
        case "openedLinkURLAcceptsContainedAbsolutePath":
            let source = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "my-purple")!),
                path: ResourcePath(rawValue: "/repo/docs/README.md")
            )
            let link = URL(fileURLWithPath: "/repo/docs/sibling.md")
            let reference = try #require(
                RemoteMarkdownReference.make(openedLinkURL: link, relativeTo: source)
            )
            #expect(reference.remotePath == "/repo/docs/sibling.md")
            #expect(reference.sshTarget == "my-purple")
        case "openedLinkURLRejectsCraftedParentTraversalUnderPrefix":
            let absoluteSource = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "my-purple")!),
                path: ResourcePath(rawValue: "/repo/docs/README.md")
            )
            let tildeSource = ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "my-purple")!),
                path: ResourcePath(rawValue: "~/repo/docs/README.md")
            )

            // Raw prefix would match `…/docs/../secret.md`; normalize must collapse
            // first so containment sees `/repo/secret.md` / `~/repo/secret.md`.
            let craftedFile = try #require(URL(string: "file:///repo/docs/../secret.md"))
            #expect(
                RemoteMarkdownReference.make(
                    openedLinkURL: craftedFile,
                    relativeTo: absoluteSource
                ) == nil
            )

            var tildeComponents = URLComponents()
            tildeComponents.scheme = RemoteMarkdownReference.remoteMarkdownLinkScheme
            tildeComponents.percentEncodedPath = "/~/repo/docs/../secret.md"
            let craftedTilde = try #require(tildeComponents.url)
            #expect(
                RemoteMarkdownReference.make(
                    openedLinkURL: craftedTilde,
                    relativeTo: tildeSource
                ) == nil
            )

            // Contained normalization after the same walk still opens.
            let containedFile = try #require(URL(string: "file:///repo/docs/nested/../sibling.md"))
            let contained = try #require(
                RemoteMarkdownReference.make(
                    openedLinkURL: containedFile,
                    relativeTo: absoluteSource
                )
            )
            #expect(contained.remotePath == "/repo/docs/sibling.md")
        default: Issue.record("Unknown scenario: \(scenario)")
        }
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

    @Test(
        "SSH argv separates the target and quotes remote paths",
        arguments: ["shellSingleQuoteEscapesQuotes", "sshOptionParsingEndsBeforeDestination"])
    func argvInjection(scenario: String) async throws {
        switch scenario {
        case "shellSingleQuoteEscapesQuotes":
            #expect(RemoteMarkdownSnapshotFetcher.shellSingleQuoted("a'b.md") == "'a'\\''b.md'")
        case "sshOptionParsingEndsBeforeDestination":
            let arguments = RemoteMarkdownSnapshotFetcher.sshArguments(
                target: "-oProxyCommand=example",
                path: "/repo/README.md"
            )
            let delimiterIndex = try #require(arguments.firstIndex(of: "--"))

            #expect(arguments[delimiterIndex + 1] == "-oProxyCommand=example")
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    /// The remote script and the Swift classifier are one contract. This pins
    /// the shell half to the same symbols the classifier matches, and pins both
    /// clear of the statuses `/bin/sh` and ssh claim for themselves — a remote
    /// with a broken shell must never be reported as a verdict about the file.

    @Test(
        "failed refetches preserve snapshot bytes and the distinct stale reason",
        arguments: ["failedRefetchPreservesSuccessfulCachedSnapshot", "anOverCapRefetchReportsWhyTheCachedCopyIsStale"])
    func staleCache(scenario: String) async throws {
        switch scenario {
        case "failedRefetchPreservesSuccessfulCachedSnapshot":
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

            #expect(refetched == .cached(first.snapshot, staleReason: .connection))
            #expect(try Data(contentsOf: refetched.snapshot.fileURL) == Data("last successful snapshot".utf8))
        case "anOverCapRefetchReportsWhyTheCachedCopyIsStale":
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
                fetchOverride: { _ in .success(Data("the copy that fit".utf8)) }
            )
            let overCap = RemoteMarkdownSnapshotFetcher(
                cacheDirectoryURL: cacheDirectory,
                fetchOverride: { _ in
                    .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileTooLarge)
                }
            )

            let first = try #require(await successful.fetch(reference))
            let refetched = try #require(await overCap.fetch(reference))

            #expect(refetched == .cached(first.snapshot, staleReason: .oversize))
            // The retained content is the point — an explanation must not have
            // replaced it.
            #expect(try Data(contentsOf: refetched.snapshot.fileURL) == Data("the copy that fit".utf8))
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    /// The journey PR #254 left open: a file caches successfully, the remote
    /// then grows past the cap, and the refetch serves the stale copy. The
    /// content is still the right thing to serve — losing it to a failure page
    /// would be worse — but the caller has to be able to tell this apart from a
    /// healthy cache hit, or the user reads a stale document with no signal.
    ///
    /// The whole outcome is compared rather than just the reason: `.cached`
    /// carrying the wrong snapshot would be a far worse bug than carrying the
    /// wrong reason, and asserting only the reason would not see it.

    @Test(
        "failure pages stay separate from recovered snapshots",
        arguments: [
            "initialFetchFailureStillCreatesFailureSnapshot", "repeatedFailuresNeverServeTheFailureDocumentAsACachedSnapshot",
            "aSuccessfulRefetchAfterAFailureMovesBackToTheSnapshotPath",
        ])
    func failureRecovery(scenario: String) async throws {
        switch scenario {
        case "initialFetchFailureStillCreatesFailureSnapshot":
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
        case "repeatedFailuresNeverServeTheFailureDocumentAsACachedSnapshot":
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
        case "aSuccessfulRefetchAfterAFailureMovesBackToTheSnapshotPath":
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
        default: Issue.record("Unknown scenario: \(scenario)")
        }
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
        // 0o700: production only ever creates this cache through
        // `validatedOwnerOnlyDirectory`, and the read-only paths refuse a
        // directory left group- or world-readable.
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
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

        #expect(refetched == .cached(fresh.snapshot, staleReason: .connection))
    }

    /// The panel's missing multi-call journey: a first fetch fails, a later one
    /// succeeds. The outcome must flip to the snapshot path, and the failure
    /// page it leaves behind must not be reachable as a snapshot.

    @Test(
        "read failures distinguish file verdicts, cap breaches, and connectivity",
        arguments: [
            "oversizeExitCodeExplainsTheSizeCapInsteadOfConnectivity", "shellReservedExitStatusesAreNotFileVerdicts",
            "aMissingRemoteFileNamesTheFileNotTheNetwork", "truncatedOutputIsTreatedAsOversizeNotAConnectionFailure",
            "aTimeoutThatAlreadyBreachedTheCapIsOversizeNotConnectivity", "aTimeoutWithoutACapBreachStaysAConnectionFailure",
            "cleanReadOverTheCapIsTreatedAsOversize",
        ])
    func exitStatusReasons(scenario: String) async throws {
        switch scenario {
        case "oversizeExitCodeExplainsTheSizeCapInsteadOfConnectivity":
            let (content, reason) = try await failureDocument(
                for: .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileTooLarge)
            )

            #expect(reason == .oversize)
            #expect(content.contains("# Remote Markdown is too large"))
            #expect(content.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB size limit"))
            #expect(!content.contains("host is reachable"))
        case "shellReservedExitStatusesAreNotFileVerdicts":
            for status: Int32 in [1, 2, 126, 127, 255] {
                let (content, reason) = try await failureDocument(for: .nonZeroExit(status))

                #expect(reason == .connection)
                #expect(content.contains("# Couldn't fetch remote Markdown"))
            }
        case "aMissingRemoteFileNamesTheFileNotTheNetwork":
            let (content, reason) = try await failureDocument(
                for: .nonZeroExit(RemoteMarkdownSnapshotFetcher.RemoteReadExit.fileNotReadable)
            )

            #expect(reason == .notFound)
            #expect(content.contains("# Remote Markdown file not found"))
            #expect(content.contains("Check that the file still exists at that path"))
            #expect(!content.contains("host is reachable"))
        case "truncatedOutputIsTreatedAsOversizeNotAConnectionFailure":
            let (content, reason) = try await failureDocument(
                for: .outputTruncated(Data(repeating: 0x23, count: 8))
            )

            #expect(reason == .oversize)
            #expect(content.contains("# Remote Markdown is too large"))
            #expect(content.contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB size limit"))
        case "aTimeoutThatAlreadyBreachedTheCapIsOversizeNotConnectivity":
            let (content, reason) = try await failureDocument(for: .timedOut(outputTruncated: true))

            #expect(reason == .oversize)
            #expect(content.contains("# Remote Markdown is too large"))
        case "aTimeoutWithoutACapBreachStaysAConnectionFailure":
            let (content, reason) = try await failureDocument(for: .timedOut(outputTruncated: false))

            #expect(reason == .connection)
            #expect(content.contains("# Couldn't fetch remote Markdown"))
        case "cleanReadOverTheCapIsTreatedAsOversize":
            let (content, reason) = try await failureDocument(
                for: .success(
                    Data(repeating: 0x23, count: DocumentURLValidator.maxFileSizeBytes + 1)
                )
            )

            #expect(reason == .oversize)
            #expect(content.contains("# Remote Markdown is too large"))
        default: Issue.record("Unknown scenario: \(scenario)")
        }
    }

    /// `exit RemoteReadExit.fileNotReadable` is reached only after ssh connected
    /// and a remote shell ran — ssh reports its own connection failures as 255 —
    /// so blaming the network here sends the reader to fix the wrong thing.

    /// The runner classifies timeout ahead of truncation, so a read that blew
    /// the cap and then missed the deadline arrives as `.timedOut`. The cap
    /// breach is still proven, and it is the answer the reader needs.

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
        // Catches a literal that carries a `%arg` marker of its own. The
        // catalog is not a declared SwiftPM resource, so under `swift test`
        // `String(localized:)` always formats the literal.
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

        let firstAttempt = fetcher.startAttempt(reference, consumer: .other)
        let first = Task { await firstAttempt.value() }
        await operationGate.waitForEntries(1)
        let secondAttempt = fetcher.startAttempt(reference, consumer: .document)
        let second = Task { await secondAttempt.value() }
        await coalesced.wait()
        await operationGate.release()
        let results = await [first.value, second.value]

        #expect(await counter.count == 1)
        #expect(firstAttempt.cohort === secondAttempt.cohort)
        #expect(firstAttempt.ownsAnnouncements)
        #expect(!secondAttempt.ownsAnnouncements)
        #expect(results[0].outcome?.snapshot.fileURL == results[1].outcome?.snapshot.fileURL)
        #expect(
            try Data(contentsOf: #require(results[0].outcome?.snapshot.fileURL))
                == Data("current".utf8)
        )
    }

    @Test func pruneWaitsForFetchRegisteredInTheSameCacheDirectory() async throws {
        let reference = try #require(
            RemoteMarkdownReference.make(payload: "/repo/README.md", pane: remotePane())
        )
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let pruneEnumerated = AsyncSignal()
        let fetchRegistered = AsyncSignal()
        let fetchEntered = AsyncSignal()
        let pruneGate = AsyncGate()
        let fetcher = RemoteMarkdownSnapshotFetcher(
            cacheDirectoryURL: cacheDirectory,
            fetchOverride: { _ in
                await fetchEntered.signal()
                return .success(Data("fresh plan".utf8))
            },
            onFetchRegistered: { await fetchRegistered.signal() },
            onPruneEnumerated: {
                await pruneEnumerated.signal()
                await pruneGate.enterAndWait()
            }
        )
        let targetURL = cacheDirectory.appending(path: fetcher.cacheFileName(for: reference))
        let orphanURL = cacheDirectory.appending(path: "orphan.md")
        // 0o700: production only ever creates this cache through
        // `validatedOwnerOnlyDirectory`, and the read-only paths refuse a
        // directory left group- or world-readable.
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("stale plan".utf8).write(to: targetURL)
        try Data("orphan".utf8).write(to: orphanURL)

        fetcher.schedulePruneUnreferencedSnapshots(keeping: [])
        await pruneEnumerated.wait()

        let fetchTask = Task { await fetcher.fetch(reference) }
        await fetchRegistered.wait()
        #expect(!(await fetchEntered.wasSignaled()))

        await pruneGate.release()
        let outcome = try #require(await fetchTask.value)
        #expect(outcome.snapshot.fileURL == targetURL)
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
        #expect(try Data(contentsOf: targetURL) == Data("fresh plan".utf8))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
    }
}
