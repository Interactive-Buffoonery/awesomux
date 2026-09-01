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
    /// safe. Selection preservation lives at the later TextKit replacement
    /// boundary. Once that boundary has rejected an incompatible replacement,
    /// one intentional early exit coalesces further viewer reloads until the
    /// selection clears.
    ///
    /// **This is a source contract, not a behavioural test, and it is named to
    /// say so.** `triggerWatcherReload` is private, it drives private `@State`,
    /// and its effect is a SwiftUI reload — there is no seam to observe it
    /// from without hosting the view, which the oversize-banner suite already
    /// records as impractical for this file. The behavioural half of the rule
    /// is `transcriptSuppressed` above; this half asserts that no unrelated
    /// exit was added above the reload.
    ///
    /// The scan starts at the top of the declaration, not at the over-cap
    /// branch's own reload. Anything that exits earlier — a guard added above
    /// `readSnapshot`, a transcript check written into the cancellation guard —
    /// skips *both* reloads and disables live refresh just as thoroughly,
    /// while a window that opened at the first reload could not see it. It
    /// pins the exits themselves rather than counting them, because a bare
    /// `return` and a `return nil` are different statements in different
    /// positions and "there are still three of them" is not the invariant.
    @Test("triggerWatcherReload has only intentional exits above its reload")
    func triggerWatcherReloadHasOnlyIntentionalExits() throws {
        let body = try SourceContract.declarationBody(
            after: "private func triggerWatcherReload() {",
            in: try SourceContract.source(at: Self.panePath),
            path: Self.panePath
        )
        let reload = try #require(body.range(of: "triggerReload(snapshot: onDisk)"))

        // Comment-stripped and token-matched, so `returns`/`returned` in prose
        // cannot stand in for a statement, and `guard … else { throw }` cannot
        // hide from a scan that only knows the word `return`.
        let code = body[body.startIndex..<reload.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
        let exits = code.matches(of: /\b(?:return|throw)\b[^\n]*/)
            .map { $0.output.trimmingCharacters(in: CharacterSet(charactersIn: " \t}")) }

        #expect(
            exits == [
                // A prior incompatible replacement already recorded the one
                // pending catch-up, so this watcher tick has no new work.
                "return",
                // The detached task, after its own read: nothing has been
                // reloaded yet, so returning costs only this tick.
                "return",
                // A superseded generation, on the main actor.
                "return nil",
                // The over-cap branch, which reloads on its own line first.
                "return nil",
            ],
            """
            triggerWatcherReload gained or changed an exit above \
            triggerReload(snapshot:), and the exits now read \(exits). \
            Only deferred-selection coalescing, cancellation, and the over-cap branch may \
            skip this reload. Any other exit disables live refresh.
            """
        )
    }

    private static let panePath = "Sources/awesoMux/Views/DocumentPaneView.swift"
}

// MARK: - DocumentPaneView.consumeLiveTranscriptRefreshAnnouncement

/// Suppressing the revision announcement (above) leaves a VoiceOver user with
/// no signal that the document they are reading is being rewritten and their
/// position may move. One announcement per mount restores the signal without
/// restoring the noise.
@Suite("DocumentPaneView live transcript refresh announcement")
struct DocumentPaneViewLiveTranscriptAnnouncementTests {

    /// Drives the seam the way the view does: one latch, reused across reloads.
    private func announcements(
        isAgentTranscript: Bool = true,
        renderedSources: [String?],
        onDiskSources: [String]
    ) -> [Bool] {
        var latch = false
        return zip(renderedSources, onDiskSources).map { rendered, onDisk in
            DocumentPaneView.consumeLiveTranscriptRefreshAnnouncement(
                isAgentTranscript: isAgentTranscript,
                alreadyAnnounced: &latch,
                renderedSource: rendered,
                onDiskSource: onDisk
            )
        }
    }

    @Test("the first content-changing refresh announces")
    func firstChangeAnnounces() {
        #expect(
            announcements(renderedSources: ["# turn 1"], onDiskSources: ["# turn 1\n# turn 2"])
                == [true]
        )
    }

    @Test("later refreshes of the same mount stay silent")
    func laterChangesStaySilent() {
        #expect(
            announcements(
                renderedSources: ["# turn 1", "# turn 2", "# turn 3"],
                onDiskSources: ["# turn 2", "# turn 3", "# turn 4"]
            ) == [true, false, false]
        )
    }

    /// A live-refreshing tab re-renders on every filesystem event, and most of
    /// those events change nothing this document shows.
    @Test("a refresh that changed nothing says nothing, and spends no latch")
    func unchangedRefreshIsSilent() {
        #expect(
            announcements(
                renderedSources: ["# turn 1", "# turn 1", "# turn 1"],
                onDiskSources: ["# turn 1", "# turn 1", "# turn 1"]
            ) == [false, false, false]
        )
        // The latch is spent by an announcement, never by a no-op reload: an
        // idle session that ticks first must still be able to announce its
        // first real append.
        #expect(
            announcements(
                renderedSources: ["# turn 1", "# turn 1"],
                onDiskSources: ["# turn 1", "# turn 1\n# turn 2"]
            ) == [false, true]
        )
    }

    @Test("an ordinary document never announces")
    func ordinaryDocumentIsSilent() {
        #expect(
            announcements(
                isAgentTranscript: false,
                renderedSources: ["# turn 1", "# turn 2"],
                onDiskSources: ["# turn 2", "# turn 3"]
            ) == [false, false]
        )
    }

    /// Opening the tab is not a live refresh, and the tab already announces
    /// when it opens.
    @Test("a reload with nothing rendered yet does not announce")
    func initialLoadIsSilent() {
        #expect(announcements(renderedSources: [nil], onDiskSources: ["# turn 1"]) == [false])
    }

    /// A remount resets the latch, so the announcement is per mount rather
    /// than once per process.
    @Test("a fresh mount can announce again")
    func remountAnnouncesAgain() {
        for _ in 0..<2 {
            #expect(
                announcements(renderedSources: ["# turn 1"], onDiskSources: ["# turn 2"]) == [true]
            )
        }
    }

    @Test("the announcement names the document as live and nothing else")
    func announcementCopy() {
        #expect(DocumentPaneView.liveTranscriptRefreshAnnouncement == "Transcript is updating live.")
    }

    /// A source contract for the same reason as
    /// `triggerWatcherReloadHasNoExitAboveTheReload`: everything above is a
    /// pure seam the tests call themselves, so all of it stays green if the
    /// production call site is deleted, or merely moved *below*
    /// `triggerReload(snapshot:)` — after which `renderedDoc?.source` is the
    /// bytes that just landed, old never differs from new, and the
    /// announcement silently never fires again. There is no seam to observe
    /// that from without hosting the view.
    @Test("triggerWatcherReload asks for the announcement before it reloads")
    func announcementIsWiredAboveTheReload() throws {
        let body = try SourceContract.declarationBody(
            after: "private func triggerWatcherReload() {",
            in: try SourceContract.source(at: Self.panePath),
            path: Self.panePath
        )
        let call = try #require(
            body.range(of: "consumeLiveTranscriptRefreshAnnouncement("),
            "triggerWatcherReload no longer asks whether to announce a live transcript refresh."
        )
        let reload = try #require(body.range(of: "triggerReload(snapshot: onDisk)"))
        #expect(
            call.upperBound < reload.lowerBound,
            """
            The live-refresh announcement moved below triggerReload(snapshot:). \
            It has to read the pre-reload rendered source, which that call \
            replaces — below it, old always equals new and nothing is ever \
            announced.
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
