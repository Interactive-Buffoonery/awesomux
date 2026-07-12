import Testing
@testable import awesoMux

@MainActor
@Suite("Ghostty event loop wedge alert")
struct GhosttyRuntimeEventLoopWedgeAlertTests {
    @Test("presentEventLoopWedgeAlert body names the terminal engine, not internal implementation details")
    func alertBodyIsUserFacing() {
        let body = GhosttyRuntime.eventLoopWedgeAlertBody
        #expect(!body.isEmpty)
        #expect(!body.contains("libxev"))
        #expect(!body.contains("kqueue"))
    }
}
