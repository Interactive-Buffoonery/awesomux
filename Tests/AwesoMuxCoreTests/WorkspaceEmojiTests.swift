import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Workspace emoji")
struct WorkspaceEmojiTests {
    @Test(arguments: [
        "🍎", "🚀", "👩🏽‍💻", "🇪🇸", "1️⃣", "❤️", "🏳️‍🌈", "☝🏽", "✌🏽", "🕵🏽",
        "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        "🏴\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}",
    ])
    func acceptsSingleEmoji(_ emoji: String) {
        #expect(WorkspaceEmoji.validated(emoji) == emoji)
    }

    @Test(arguments: [
        "", " ", "a", "1", "#", "🍎🚀", "hello 🍎", "\u{202E}🍎", "🏽",
        "1\u{FE0F}", "🇦", "🍎🏽🏽", "🍎\u{E0061}\u{E007F}",
        "🍎\u{20E3}", "🍎\u{FE0F}\u{FE0F}",
        "🏴\u{E0068}\u{E0065}\u{E006C}\u{E006C}\u{E006F}\u{E007F}",
        Array(repeating: "🍎", count: 16).joined(separator: "\u{200D}"),
        String(repeating: "\u{200D}", count: 100),
    ])
    func rejectsOtherInput(_ input: String) {
        #expect(WorkspaceEmoji.validated(input) == nil)
    }

    @Test @MainActor
    func badgeDoesNotFreezeAutomaticTitle() throws {
        let session = TerminalSession(title: "before", workingDirectory: NSHomeDirectory())
        let store = SessionStore(groups: [SessionGroup(name: "Test", sessions: [session])])
        #expect(store.setWorkspaceEmoji(id: session.id, emoji: "🍎"))
        store.updatePane(sessionID: session.id, paneID: session.activePaneID, title: "after")
        let updated = try #require(store.session(id: session.id))
        #expect(updated.emoji == "🍎")
        #expect(updated.title == "after")
        #expect(!updated.isTitleUserEdited)
        #expect(!updated.activePane!.isTitleUserEdited)
        #expect(!store.setWorkspaceEmoji(id: session.id, emoji: "no"))
        #expect(store.session(id: session.id)?.emoji == "🍎")
        #expect(!store.setWorkspaceEmoji(id: UUID(), emoji: "🚀"))
        #expect(store.setWorkspaceEmoji(id: session.id, emoji: nil))
        #expect(store.session(id: session.id)?.emoji == nil)
    }

    @Test @MainActor
    func survivesSnapshotRestoreAndReopen() throws {
        let session = TerminalSession(title: "shell", workingDirectory: NSHomeDirectory())
        let store = SessionStore(groups: [SessionGroup(name: "Test", sessions: [session])])
        #expect(store.setWorkspaceEmoji(id: session.id, emoji: "👩🏽‍💻"))
        let data = try JSONEncoder().encode(store.snapshot())
        let snapshot = try SessionSnapshot.decode(from: data)
        let restored = SessionStore(restoring: snapshot)
        #expect(restored.session(id: session.id)?.emoji == "👩🏽‍💻")
        restored.closeSession(id: session.id)
        #expect(restored.recentlyClosed.first?.emoji == "👩🏽‍💻")
        let closedData = try JSONEncoder().encode(restored.snapshot())
        let closedSnapshot = try SessionSnapshot.decode(from: closedData)
        let reopened = SessionStore(restoring: closedSnapshot)
        let id = try #require(reopened.reopenMostRecentlyClosed())
        #expect(reopened.session(id: id)?.emoji == "👩🏽‍💻")
    }

    @Test
    func oldAndMalformedSnapshotValuesAreHarmless() throws {
        let session = TerminalSession(title: "shell", workingDirectory: "~")
        let data = try JSONEncoder().encode(session)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["emoji"] == nil)
        for value: Any in [NSNull(), 42, "not emoji", "🍎🚀"] {
            json["emoji"] = value
            let malformed = try JSONSerialization.data(withJSONObject: json)
            #expect(try JSONDecoder().decode(TerminalSession.self, from: malformed).emoji == nil)
        }
    }
}
