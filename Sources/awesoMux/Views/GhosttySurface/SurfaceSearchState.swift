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

    var matchCountText: String {
        let summary = SurfaceSearchMatchSummary(selected: selected, total: total)
        return "\(summary.currentDisplay) / \(summary.totalDisplay)"
    }

    var spokenSummary: String {
        SurfaceSearchMatchSummary(selected: selected, total: total).spokenSummary
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
        self.total = max(0, total)
        if self.total == 0 {
            selected = nil
        }
    }

    func updateSelected(_ selected: Int) {
        guard isPresented else { return }
        self.selected = selected >= 0 ? selected : nil
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

    var totalDisplay: Int {
        max(0, total ?? 0)
    }

    var spokenSummary: String {
        guard totalDisplay > 0 else {
            return "No matches"
        }
        return "Match \(currentDisplay) of \(totalDisplay)"
    }
}
