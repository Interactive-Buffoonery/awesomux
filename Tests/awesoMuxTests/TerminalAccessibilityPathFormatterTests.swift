import Foundation
import Testing
@testable import awesoMux

@Suite("Terminal accessibility path formatter")
struct TerminalAccessibilityPathFormatterTests {
    @Test("home directory is abbreviated")
    func abbreviatesHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(TerminalAccessibilityPathFormatter.format(home) == "~")
    }

    @Test("deep home paths preserve the root and final context")
    func compactsDeepHomePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Development/awesomux/vendor/ghostty"

        #expect(TerminalAccessibilityPathFormatter.format(path) == "~/.../vendor/ghostty")
    }

    @Test("compaction fires at four components but not three")
    func compactionBoundary() {
        // count > 3 is the gate; pin both sides so an off-by-one is caught.
        #expect(TerminalAccessibilityPathFormatter.format("/a/b/c") == "/a/b/c")
        #expect(TerminalAccessibilityPathFormatter.format("/a/b/c/d") == "/a/.../c/d")
    }

    @Test("long shallow paths are capped, preserving the identifying tail")
    func capsLongShallowPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let longDirectoryName = String(repeating: "project-name-", count: 12)
        let formatted = TerminalAccessibilityPathFormatter.format(
            home + "/Projects/" + longDirectoryName
        )

        #expect(formatted.count <= TerminalAccessibilityPathFormatter.maximumPathLength)
        // Front-truncation keeps the leaf tail (the disambiguating part for a
        // screen-reader user), not the prefix.
        #expect(formatted.hasPrefix("..."))
        #expect(formatted.hasSuffix("project-name-"))
    }

    @Test("truncation fires above the cap but not at it")
    func truncationBoundary() {
        let atCap = "/" + String(repeating: "a", count: 79) // count == 80
        let overCap = "/" + String(repeating: "a", count: 80) // count == 81

        #expect(TerminalAccessibilityPathFormatter.format(atCap) == atCap)

        let truncated = TerminalAccessibilityPathFormatter.format(overCap)
        #expect(truncated != overCap)
        #expect(truncated.count == TerminalAccessibilityPathFormatter.maximumPathLength)
        #expect(truncated.hasPrefix("..."))
    }

    @Test("a deep AND over-long path collapses to a single ellipsis marker")
    func deepLongPathHasSingleMarker() {
        let segment = String(repeating: "a", count: 60)
        let path = "/root/mid/" + segment + "/" + segment

        let formatted = TerminalAccessibilityPathFormatter.format(path)

        #expect(formatted.count <= TerminalAccessibilityPathFormatter.maximumPathLength)
        // Without front-truncation this carried compaction's "/.../" marker AND
        // a second truncation marker. The front cut drops the former.
        #expect(formatted.components(separatedBy: "...").count - 1 == 1)
    }

    @Test("empty and root paths pass through unchanged")
    func emptyAndRootPaths() {
        #expect(TerminalAccessibilityPathFormatter.format("") == "")
        #expect(TerminalAccessibilityPathFormatter.format("/") == "/")
    }

    @Test("control characters beyond CR/LF are sanitized for speech")
    func sanitizesControlCharacters() {
        let formatted = TerminalAccessibilityPathFormatter.format("~/a\tb\u{07}c")

        #expect(!formatted.contains("\t"))
        #expect(!formatted.contains("\u{07}"))
        #expect(formatted == "~/a b c")
    }

    @Test("line breaks are sanitized before truncation")
    func sanitizesLineBreaks() {
        let formatted = TerminalAccessibilityPathFormatter.format("~/first\nsecond\rthird")

        #expect(!formatted.contains("\n"))
        #expect(!formatted.contains("\r"))
        #expect(formatted == "~/first second third")
    }
}
