import Foundation
import Testing
@testable import awesoMux

/// INT-164: `SettingsDefault.resolvedUpdateChannel` is the intended
/// validated read path for `SettingsKey.updateChannel` (see the doc comment
/// there), so a poisoned/stale UserDefaults value can be rejected instead of
/// propagating as a raw string once a real updater consumer reads this key.
/// Each test drives an isolated `UserDefaults` suite so the suite-wide
/// parallel runner never races on `.standard`.
private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "awesomux.tests.updatechannel.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

@Suite("SettingsDefault.resolvedUpdateChannel")
struct ResolvedUpdateChannelTests {
    @Test("unregistered key falls back to the static default, without requiring registerInitialValues to have run")
    func unregisteredKeyUsesStaticDefault() {
        withIsolatedDefaults { defaults in
            // Deliberately skips `SettingsDefault.registerInitialValues` —
            // in production it always runs before any consumer reads the
            // key, but the resolver must not depend on that ordering.
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .stable)
        }
    }

    @Test("explicit stable round-trips via the enum's rawValue")
    func explicitStableRoundTripsViaRawValue() {
        withIsolatedDefaults { defaults in
            defaults.set(UpdateChannel.stable.rawValue, forKey: SettingsKey.updateChannel)
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .stable)
        }
    }

    @Test("explicit beta round-trips via the enum's rawValue")
    func explicitBetaRoundTripsViaRawValue() {
        withIsolatedDefaults { defaults in
            defaults.set(UpdateChannel.beta.rawValue, forKey: SettingsKey.updateChannel)
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .beta)
        }
    }

    @Test("explicit stable round-trips via the literal persisted string")
    func explicitStableRoundTripsViaLiteralString() {
        withIsolatedDefaults { defaults in
            // Exercises the actual on-disk plist contract directly, not just
            // values the enum itself produced — catches a future case rename
            // silently changing what's read back (see UpdateChannel's doc
            // comment on its pinned raw values).
            defaults.set("stable", forKey: SettingsKey.updateChannel)
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .stable)
        }
    }

    @Test("explicit beta round-trips via the literal persisted string")
    func explicitBetaRoundTripsViaLiteralString() {
        withIsolatedDefaults { defaults in
            defaults.set("beta", forKey: SettingsKey.updateChannel)
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .beta)
        }
    }

    @Test("malformed value falls back to stable")
    func malformedValueFallsBackToStable() {
        withIsolatedDefaults { defaults in
            defaults.set("nightly-canary-typo", forKey: SettingsKey.updateChannel)
            #expect(SettingsDefault.resolvedUpdateChannel(from: defaults) == .stable)
        }
    }
}
