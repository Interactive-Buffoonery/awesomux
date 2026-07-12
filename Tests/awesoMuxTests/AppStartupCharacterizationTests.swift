import AppKit
import Foundation
import Testing
@testable import awesoMux

/// Characterization coverage for the app startup critical path — the existing
/// behavior of `AwesoMuxApp.swift`'s startup helpers, pinned before any future
/// extraction. INT-560 (phase-1): coverage only, no behavior change. Each test
/// drives an isolated `UserDefaults` suite so the suite-wide parallel runner
/// never races on `.standard`.
private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "awesomux.tests.startup.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

@Suite("Primary window frame persistence")
struct PrimaryWindowFramePersistenceTests {
    @Test("save then read round-trips the frame")
    func saveThenReadRoundTrips() {
        withIsolatedDefaults { defaults in
            let frame = CGRect(x: 120, y: 240, width: 1024, height: 768)
            PrimaryWindowFramePersistence.save(frame, to: defaults)
            #expect(PrimaryWindowFramePersistence.savedFrame(defaults) == frame)
        }
    }

    @Test("absent key reads as nil")
    func absentKeyReadsAsNil() {
        withIsolatedDefaults { defaults in
            #expect(PrimaryWindowFramePersistence.savedFrame(defaults) == nil)
        }
    }

    @Test("non-rect string reads as nil")
    func nonRectStringReadsAsNil() {
        withIsolatedDefaults { defaults in
            defaults.set("not a rect", forKey: PrimaryWindowFramePersistence.frameKey)
            // NSRectFromString yields a zero rect for garbage, which the
            // zero-size guard then rejects.
            #expect(PrimaryWindowFramePersistence.savedFrame(defaults) == nil)
        }
    }

    @Test("zero-size frame is rejected")
    func zeroSizeFrameIsRejected() {
        withIsolatedDefaults { defaults in
            let degenerate = CGRect(x: 10, y: 10, width: 0, height: 0)
            PrimaryWindowFramePersistence.save(degenerate, to: defaults)
            #expect(PrimaryWindowFramePersistence.savedFrame(defaults) == nil)
        }
    }

    @Test("non-finite frame is rejected")
    func nonFiniteFrameIsRejected() {
        withIsolatedDefaults { defaults in
            let infinite = CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 600)
            PrimaryWindowFramePersistence.save(infinite, to: defaults)
            #expect(PrimaryWindowFramePersistence.savedFrame(defaults) == nil)
        }
    }
}

@Suite("Settings defaults registration")
struct SettingsDefaultRegistrationTests {
    @Test("registration seeds documented startup defaults")
    func registrationSeedsDocumentedDefaults() {
        withIsolatedDefaults { defaults in
            // Registration backs the documented `SettingsDefault` values so a
            // non-`@AppStorage` reader sees them rather than the type zero value
            // (the INT-159 bug).
            //
            // `register(defaults:)` feeds `NSRegistrationDomain`, which Foundation
            // shares process-wide across every `UserDefaults` instance — a unique
            // suite name partitions the persistent domain, not the registration
            // domain. So this asserts only keys that no other test target
            // registers; `theme`/`notificationsMuted` are exercised below via the
            // persistent domain, which is genuinely suite-isolated and race-free.
            SettingsDefault.registerInitialValues(defaults)

            #expect(defaults.string(forKey: SettingsKey.accentColor) == SettingsDefault.accentColor)
            #expect(defaults.double(forKey: SettingsKey.glowStrength) == SettingsDefault.glowStrength)
            #expect(defaults.bool(forKey: SettingsKey.rememberToolTrust) == SettingsDefault.rememberToolTrust)
            #expect(defaults.bool(forKey: SettingsKey.respectDoNotDisturb) == SettingsDefault.respectDoNotDisturb)
            #expect(defaults.bool(forKey: SettingsKey.notificationSoundEnabled) == SettingsDefault.notificationSoundEnabled)
            #expect(defaults.bool(forKey: SettingsKey.outputMarksNeedsAttention) == SettingsDefault.outputMarksNeedsAttention)
            #expect(defaults.string(forKey: SettingsKey.defaultWorkspaceGroup) == SettingsDefault.defaultWorkspaceGroup)
            #expect(defaults.string(forKey: SettingsKey.updateChannel) == SettingsDefault.updateChannel)
        }
    }

    @Test("registration does not clobber an existing user value")
    func registrationDoesNotClobberExistingValue() {
        withIsolatedDefaults { defaults in
            // `register(defaults:)` only supplies fallbacks; an explicitly set
            // value must survive a later registration pass.
            defaults.set("dark", forKey: SettingsKey.theme)
            SettingsDefault.registerInitialValues(defaults)
            #expect(defaults.string(forKey: SettingsKey.theme) == "dark")
        }
    }
}
