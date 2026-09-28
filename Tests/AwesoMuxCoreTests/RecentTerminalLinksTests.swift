import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Recent terminal links")
struct RecentTerminalLinksTests {

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

    private func makePane(title: String) -> TerminalPane {
        TerminalPane(title: title, workingDirectory: "/tmp", executionPlan: .local)
    }
}
