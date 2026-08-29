import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

private let transcriptSession = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

/// Force-unwrapped on purpose: a fixture that stopped validating is a bug in
/// the fixture, and every test below depends on it being a real identity.
private let transcriptIdentity = AgentTranscriptIdentity(
    agentKind: .claudeCode,
    sessionID: transcriptSession
)!

// MARK: - DocumentPaneView.watcherRevisionContext

/// A transcript tab's cache file is rewritten for as long as its agent session
/// runs (#494). Those rewrites must reload the tab and must not be reported as
/// external edits.
@Suite("DocumentPaneView.watcherRevisionContext")
struct DocumentPaneViewWatcherRevisionContextTests {

    @Test("an ordinary tab diffs against the rendered source")
    func ordinaryTabReports() {
        let context = DocumentPaneView.watcherRevisionContext(
            isAgentTranscript: false,
            selfWrite: nil,
            renderedSource: "# old"
        )
        #expect(context?.old == "# old")
        #expect(context?.isSelfWrite == false)
    }

    @Test("a self-write diffs from the source awesoMux itself wrote")
    func selfWriteWins() {
        let context = DocumentPaneView.watcherRevisionContext(
            isAgentTranscript: false,
            selfWrite: MarkdownSelfWriteContext(source: "# mine", isSelfWrite: true),
            renderedSource: "# old"
        )
        #expect(context?.old == "# mine")
        #expect(context?.isSelfWrite == true)
    }

    @Test("a transcript tab reports nothing")
    func transcriptSuppressed() {
        #expect(
            DocumentPaneView.watcherRevisionContext(
                isAgentTranscript: true,
                selfWrite: nil,
                renderedSource: "# old"
            ) == nil
        )
        // Even a matching self-write entry cannot revive reporting: the tab
        // has no user edits to report at all.
        #expect(
            DocumentPaneView.watcherRevisionContext(
                isAgentTranscript: true,
                selfWrite: MarkdownSelfWriteContext(source: "# mine", isSelfWrite: true),
                renderedSource: "# old"
            ) == nil
        )
    }

    /// The regression that matters most, and the one the pure seam above
    /// cannot catch on its own.
    ///
    /// `pendingScrollAnchor` and `triggerReload(snapshot:)` sit *above* the
    /// diff inside the same `MainActor.run` block, so a transcript check
    /// written as an early return there would silently disable live refresh
    /// while every behavioural test still passed. The suppression is a returned
    /// value for exactly that reason, and this pins the shape that makes it
    /// safe.
    ///
    /// **This is a source contract, not a behavioural test, and it is named to
    /// say so.** `triggerWatcherReload` is private, it drives private `@State`,
    /// and its effect is a SwiftUI reload — there is no seam to observe it
    /// from without hosting the view, which the oversize-banner suite already
    /// records as impractical for this file. The behavioural half of the rule
    /// is `transcriptSuppressed` above; this half only asserts that nothing
    /// exits the block before the reload it depends on.
    @Test("triggerWatcherReload has no exit between the two reload calls")
    func triggerWatcherReloadHasNoExitAboveTheReload() throws {
        let body = try SourceContract.declarationBody(
            after: "private func triggerWatcherReload() {",
            in: try SourceContract.source(at: Self.panePath),
            path: Self.panePath
        )
        // From the over-cap branch's own reload to the normal one: the only
        // legitimate exit in between is that branch's single `return nil`.
        let overCapReload = try #require(body.range(of: "triggerReload()\n"))
        let reload = try #require(
            body.range(of: "triggerReload(snapshot: onDisk)", range: overCapReload.upperBound..<body.endIndex)
        )

        // Comment-stripped and token-matched, so `returns`/`returned` in prose
        // cannot stand in for a statement, and `guard … else { throw }` cannot
        // hide from a scan that only knows the word `return`.
        let code = body[overCapReload.upperBound..<reload.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
        let exits = code.matches(of: /\b(return|throw)\b/)

        #expect(
            exits.count == 1,
            """
            triggerWatcherReload gained an early exit above \
            triggerReload(snapshot:). Suppressing the revision indicator for a \
            transcript must not skip the reload — that disables live refresh.
            """
        )
    }

    private static let panePath = "Sources/awesoMux/Views/DocumentPaneView.swift"
}

// MARK: - DocumentRevisionMonitor

/// The monitor's background-tab pipeline must not watch a transcript either:
/// it would announce every live refresh from the other side.
@MainActor
@Suite("DocumentRevisionMonitor transcript suppression", .serialized)
struct DocumentRevisionMonitorTranscriptTests {

    private final class AnnouncementLog {
        var messages: [String] = []
    }

    private static let baseContent = "line1\nline2\nline3"

    @Test("a transcript tab gets no entry and no watcher, an ordinary tab does")
    func syncSkipsTranscripts() async throws {
        let directory = try TemporaryDirectory(prefix: "DocumentRevisionMonitorTranscriptTests")
        defer { withExtendedLifetime(directory) {} }

        let selectedURL = directory.url.appendingPathComponent("selected.md")
        let plainURL = directory.url.appendingPathComponent("plain.md")
        let transcriptURL = directory.url.appendingPathComponent("transcript.md")
        for url in [selectedURL, plainURL, transcriptURL] {
            try Self.baseContent.write(to: url, atomically: false, encoding: .utf8)
        }

        let selected = DocumentPane(fileURL: selectedURL, title: "selected.md")
        let plain = DocumentPane(fileURL: plainURL, title: "plain.md")
        let transcript = DocumentPane(
            fileURL: transcriptURL,
            title: "Claude Code Transcript",
            agentTranscriptIdentity: transcriptIdentity
        )

        let log = AnnouncementLog()
        let monitor = DocumentRevisionMonitor()
        monitor.announce = { log.messages.append($0) }
        monitor.selfWriteContext = { _, _ in nil }
        monitor.sync(
            tabs: [selected, plain, transcript],
            selectedTabID: selected.id,
            cachedSource: { _ in Self.baseContent }
        )
        defer { monitor.stopAll() }
        // Give the vnode sources a tick to arm before the first edit.
        try await Task.sleep(nanoseconds: 50_000_000)

        let edited = Self.baseContent + "\nline4"
        try edited.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try edited.write(to: plainURL, atomically: true, encoding: .utf8)

        // Gate the negative on the positive: once the ordinary background tab
        // has recorded, the transcript's write has had at least as long.
        let recorded = await waitUntilEventually {
            monitor.indicator(for: plain) != nil
        }
        #expect(recorded)
        #expect(monitor.indicator(for: transcript) == nil)
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.contains("plain.md") == true)
    }

    @Test("recordSelected on a transcript records nothing and says nothing")
    func recordSelectedSkipsTranscripts() {
        let log = AnnouncementLog()
        let monitor = DocumentRevisionMonitor()
        monitor.announce = { log.messages.append($0) }

        let transcript = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/awesomux-transcript-\(UUID().uuidString).md"),
            title: "Claude Code Transcript",
            agentTranscriptIdentity: transcriptIdentity
        )
        monitor.recordSelected(.exact(LineDiffCount(added: 3, removed: 0)), for: transcript)

        #expect(monitor.indicator(for: transcript) == nil)
        #expect(log.messages.isEmpty)
    }

    /// The third entry point into `entries`. `sync` filters transcripts out,
    /// but this runs per reload and would put one back — inert today only
    /// because nothing reads it, which is not a property to leave resting on
    /// the next caller.
    @Test("noteRenderCompleted creates no entry for a transcript")
    func noteRenderCompletedSkipsTranscripts() {
        let monitor = DocumentRevisionMonitor()
        monitor.announce = { _ in }

        let transcript = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/awesomux-transcript-\(UUID().uuidString).md"),
            title: "Claude Code Transcript",
            agentTranscriptIdentity: transcriptIdentity
        )
        monitor.noteRenderCompleted(source: Self.baseContent, for: transcript)
        // An entry would make the tab reportable from the background pipeline,
        // which is exactly what `sync` refused it.
        monitor.recordSelected(.exact(LineDiffCount(added: 1, removed: 0)), for: transcript)

        #expect(monitor.indicator(for: transcript) == nil)
    }

    @Test("recordSelected still records for an ordinary tab")
    func recordSelectedKeepsOrdinaryTabs() {
        let log = AnnouncementLog()
        let monitor = DocumentRevisionMonitor()
        monitor.announce = { log.messages.append($0) }

        let plain = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/awesomux-plain-\(UUID().uuidString).md"),
            title: "plain.md"
        )
        monitor.recordSelected(.exact(LineDiffCount(added: 3, removed: 0)), for: plain)

        #expect(monitor.indicator(for: plain) != nil)
        #expect(log.messages.count == 1)
    }
}
