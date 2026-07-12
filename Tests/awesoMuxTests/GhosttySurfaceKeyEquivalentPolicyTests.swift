import AppKit
import Testing
@testable import awesoMux

@Suite("GhosttyKeyEquivalentPolicy")
struct GhosttySurfaceKeyEquivalentPolicyTests {
    @Test("C-<return> passes through verbatim")
    func controlReturnPassesThrough() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "\r",
            characters: "\r",
            modifierFlags: [.control],
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .encode(equivalent: "\r"))
        #expect(result.lastPerformKeyEvent == nil)
    }

    @Test("plain return without control is ignored")
    func plainReturnIgnored() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "\r",
            characters: "\r",
            modifierFlags: [],
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .ignore)
    }

    @Test("C-/ is remapped to C-_ to avoid the system beep")
    func controlSlashRemapped() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "/",
            characters: "/",
            modifierFlags: [.control],
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .encode(equivalent: "_"))
    }

    @Test(
        "C-/ combined with other modifiers is ignored",
        arguments: [
            NSEvent.ModifierFlags([.control, .shift]),
            NSEvent.ModifierFlags([.control, .command]),
            NSEvent.ModifierFlags([.control, .option])
        ]
    )
    func controlSlashWithExtraModifiersIgnored(modifierFlags: NSEvent.ModifierFlags) {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "/",
            characters: "/",
            modifierFlags: modifierFlags,
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .ignore)
    }

    @Test("synthetic zero-timestamp events are ignored")
    func syntheticEventsIgnored() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: ".",
            characters: ".",
            modifierFlags: [.command],
            timestamp: 0,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .ignore)
    }

    @Test("non-command, non-control keys are ignored and clear stale state")
    func nonModifiedKeysIgnoredAndClearState() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "a",
            characters: "a",
            modifierFlags: [.shift],
            timestamp: 100,
            lastPerformKeyEvent: 42
        )

        #expect(result.decision == .ignore)
        #expect(result.lastPerformKeyEvent == nil)
    }

    @Test("first sighting of a command-modified key defers and stashes its timestamp")
    func firstSightingDefers() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "k",
            characters: "k",
            modifierFlags: [.command],
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .waitForResponderChain)
        #expect(result.lastPerformKeyEvent == 100)
    }

    @Test("control-modified key also defers (no command required)")
    func controlModifiedKeyDefers() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "k",
            characters: "k",
            modifierFlags: [.control],
            timestamp: 100,
            lastPerformKeyEvent: nil
        )

        #expect(result.decision == .waitForResponderChain)
        #expect(result.lastPerformKeyEvent == 100)
    }

    @Test("matching timestamp on the redispatched pass encodes the key")
    func matchingTimestampRedispatches() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "k",
            characters: "k",
            modifierFlags: [.command],
            timestamp: 100,
            lastPerformKeyEvent: 100
        )

        #expect(result.decision == .redispatch(equivalent: "k"))
        #expect(result.lastPerformKeyEvent == nil)
    }

    @Test("stale non-matching timestamp is dropped in favor of the new event")
    func staleTimestampReplacedByNewEvent() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "j",
            characters: "j",
            modifierFlags: [.command],
            timestamp: 200,
            lastPerformKeyEvent: 100
        )

        #expect(result.decision == .waitForResponderChain)
        #expect(result.lastPerformKeyEvent == 200)
    }

    @Test("redispatch falls back to empty string when characters is nil")
    func redispatchFallsBackToEmptyString() {
        let result = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: "k",
            characters: nil,
            modifierFlags: [.command],
            timestamp: 100,
            lastPerformKeyEvent: 100
        )

        #expect(result.decision == .redispatch(equivalent: ""))
    }
}
