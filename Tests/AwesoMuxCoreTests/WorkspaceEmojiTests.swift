import Foundation
import Testing
@testable import AwesoMuxCore

@Suite("Workspace emoji")
struct WorkspaceEmojiTests {
    @Test(arguments: ["🍎", "👩🏽‍💻", "🇪🇸"])
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
