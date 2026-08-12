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

    @Test("the scrollback sheet's host is unconditional")
    func sheetHostIsUnconditional() throws {
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

        // Position, not presence: a `Color.clear` moved *inside* the `if` would
        // still appear in this region while the bug it guards against is back.
        let base = hostRegion.ranges(of: "Color.clear").first?.lowerBound
        let conditional = hostRegion.ranges(of: "if ").first?.lowerBound

        #expect(
            base != nil && (conditional == nil || base! < conditional!),
            """
            The scrollback sheet's host in `SurfaceSearchBar.body` is conditional \
            again. SwiftUI never presents a sheet attached to a view that renders \
            nothing, so with the find bar closed Show Scrollback (⇧⌘F) becomes a \
            silently dead menu item. Keep an unconditional view — a `Color.clear` \
            base — in the host, ahead of every `if`.
            """
        )
    }

    @Test("the clear base cannot swallow terminal clicks")
    func clearBasesDisableHitTesting() throws {
        // All whitespace stripped, not collapsed: `swift format` may join these
        // onto one line, leaving zero whitespace between them.
        let source = try SourceContract.source(at: Self.path)
            .replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)

        #expect(
            source.ranges(of: "Color.clear.allowsHitTesting(false)").count == 1,
            """
            The sheet-host `Color.clear` in \(Self.path) lost its \
            `.allowsHitTesting(false)`. It fills the terminal pane it is \
            overlaid on, so without it every click on the surface is eaten.
            """
        )
    }
}
