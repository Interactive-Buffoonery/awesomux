import AwesoMuxTestSupport
import Foundation
import Testing

/// Show Scrollback (⇧⌘F) was a dead menu item whenever the find bar was closed:
/// its sheet hung off a `Group { if searchState.isPresented { … } }` nested
/// inside a `Group { if let surfaceView { … } }`, and SwiftUI does not present
/// a sheet attached to a host that renders nothing.
///
/// Source-scraped on purpose. Whether a sheet presents is a property of the
/// hosted view hierarchy, and hosted-view tests in this repository have a
/// documented history of going vacuously green — a hosted replacement here
/// would be less trustworthy than this, not more.
@Suite("Surface search overlay sheet host (#3452)")
struct SurfaceSearchOverlaySheetHostTests {

    private static let path = "Sources/awesoMux/Views/GhosttySurface/SurfaceSearchOverlay.swift"

    /// One assertion, not two. Splitting "the base is positioned ahead of every
    /// conditional" from "a base somewhere in the file disables hit testing" let
    /// a bare `Color.clear` in the host plus a hit-test-disabled one anywhere
    /// else satisfy both while every terminal click was swallowed.
    @Test("the scrollback sheet's host is an inert unconditional base")
    func sheetHostIsUnconditionalAndInert() throws {
        let source = try SourceContract.source(at: Self.path)
        let type = try SourceContract.declarationBody(
            after: "private struct SurfaceSearchBar: View {",
            in: source,
            path: Self.path
        )
        let body = try SourceContract.declarationBody(
            after: "var body: some View {",
            in: type,
            path: "\(Self.path) (SurfaceSearchBar)"
        )
        let hostRegion = try #require(
            body.ranges(of: ".sheet(").first.map { body[..<$0.lowerBound] },
            "`SurfaceSearchBar.body` no longer attaches a `.sheet(`."
        )

        // Position, not presence: a base moved *inside* the `if` would still
        // appear in this region while the bug it guards against is back.
        //
        // Both patterns are regexes rather than substrings. `\s*` between the
        // modifiers tolerates `swift format` joining them onto one line, and
        // anchoring the conditional to the start of a line keeps a prose word
        // merely ending in "if" from masquerading as one.
        let base = try hostRegion.firstMatch(
            of: Regex(#"Color\.clear\s*\.allowsHitTesting\(false\)\s*\.accessibilityHidden\(true\)"#)
        )?.range.lowerBound
        let conditional = try hostRegion.firstMatch(
            of: Regex(#"(?m)^[ \t]*if\b"#)
        )?.range.lowerBound

        #expect(
            base != nil && (conditional == nil || base! < conditional!),
            """
            The scrollback sheet's host in `SurfaceSearchBar.body` is no longer an \
            unconditional, inert `Color.clear` base ahead of every conditional. \
            SwiftUI never presents a sheet attached to a view that renders \
            nothing, so with the find bar closed Show Scrollback (⇧⌘F) becomes a \
            silently dead menu item — and the base fills the terminal pane it is \
            overlaid on, so without `.allowsHitTesting(false)` every click on the \
            surface is eaten and without `.accessibilityHidden(true)` it is only \
            incidentally absent from the accessibility tree.
            """
        )
    }
}
