import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct PaneColorCodableTests {

    @Test(
        "bad colors degrade to nil without losing the snapshot",
        arguments: [
            (true, #"{"kind":"theme","name":"x"}"#),
            (true, #"{"kind":"palette","name":"coral"}"#),
            (true, #""ultraviolet""#),
            (false, #""ultraviolet""#),
            (false, #"{"unexpected":"shape"}"#),
        ])
    func badColor(paneColor: Bool, colorJSON: String) throws {
        let paneID = UUID()
        let json = """
            {"groups":[{"id":"\(UUID())","name":"main",\(paneColor ? "" : "\"color\":\(colorJSON),")"sessions":[
            {"id":"\(UUID())","title":"shell","workingDirectory":"~","layout":{"pane":{"_0":{
            "id":"\(paneID)","title":"shell","workingDirectory":"~"\(paneColor ? ",\"color\":\(colorJSON)" : "")
            }}}}]}]}
            """
        let snapshot = try SessionSnapshot.decode(from: Data(json.utf8))
        let group = try #require(snapshot.groups.first)
        let pane = try #require(group.sessions.first?.layout.pane(id: paneID))
        #expect(group.color == nil)
        #expect(pane.color == nil)
        #expect(group.sessions.count == 1)
    }
}
