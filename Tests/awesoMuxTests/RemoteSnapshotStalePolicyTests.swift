import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

/// The bridge between "the fetcher knows the remote outgrew the cap" and "the
/// pane raises a banner over the retained copy". Before this existed, `.cached`
/// was indistinguishable from a healthy cache hit by the time it reached the
/// view.
@MainActor
@Suite("Remote snapshot stale policy")
struct RemoteSnapshotStalePolicyTests {
    private final class ChangeBox: @unchecked Sendable {
        var values: [RemoteSnapshotStalePolicy.Change] = []
    }

    private func snapshot(path: String) -> RemoteMarkdownSnapshot {
        RemoteMarkdownSnapshot(
            fileURL: URL(fileURLWithPath: path),
            identity: ResourceIdentity(location: .local, path: ResourcePath(rawValue: path))
        )
    }

    private func clear(_ path: String) {
        RemoteSnapshotStalePolicy.note(nil, path: path)
    }

    @Test func anOverCapCachedOutcomeMarksThePathStale() {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }

        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))

        #expect(
            RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteStoppedRefreshing)
    }

    /// A fresh fetch is the only thing that proves the remote fits again, and
    /// it must clear the note — otherwise the banner outlives the condition and
    /// tells the reader their current copy is stale when it is not.
    @Test func aFreshFetchClearsAPriorStaleNote() {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }
        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))
        #expect(
            RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteStoppedRefreshing,
            "premise: the oversize note must be set")

        RemoteSnapshotStalePolicy.record(.fresh(snapshot(path: path)))

        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == nil)
    }

    /// A non-size refresh failure still serves stale content, but must replace
    /// the oversize explanation with copy that is honest for either a missing
    /// file or a failed connection.
    @Test(arguments: [RemoteMarkdownFailureReason.notFound, .connection])
    func nonSizeStaleReasonsRaiseTheRefreshFailedBanner(reason: RemoteMarkdownFailureReason) {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }
        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))
        #expect(
            RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteStoppedRefreshing,
            "premise: the oversize note must be set")

        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: reason))

        #expect(RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteRefreshFailed)
    }

    /// Keyed by standardized path, matching `DocumentOversizePolicy` — two
    /// panes can show the same cached snapshot, and the fact is about the file.
    @Test func pathsAreStandardizedBeforeLookup() {
        let directory = "/tmp/awesomux-stale-\(UUID().uuidString)"
        let path = "\(directory)/doc.md"
        defer { clear(path) }

        RemoteSnapshotStalePolicy.record(
            .cached(snapshot(path: "\(directory)/./doc.md"), staleReason: .oversize))

        #expect(
            RemoteSnapshotStalePolicy.bannerKind(path: path) == .remoteStoppedRefreshing)
    }

    @Test func anUnrelatedPathIsNotStale() {
        #expect(RemoteSnapshotStalePolicy.bannerKind(path: "/tmp/awesomux-never-noted.md") == nil)
    }

    @Test func recordPublishesLiveFailureAndRecoveryChanges() throws {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }
        let box = ChangeBox()
        let token = NotificationCenter.default.addObserver(
            forName: RemoteSnapshotStalePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let change = notification.object as? RemoteSnapshotStalePolicy.Change else {
                return
            }
            box.values.append(change)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        RemoteSnapshotStalePolicy.record(
            .cached(snapshot(path: path), staleReason: .connection))
        RemoteSnapshotStalePolicy.record(.fresh(snapshot(path: path)))

        #expect(box.values.map(\.path) == [path, path])
        #expect(box.values.map(\.kind) == [.remoteRefreshFailed, nil])
    }
}

/// The banner variants must not drift into giving distinct failures the same
/// explanation.
@MainActor
@Suite("Document oversize banner copy per kind")
struct DocumentOversizeBannerKindTests {
    @Test func everyKindHasDistinctDetail() {
        let details = [
            DocumentOversizeBanner.detail(for: .localFileGrew),
            DocumentOversizeBanner.detail(for: .remoteStoppedRefreshing),
            DocumentOversizeBanner.detail(for: .remoteRefreshFailed),
        ]

        #expect(Set(details).count == details.count)
    }

    /// Remote snapshots are already read-only, so there is no commenting change
    /// to announce — saying "comments are paused" would describe a transition
    /// that never happened.
    @Test func theRemoteVariantDoesNotClaimCommentsChanged() {
        let detail = DocumentOversizeBanner.detail(for: .remoteStoppedRefreshing)
        #expect(!detail.lowercased().contains("comment"), "\(detail)")
        #expect(
            DocumentOversizeBanner.detail(for: .localFileGrew).lowercased().contains("comment"),
            "premise: the local variant is the one that mentions comments")
    }

    /// Both state the enforced cap, and both must read it from the validator
    /// rather than a hand-typed number.
    @Test(arguments: [
        DocumentOversizeBanner.Kind.localFileGrew, .remoteStoppedRefreshing,
    ])
    func everyVariantStatesTheEnforcedCap(kind: DocumentOversizeBanner.Kind) {
        #expect(
            DocumentOversizeBanner.detail(for: kind)
                .contains("\(DocumentURLValidator.maxFileSizeMegabytes) MB"))
    }

    @Test func refreshFailureCopyDoesNotInventTheCauseOrOrigin() {
        let detail = DocumentOversizeBanner.detail(for: .remoteRefreshFailed)

        #expect(detail.localizedCaseInsensitiveContains("couldn't refresh"))
        #expect(detail.localizedCaseInsensitiveContains("last copy"))
        #expect(!detail.localizedCaseInsensitiveContains("host"))
        #expect(!detail.localizedCaseInsensitiveContains("not found"))
        #expect(!detail.localizedCaseInsensitiveContains("MB"))
    }

    /// The lead-in must not claim the document is too large to render — the
    /// copy on screen rendered fine and still does. Only the refresh failed.
    @Test func theRemoteAccessibilityLeadNamesTheRefreshNotTheRender() {
        let label = DocumentOversizeBanner.accessibilityLabel(
            fileName: "plan.md", kind: .remoteStoppedRefreshing)

        #expect(label.contains("plan.md"))
        #expect(label.contains("stopped refreshing"))
        #expect(!label.contains("too large to render"), "\(label)")
    }

    @Test func refreshFailureAccessibilityNamesTheUnavailableRefresh() {
        let label = DocumentOversizeBanner.accessibilityLabel(
            fileName: "plan.md", kind: .remoteRefreshFailed)

        #expect(label.contains("plan.md"))
        #expect(label.localizedCaseInsensitiveContains("couldn't be refreshed"))
        #expect(!label.contains("too large to render"), "\(label)")
    }
}
