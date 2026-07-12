import Foundation
import Testing
@testable import AwesoMuxCore

@Suite
struct AgentRuntimeRenameEventTests {
    @Test
    func parsesRenameEventWithTitle() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","phase":"rename","title":"My Backend"}"#
        )
        #expect(event?.phase == .rename)
        #expect(event?.title == "My Backend")
    }

    @Test
    func parsesRenameEventWithEmptyTitleForReset() {
        let event = AgentRuntimeEvent.parse(
            line: #"{"v":1,"source":"claude-code","phase":"rename","title":""}"#
        )
        #expect(event?.phase == .rename)
        #expect(event?.title == "")
    }

    @Test
    func nonRenameEventHasNilTitle() {
        let event = AgentRuntimeEvent.parse(line: #"{"v":1,"source":"codex","phase":"stop"}"#)
        #expect(event?.title == nil)
    }
}
