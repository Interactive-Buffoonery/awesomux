import AwesoMuxAppKitTestHost
import Foundation
import Testing

@Suite("Sidebar native test host")
@MainActor
struct SidebarAppKitTestHostTests {
    @Test(
        "the requested native host is linked and running",
        .enabled(
            if: ProcessInfo.processInfo.environment["AWESOMUX_APPKIT_TEST_HOST"] == "1",
            "enabled by the sidebar shard"
        )
    )
    func nativeHostIsRunning() {
        #expect(awesomuxAppKitTestHostIsRunning())
    }
}
