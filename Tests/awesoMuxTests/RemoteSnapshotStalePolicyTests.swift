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
    private func snapshot(path: String) -> RemoteMarkdownSnapshot {
        RemoteMarkdownSnapshot(
            fileURL: URL(fileURLWithPath: path),
            identity: ResourceIdentity(location: .local, path: ResourcePath(rawValue: path))
        )
    }

    private func clear(_ path: String) {
        RemoteSnapshotStalePolicy.noteStale(false, path: path)
    }

    @Test func anOverCapCachedOutcomeMarksThePathStale() {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }

        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))

        #expect(RemoteSnapshotStalePolicy.isStale(path: path))
    }

    /// A fresh fetch is the only thing that proves the remote fits again, and
    /// it must clear the note — otherwise the banner outlives the condition and
    /// tells the reader their current copy is stale when it is not.
    @Test func aFreshFetchClearsAPriorStaleNote() {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }
        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))
        #expect(RemoteSnapshotStalePolicy.isStale(path: path), "premise: the note must be set")

        RemoteSnapshotStalePolicy.record(.fresh(snapshot(path: path)))

        #expect(!RemoteSnapshotStalePolicy.isStale(path: path))
    }

    /// Only the size reason raises this banner. A host that went unreachable
    /// also serves a cached copy, but "too large" would be a false explanation
    /// — and the honest surface for unreachability is different copy, not this
    /// one. Both still CLEAR a prior note: a fetch that got far enough to fail
    /// differently is no longer evidence the file is over cap.
    @Test(arguments: [RemoteMarkdownFailureReason.notFound, .connection])
    func nonSizeStaleReasonsDoNotRaiseTheBanner(reason: RemoteMarkdownFailureReason) {
        let path = "/tmp/awesomux-stale-\(UUID().uuidString).md"
        defer { clear(path) }
        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: .oversize))
        #expect(RemoteSnapshotStalePolicy.isStale(path: path), "premise: the note must be set")

        RemoteSnapshotStalePolicy.record(.cached(snapshot(path: path), staleReason: reason))

        #expect(!RemoteSnapshotStalePolicy.isStale(path: path))
    }

    /// Keyed by standardized path, matching `DocumentOversizePolicy` — two
    /// panes can show the same cached snapshot, and the fact is about the file.
    @Test func pathsAreStandardizedBeforeLookup() {
        let directory = "/tmp/awesomux-stale-\(UUID().uuidString)"
        let path = "\(directory)/doc.md"
        defer { clear(path) }

        RemoteSnapshotStalePolicy.record(
            .cached(snapshot(path: "\(directory)/./doc.md"), staleReason: .oversize))

        #expect(RemoteSnapshotStalePolicy.isStale(path: path))
    }

    @Test func anUnrelatedPathIsNotStale() {
        #expect(!RemoteSnapshotStalePolicy.isStale(path: "/tmp/awesomux-never-noted.md"))
    }
}

/// The two banner variants must not drift into saying the same thing — if they
/// did, the remote case would be telling users their local file grew.
@Suite("Document oversize banner copy per kind")
struct DocumentOversizeBannerKindTests {
    @Test func theTwoKindsReadDifferently() {
        #expect(
            DocumentOversizeBanner.kicker(for: .localFileGrew)
                != DocumentOversizeBanner.kicker(for: .remoteStoppedRefreshing))
        #expect(
            DocumentOversizeBanner.detail(for: .localFileGrew)
                != DocumentOversizeBanner.detail(for: .remoteStoppedRefreshing))
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

    /// The lead-in must not claim the document is too large to render — the
    /// copy on screen rendered fine and still does. Only the refresh failed.
    @Test func theRemoteAccessibilityLeadNamesTheRefreshNotTheRender() {
        let label = DocumentOversizeBanner.accessibilityLabel(
            fileName: "plan.md", kind: .remoteStoppedRefreshing)

        #expect(label.contains("plan.md"))
        #expect(label.contains("stopped refreshing"))
        #expect(!label.contains("too large to render"), "\(label)")
    }
}
