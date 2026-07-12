import Foundation
import Testing
@testable import awesoMux

@Suite("Ghostty fault log source")
struct GhosttyFaultLogSourceTests {
    @Test("OSLogGhosttyFaultSource conforms to GhosttyFaultLogSource and does not throw on an empty window")
    func conformsAndDoesNotThrow() {
        let source: GhosttyFaultLogSource = OSLogGhosttyFaultSource()
        let count = source.recentFaultCount(
            subsystem: "com.mitchellh.ghostty",
            category: "libxev_kqueue",
            since: Date().addingTimeInterval(-1)
        )
        #expect(count >= 0)
    }
}
