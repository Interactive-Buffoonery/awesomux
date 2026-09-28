import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct PaneColorCodableTests {

    @Test
    func unknownKindThrows() {
        // A future build's `.theme` value read by this build: the Kind decode
        // fails, which the pane-level tolerant decoder turns into nil.
        let json = #"{"kind":"theme","name":"whatever"}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(PaneColor.self, from: Data(json.utf8))
        }
    }

    @Test
    func paneMissingColorKeyDecodesNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"shell","workingDirectory":"~","unreadNotificationCount":0}"#
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))
        #expect(decoded.color == nil)
    }

    @Test
    func paneWithCorruptColorDecodesNilNotThrow() throws {
        // A hand-edited/forward snapshot must not fail the whole pane decode.
        let json = #"{"id":"\#(UUID().uuidString)","title":"shell","workingDirectory":"~","unreadNotificationCount":0,"color":{"kind":"theme","name":"x"}}"#
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))
        #expect(decoded.color == nil)
    }

    @Test
    func paneWithFuturePaletteNameDecodesNilNotThrow() throws {
        // The realistic forward path: a *known* `kind` (palette) carrying a `name`
        // from a WorkspaceGroupColor case a newer build added (here "coral"). The
        // synthesized WorkspaceGroupColor decode throws inside PaneColor; the pane's
        // tolerant decoder must turn that into nil, not quarantine the snapshot.
        let json = #"{"id":"\#(UUID().uuidString)","title":"shell","workingDirectory":"~","unreadNotificationCount":0,"color":{"kind":"palette","name":"coral"}}"#
        let decoded = try JSONDecoder().decode(TerminalPane.self, from: Data(json.utf8))
        #expect(decoded.color == nil)
    }
}
