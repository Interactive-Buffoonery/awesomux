import Foundation
import Testing

/// Guard rail for ADR-0013 (INT-530): focus-cue contrast stays keyed to the
/// config-derived terminal background. Runtime OSC 11 background reports are
/// pty-writable, so wiring `GHOSTTY_ACTION_COLOR_CHANGE` without a clamping
/// sanitizer would let a hostile process degrade the `.needs` focus stripe
/// below the WCAG floor `AwColors.focusAccent` enforces. These tests scan the
/// source tree so that future OSC 11 work must go through the sanitizer
/// deliberately instead of silently rebinding the cue.
@Suite("Focus-cue color source guard (INT-530)")
struct FocusCueColorSourceGuardTests {
    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // awesoMuxTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Sources")

    /// One walk of `Sources/`, shared by every test in the suite.
    private static let swiftSources: [(path: String, contents: String)] = {
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        var results: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            results.append((url.path, contents))
        }
        return results
    }()

    /// Markers that indicate a file handles the runtime color-change action.
    /// `.color_change` is the payload union member spelled in ghostty.h
    /// (`ghostty_action_color_change_s color_change;`), so a wrapper that
    /// re-exports the constant under another name still trips this when it
    /// actually reads the payload.
    private static let colorChangeMarkers = ["GHOSTTY_ACTION_COLOR_CHANGE", ".color_change"]

    private static func nonCommentLines(_ contents: String) -> [Substring] {
        contents.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("OSC 11 color-change handling must route through the sanitizer")
    func colorChangeHandlingRequiresSanitizer() throws {
        try #require(
            !Self.swiftSources.isEmpty,
            "source scan found no Swift files under \(Self.sourcesRoot.path)"
        )
        for (path, contents) in Self.swiftSources {
            let codeLines = Self.nonCommentLines(contents)
            let handlesColorChange = codeLines.contains { line in
                Self.colorChangeMarkers.contains { line.contains($0) }
            }
            guard handlesColorChange else { continue }
            let callsSanitizer = codeLines.contains {
                $0.contains("sanitizedRuntimeBackgroundColor(")
            }
            #expect(
                callsSanitizer,
                """
                \(path) handles the runtime color-change action \
                (GHOSTTY_ACTION_COLOR_CHANGE / .color_change payload) without \
                calling sanitizedRuntimeBackgroundColor(...). A comment \
                mentioning the sanitizer does not count — the call must appear \
                on a code line. Runtime background reports are pty-writable and \
                must be clamped so focus cues never fall below the WCAG 3:1 \
                floor. See docs/adr/0013.
                """
            )
        }
    }

    @Test("terminalBackgroundColor is written only from the config build")
    func terminalBackgroundColorHasSingleConfigDerivedWriteSite() throws {
        let runtimePath = Self.sourcesRoot
            .appendingPathComponent("awesoMux/Services/GhosttyRuntime.swift").path
        let contents = try #require(
            Self.swiftSources.first { $0.path == runtimePath }?.contents,
            "GhosttyRuntime.swift not found in source scan"
        )

        // The single-write-site guard below only holds if the compiler
        // confines writes to this file in the first place.
        #expect(
            contents.contains("private(set) var terminalBackgroundColor"),
            """
            GhosttyRuntime.terminalBackgroundColor must stay private(set): the \
            single-write-site guard relies on the compiler confining writes to \
            GhosttyRuntime.swift. See docs/adr/0013.
            """
        )

        // Assignment (not `==` comparison), line-anchored, optional `self.`,
        // excluding the `var ... =` declaration default.
        let writePattern = /(?m)^\s*(?:self\.)?terminalBackgroundColor\s*=(?!=)/
        let writes = contents.matches(of: writePattern)
        #expect(
            writes.count == 1,
            """
            Expected exactly one terminalBackgroundColor write site (the \
            finalized-config read-back); found \(writes.count). New write sites \
            must keep the value config-derived or clamp runtime reports per \
            docs/adr/0013.
            """
        )

        // Provenance: the surviving write must sit in the config-build path —
        // after `makeGhosttyConfig`'s declaration, in the file that consumes
        // the `.built(` read-back — so deleting the config read-back and
        // adding a runtime write elsewhere cannot stay green.
        if let write = writes.first {
            let declaration = try #require(
                contents.range(of: "private func makeGhosttyConfig("),
                """
                makeGhosttyConfig declaration not found; the config-build seam \
                moved — update this guard so it keeps pinning the write to the \
                config path (docs/adr/0013)
                """
            )
            #expect(
                contents.contains(".built("),
                "config read-back anchor `.built(` missing from GhosttyRuntime.swift; see docs/adr/0013"
            )
            #expect(
                write.range.lowerBound > declaration.upperBound,
                """
                The terminalBackgroundColor write site no longer sits in the \
                config-build path (after makeGhosttyConfig). Focus-cue contrast \
                must stay keyed to the finalized config per docs/adr/0013.
                """
            )
        }
    }
}
