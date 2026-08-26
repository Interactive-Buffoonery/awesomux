import AwesoMuxConfig
import Testing

@testable import awesoMux

@Suite("Empty workspace copy")
struct EmptyWorkspaceCopyTests {
    /// Deliberately NOT the default binding. `newWorkspace`'s default
    /// `displaySymbol` is literally "⌘N", so an assertion against the default
    /// passes just as happily for a hard-coded chord as for an interpolated
    /// one — the exact regression this suite exists to catch.
    private static let rebound = KeyboardShortcutCatalog.newWorkspace
        .applying(ShortcutBindingConfig(key: "j", modifiers: [.command, .shift]))

    @Test("First launch without reopen renders the resolved chord, never a literal")
    func firstLaunchWithoutReopen() {
        let copy = EmptyWorkspaceCopy.body(
            mode: .firstLaunch, canReopen: false, newWorkspace: Self.rebound)
        #expect(copy.visible.contains(Self.rebound.displaySymbol))
        #expect(copy.spoken.contains(Self.rebound.spokenForm))
        #expect(copy.visible.contains("Command-N") == false)
        #expect(copy.visible.contains("⌘N") == false)
    }

    @Test("First launch with reopen renders the resolved chord, never a literal")
    func firstLaunchWithReopen() {
        let copy = EmptyWorkspaceCopy.body(
            mode: .firstLaunch, canReopen: true, newWorkspace: Self.rebound)
        #expect(copy.visible.contains(Self.rebound.displaySymbol))
        #expect(copy.spoken.contains(Self.rebound.spokenForm))
        #expect(copy.visible.contains("Command-N") == false)
        #expect(copy.visible.contains("⌘N") == false)
    }

    @Test("Recovered renders the resolved chord, never a literal")
    func recovered() {
        let copy = EmptyWorkspaceCopy.body(
            mode: .recovered, canReopen: false, newWorkspace: Self.rebound)
        #expect(copy.visible.contains(Self.rebound.displaySymbol))
        #expect(copy.spoken.contains(Self.rebound.spokenForm))
        #expect(copy.visible.contains("Command-N") == false)
        #expect(copy.visible.contains("⌘N") == false)
    }
}
