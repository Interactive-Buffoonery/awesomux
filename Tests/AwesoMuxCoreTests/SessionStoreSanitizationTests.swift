import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("SessionStore sanitization")
struct SessionStoreSanitizationTests {

    enum Context: Sendable { case group, title }

    @Test(
        "sanitize names at their routing and display boundaries",
        arguments: [
            (Context.group, "foo\u{202E}bar", "foobar"),
            (.title, "foo\u{202E}bar", "foobar"),
            (.group, "foo\u{2066}bar", "foobar"),
            (.group, "foo\u{2067}bar", "foobar"),
            (.group, "foo\u{2068}bar", "foobar"),
            (.group, "foo\u{2069}bar", "foobar"),
            (.title, "\u{200E}", ""),
            (.title, "\u{200F}", ""),
            (.title, "\u{061C}", ""),
            (.title, "\u{200E}\u{200F}\u{061C}", ""),
            (.title, "\u{200C}", ""),
            (.title, "\u{200D}", ""),
            (.group, "\u{200E}", ""),
            (.group, "\u{200C}\u{200D}", ""),
            (.title, "\u{115F}\u{FE0F}\u{E0100}", ""),
            (.group, "\u{115F}\u{FE0F}\u{E0100}", ""),
            (.title, "\u{1F469}\u{200D}\u{1F4BB}", "\u{1F469}\u{200D}\u{1F4BB}"),
            (.title, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
            (.title, "src/main.rs\u{200E}(latin)", "src/main.rs\u{200E}(latin)"),
            (.title, "src/main.rs\u{200F}(عربي)", "src/main.rs\u{200F}(عربي)"),
            (.title, "src/main.rs\u{061C}(عربي)", "src/main.rs\u{061C}(عربي)"),
            (.group, "src/main.rs\u{200E}(latin)", "src/main.rs(latin)"),
            (.group, "src/main.rs\u{200F}(عربي)", "src/main.rs(عربي)"),
            (.group, "src/main.rs\u{061C}(عربي)", "src/main.rs(عربي)"),
            (.title, "\u{FF41}\u{FF42}\u{FF43}", "abc"),
            (.group, "\u{1D41A}\u{1D41B}\u{1D41C}", "abc"),
            (.group, String(repeating: "a", count: 200), String(repeating: "a", count: SessionStore.maxGroupNameLength)),
            (
                .title, "  " + String(repeating: "a", count: SessionStore.maxTitleLength + 10) + "\u{202E}\n  ",
                String(repeating: "a", count: SessionStore.maxTitleLength)
            ),
            (.title, "\u{0301}\u{0301}\u{0301}", ""),
            (.group, "\u{20DD}", ""),
            (.title, "e\u{0301}", "e\u{0301}"),
        ])
    func sanitize(context: Context, input: String, expected: String) {
        let result = context == .group ? SessionStore.sanitizedGroupName(input) : SessionStore.sanitizedTitle(input)
        #expect(result == expected)
    }
}
