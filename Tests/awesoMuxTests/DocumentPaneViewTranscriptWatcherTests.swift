import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

// MARK: - DocumentPaneView's cache watcher follows the transcript identity

/// A transcript tab's cache file is rewritten for as long as its agent session
/// runs (#494), so its watcher runs `.leadingEdge` while every other document
/// keeps the trailing `.debounced` behaviour a human editor wants. That choice
/// is made once, when the watcher starts.
///
/// The gap that closes is a tab that becomes a transcript *after* it mounts.
/// The reducer can backfill `agentTranscriptIdentity` onto the pane that
/// already holds this file URL, and the URL is the view's identity, so nothing
/// remounts and `onAppear` never fires again. Without a restart that tab keeps
/// the debounced watcher it was given as an ordinary document — the starvation
/// live refresh exists to remove, on the one tab that just became eligible.
///
/// **This is a source contract, not a behavioural test.** The watcher is
/// private `@State` armed from `body`, and this file's suites already record
/// hosting the view as impractical; a hosted test here would be the vacuously
/// green kind `SourceContract` was written to replace. It asserts the two
/// halves that make the rule true: that the restart is keyed on the transcript
/// identity, and that the mode is derived from that identity rather than
/// pinned.
@Suite("DocumentPaneView transcript watcher lifecycle")
struct DocumentPaneViewTranscriptWatcherTests {

    private static let panePath = "Sources/awesoMux/Views/DocumentPaneView.swift"

    @Test("the watcher restarts when a mounted tab becomes a transcript")
    func watcherRestartsOnTranscriptIdentityChange() throws {
        let body = try SourceContract.declarationBody(
            after: ".onChange(of: pane.agentTranscriptIdentity != nil) {",
            in: try SourceContract.source(at: Self.panePath),
            path: Self.panePath
        )
        #expect(
            body.contains("startWatcher()"),
            """
            The transcript-identity onChange no longer restarts the watcher. \
            A tab that becomes a transcript after mounting keeps the coalescing \
            mode it was given as an ordinary document, which starves live \
            refresh for exactly as long as its agent keeps writing.
            """
        )
    }

    @Test("the coalescing mode is derived from the pane's transcript identity")
    func coalescingModeFollowsTheTranscriptIdentity() throws {
        let body = try SourceContract.declarationBody(
            after: "private func startWatcher() {",
            in: try SourceContract.source(at: Self.panePath),
            path: Self.panePath
        )
        #expect(
            body.contains("pane.agentTranscriptIdentity"),
            """
            startWatcher no longer reads pane.agentTranscriptIdentity, so \
            restarting it on an identity change cannot change anything. Either \
            the mode moved, or the transcript watcher lost its leading edge.
            """
        )
    }
}
