import Testing
@testable import awesoMux

@Suite("JumpNumberDisplay")
struct JumpNumberDisplayTests {
    @Test("expanded mode never shows numbers")
    func expandedHidesAlways() {
        #expect(JumpNumberDisplay.resolve(collapsed: false, alwaysOn: false, commandHeld: false) == .hidden)
        #expect(JumpNumberDisplay.resolve(collapsed: false, alwaysOn: true, commandHeld: true) == .hidden)
    }
    @Test("collapsed default reveals only while command is held")
    func collapsedDefaultRevealsOnCommand() {
        #expect(JumpNumberDisplay.resolve(collapsed: true, alwaysOn: false, commandHeld: false) == .hidden)
        #expect(JumpNumberDisplay.resolve(collapsed: true, alwaysOn: false, commandHeld: true) == .overlay)
    }
    @Test("always-on pins numbers below the tile, command does not change that")
    func alwaysOnPinsBelow() {
        #expect(JumpNumberDisplay.resolve(collapsed: true, alwaysOn: true, commandHeld: false) == .belowTile)
        #expect(JumpNumberDisplay.resolve(collapsed: true, alwaysOn: true, commandHeld: true) == .belowTile)
    }
}
