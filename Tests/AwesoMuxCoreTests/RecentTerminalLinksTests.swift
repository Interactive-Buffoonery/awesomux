import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Recent terminal links")
struct RecentTerminalLinksTests {
    @Test func recordsNewestFirst() {
        var links = RecentTerminalLinks()
        links.record("first")
        links.record("second")
        #expect(links.values == ["second", "first"])
    }

    @Test func duplicateMovesToFrontWithoutAddingAnEntry() {
        var links = RecentTerminalLinks()
        links.record("first")
        links.record("second")
        links.record("first")
        #expect(links.values == ["first", "second"])
    }

    @Test func enforcesTwentyEntryCap() {
        var links = RecentTerminalLinks()
        for index in 0..<25 {
            links.record("link-\(index)")
        }
        #expect(links.values.count == 20)
        #expect(links.values.first == "link-24")
        #expect(links.values.last == "link-5")
    }

    @Test func rejectsEmptyAndOversizedValues() {
        var links = RecentTerminalLinks()
        let acceptedEmpty = links.record("")
        let acceptedMaximum = links.record(String(repeating: "a", count: 8_192))
        let acceptedOversized = links.record(String(repeating: "é", count: 4_097))
        #expect(!acceptedEmpty)
        #expect(acceptedMaximum)
        #expect(!acceptedOversized)
        #expect(links.values.count == 1)
    }

    @Test func differentRawValuesRemainDistinct() {
        var links = RecentTerminalLinks()
        links.record(" link ")
        links.record("link")
        #expect(links.values == ["link", " link "])
    }

    @Test func recentLinksDoNotRoundTripThroughTerminalPaneCodable() throws {
        var pane = makePane(title: "pane")
        pane.recentLinks.record("https://example.com/private?token=secret")
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)
        #expect(decoded.recentLinks.values.isEmpty)
        #expect(!String(decoding: data, as: UTF8.self).contains("token=secret"))
    }

    @Test func recentLinksDoNotAffectTerminalPaneEqualityOrHashing() {
        let pane = makePane(title: "pane")
        var changed = pane
        changed.recentLinks.record("https://example.com")
        #expect(pane == changed)
        #expect(Set([pane, changed]).count == 1)
    }

    @Test func recordingForOnePaneDoesNotMutateSiblingPane() throws {
        let left = makePane(title: "left")
        let right = makePane(title: "right")
        let session = makeSplitSession(left: left, right: right)
        let updated = try #require(
            PaneLayoutReducer.recordRecentTerminalLink(
                in: session,
                paneID: left.id,
                value: "https://example.com"
            )
        )
        #expect(updated.layout.pane(id: left.id)?.recentLinks.values == ["https://example.com"])
        #expect(updated.layout.pane(id: right.id)?.recentLinks.values.isEmpty == true)
    }

    @Test @MainActor
    func missingSessionOrPaneIsANoOp() {
        let pane = makePane(title: "pane")
        let session = TerminalSession(
            title: "session",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "group", sessions: [session])],
            selectedSessionID: session.id
        )
        store.recordRecentTerminalLink(
            sessionID: TerminalSession.ID(),
            paneID: pane.id,
            value: "missing-session"
        )
        store.recordRecentTerminalLink(
            sessionID: session.id,
            paneID: TerminalPane.ID(),
            value: "missing-pane"
        )
        #expect(store.session(id: session.id)?.activePane?.recentLinks.values.isEmpty == true)
    }

    private func makePane(title: String) -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "/tmp", executionPlan: .local)
    }

    private func makeSplitSession(left: TerminalPane, right: TerminalPane) -> TerminalSession {
        TerminalSession(
            title: "session",
            workingDirectory: "/tmp",
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(left),
                    second: .pane(right)
                )
            ),
            activePaneID: left.id
        )
    }
}
