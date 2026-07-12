import Testing
@testable import AwesoMuxCore

@Suite("Compact terminal identity")
struct CompactTerminalKindTests {
    @Test("compact surfaces share one shell startup marker")
    func sharedMarker() {
        #expect(CompactTerminalKind.spawnEnvironmentKey == "AWESOMUX_COMPACT_TERMINAL")
    }

    @Test("spawn markers distinguish regular, Floating, and Pop-up terminals")
    func spawnMarkerMatrix() {
        let regular = CompactTerminalKind.applyingSpawnMarkers(to: [:], kind: nil)
        let floating = CompactTerminalKind.applyingSpawnMarkers(to: [:], kind: .floatingPanel)
        let popUp = CompactTerminalKind.applyingSpawnMarkers(to: [:], kind: .popUpTerminal)

        #expect(regular[CompactTerminalKind.spawnEnvironmentKey] == nil)
        #expect(regular[FloatingPanelStoreFactory.spawnEnvironmentKey] == nil)
        #expect(floating[CompactTerminalKind.spawnEnvironmentKey] == "1")
        #expect(floating[FloatingPanelStoreFactory.spawnEnvironmentKey] == "1")
        #expect(popUp[CompactTerminalKind.spawnEnvironmentKey] == "1")
        #expect(popUp[FloatingPanelStoreFactory.spawnEnvironmentKey] == nil)
    }
}
