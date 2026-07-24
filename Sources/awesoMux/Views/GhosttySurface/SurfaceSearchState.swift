import Foundation
import Observation

@MainActor
@Observable
final class SurfaceSearchState {
    var isPresented = false
    var needle = ""
    var selected: Int?
    var total: Int?
    var focusRequestSerial = 0
    var scrollbackDumpText: String?

    var matchSummary: SurfaceSearchMatchSummary {
        SurfaceSearchMatchSummary(selected: selected, total: total)
    }

    var matchCountText: String {
        let summary = matchSummary
        return "\(summary.currentDisplayText) / \(summary.totalDisplay)"
    }

    var spokenSummary: String {
        matchSummary.spokenSummary
    }

    func present(needle: String? = nil) {
        isPresented = true
        if let needle {
            self.needle = needle
        }
        focusRequestSerial += 1
    }

    func hide() {
        isPresented = false
        needle = ""
        resetMatches()
    }

    func resetMatches() {
        selected = nil
        total = nil
    }

    func clearMatches() {
        selected = nil
        total = 0
    }

    func updateTotal(_ total: Int) {
        guard isPresented else { return }
        let clamped = max(0, total)
        guard clamped != self.total else { return }
        self.total = clamped
        if clamped == 0 {
            selected = nil
        }
    }

    func updateSelected(_ selected: Int) {
        guard isPresented else { return }
        let normalized: Int? = selected >= 0 ? selected : nil
        guard normalized != self.selected else { return }
        self.selected = normalized
    }

    func presentScrollbackDump(_ text: String) {
        scrollbackDumpText = text
    }

    func dismissScrollbackDump() {
        scrollbackDumpText = nil
    }
}

struct SurfaceSearchMatchSummary: Equatable {
    let selected: Int?
    let total: Int?

    var currentDisplay: Int {
        guard totalDisplay > 0, let selected, selected >= 0 else {
            return 0
        }
        return min(selected + 1, totalDisplay)
    }

    /// libghostty only selects a match once a `navigate_search` binding runs,
    /// so a fresh search reports matches with no current index. Render that
    /// state as "–" instead of a false "0", matching upstream ghostty's find
    /// bar (vendor/ghostty macos SurfaceView.SurfaceSearchOverlay), which
    /// shows "-/N" when no selection exists. Deliberate deviations: an en
    /// dash over upstream's hyphen, and "0 / 0" (not "-/0") for zero totals.
    var currentDisplayText: String {
        if totalDisplay > 0, !hasSelection {
            return "–"
        }
        return "\(currentDisplay)"
    }

    var totalDisplay: Int {
        max(0, total ?? 0)
    }

    var spokenSummary: String {
        guard totalDisplay > 0 else {
            return String(
                localized: "No matches",
                comment: "Spoken find-bar summary when a search finds nothing."
            )
        }
        guard hasSelection else {
            return LocalizedPluralStrings.surfaceSearchMatches(count: totalDisplay)
        }
        return String(
            localized: "Match \(currentDisplay) of \(totalDisplay)",
            comment:
                "Spoken find-bar position; arguments are the one-based current match and the match count."
        )
    }

    /// libghostty resets the total to zero on every needle change before the
    /// replacement search reports results, so a fast announcement would speak
    /// a false "No matches" while a slow search is still running. Zero-total
    /// summaries therefore wait longer; any result arriving in the interim
    /// reschedules the announcement with the corrected state.
    var announcementDelay: TimeInterval {
        totalDisplay > 0 ? 0.2 : 1.0
    }

    private var hasSelection: Bool {
        guard let selected else { return false }
        return selected >= 0
    }
}
