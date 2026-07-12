import AwesoMuxConfig
import Foundation
import Testing
@testable import awesoMux

@Suite("Terminal appearance sync announcements")
@MainActor
struct TerminalAppearanceSyncTests {
    @Test("font size commit announces the new point size, not a generic message")
    func fontSizeCommitAnnouncesNewPointSize() {
        let old = TerminalAppearancePreferences(fontSize: 13)
        let new = TerminalAppearancePreferences(fontSize: 16)

        // The integer-size announcement resolves its plural form from
        // `Localizable.stringsdict`, which the SwiftPM test harness bundle
        // lacks — point the canonical bundle at the package resources.
        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                TerminalAppearanceSync.announcementMessage(from: old, to: new)
                    == "Font size updated to 16 points. Open terminal panes refreshed."
            )
        }
    }

    @Test("font size below the runtime floor announces the clamped value, not raw input")
    func fontSizeBelowRuntimeFloorAnnouncesClampedValue() {
        // A hand-edited disk config could set a value under `ghosttyFontSize`'s
        // 6...72 clamp; the announcement must speak the value libghostty
        // actually applied, not the unclamped struct field.
        let old = TerminalAppearancePreferences(fontSize: 13)
        let new = TerminalAppearancePreferences(fontSize: 1)

        LocalizedPluralStrings.withCanonicalBundle(Self.resourcesBundle) {
            #expect(
                TerminalAppearanceSync.announcementMessage(from: old, to: new)
                    == "Font size updated to 6 points. Open terminal panes refreshed."
            )
        }
    }

    @Test("fractional font size from a hand-edited config announces the exact applied value")
    func fractionalFontSizeAnnouncesExactAppliedValue() {
        let old = TerminalAppearancePreferences(fontSize: 13)
        let new = TerminalAppearancePreferences(fontSize: 13.5)

        // Format the expectation with the same locale-aware API the
        // implementation uses so the test doesn't assume "13.5" spelling.
        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Font size updated to \(13.5.formatted(.number.precision(.fractionLength(0...2)))) points. Open terminal panes refreshed."
        )
    }

    @Test("spoken fractional value agrees with the config writer at half-boundaries")
    func spokenFractionalValueAgreesWithConfigWriterAtHalfBoundaries() {
        // The config writer uses printf %.2f; the announcement uses
        // FormatStyle with 0...2 fraction digits. A review pass claimed the
        // two diverge at exactly-representable half-boundaries (13.125 →
        // "13.13" vs "13.12"); this pins that they agree, and fails if a
        // future OS/ICU change ever splits them.
        for boundary in [13.125, 13.375, 13.625, 13.875] {
            let old = TerminalAppearancePreferences(fontSize: 13)
            let new = TerminalAppearancePreferences(fontSize: boundary)
            let configSpelling = String(
                format: "%.2f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(new.ghosttyFontSize)
            )
            let expectedSpoken = Double(configSpelling)!
                .formatted(.number.precision(.fractionLength(0...2)))

            #expect(
                TerminalAppearanceSync.announcementMessage(from: old, to: new)
                    == "Font size updated to \(expectedSpoken) points. Open terminal panes refreshed."
            )
        }
    }

    @Test("fractional font size beyond config precision is spoken at the applied 2-digit precision")
    func fractionalFontSizeBeyondConfigPrecisionSpeaksAppliedPrecision() {
        // The ghostty config writer emits %.2f, so a hand-edited 13.333
        // applies as 13.33 — the announcement must say 13.33, neither the
        // raw 13.333 nor Float-widening noise.
        let old = TerminalAppearancePreferences(fontSize: 13)
        let new = TerminalAppearancePreferences(fontSize: 13.333)

        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Font size updated to \(13.33.formatted(.number.precision(.fractionLength(0...2)))) points. Open terminal panes refreshed."
        )
    }

    @Test("font family commit names the new family")
    func fontFamilyCommitNamesNewFamily() {
        let old = TerminalAppearancePreferences(monoFont: "Menlo")
        let new = TerminalAppearancePreferences(monoFont: "Hack Nerd Font Mono")

        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Font updated to Hack Nerd Font Mono. Open terminal panes refreshed."
        )
    }

    @Test("font family commit to the system sentinel announces a spoken name, not the raw sentinel")
    func fontFamilyCommitToSystemSentinelAnnouncesSpokenName() {
        let old = TerminalAppearancePreferences(monoFont: "Menlo")
        let new = TerminalAppearancePreferences(
            monoFont: TerminalAppearancePreferences.systemMonospaceFont
        )

        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Font updated to System default. Open terminal panes refreshed."
        )
    }

    @Test("font family rejected at the config boundary announces the default, not the raw garbage")
    func rejectedFontFamilyAnnouncesDefaultNotRawValue() {
        // Whitespace-only (and control-character) values are discarded by
        // `ghosttyFontFamily` before reaching libghostty — the announcement
        // must speak what was applied (no override), not the raw string.
        let old = TerminalAppearancePreferences(monoFont: "Menlo")
        let new = TerminalAppearancePreferences(monoFont: "   ")

        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Font updated to System default. Open terminal panes refreshed."
        )
    }

    @Test("raw-only font family change that applies nothing new announces nothing")
    func rawOnlyFontFamilyChangeAnnouncesNothing() {
        // " Menlo " trims to "Menlo" at the config boundary — same applied
        // family, nothing changed on screen, so any announcement would
        // report a state change that didn't happen.
        let old = TerminalAppearancePreferences(monoFont: "Menlo")
        let new = TerminalAppearancePreferences(monoFont: " Menlo ")

        #expect(TerminalAppearanceSync.announcementMessage(from: old, to: new) == nil)
    }

    @Test("raw font size change that clamps to the same applied value announces nothing")
    func clampCollapsedFontSizeChangeAnnouncesNothing() {
        // 100 and 80 both clamp to the 72pt ceiling — no applied change,
        // no announcement.
        let old = TerminalAppearancePreferences(fontSize: 100)
        let new = TerminalAppearancePreferences(fontSize: 80)

        #expect(TerminalAppearanceSync.announcementMessage(from: old, to: new) == nil)
    }

    @Test("non-font meaningful change keeps the generic announcement")
    func nonFontMeaningfulChangeKeepsGenericAnnouncement() {
        let old = TerminalAppearancePreferences(terminalBackgroundColor: "#1e1e2e")
        let new = TerminalAppearancePreferences(terminalBackgroundColor: "#eff1f5")

        #expect(
            TerminalAppearanceSync.announcementMessage(from: old, to: new)
                == "Terminal appearance updated"
        )
    }

    @Test("no meaningful change announces nothing")
    func noMeaningfulChangeAnnouncesNothing() {
        let preferences = TerminalAppearancePreferences(fontSize: 13)

        #expect(TerminalAppearanceSync.announcementMessage(from: preferences, to: preferences) == nil)
    }

    private static var resourcesBundle: Bundle {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
        return Bundle(url: url) ?? .main
    }
}
