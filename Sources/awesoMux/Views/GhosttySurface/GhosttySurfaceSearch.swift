import AppKit
import GhosttyKit

enum SurfaceSearchNavigationDirection {
    case previous
    case next

    var bindingValue: String {
        switch self {
        case .previous: "previous"
        case .next: "next"
        }
    }
}

extension GhosttySurfaceNSView {
    func presentSearch() {
        if !performBindingAction("start_search") {
            searchState.present()
        }
    }

    func updateSearchNeedle(_ needle: String) {
        searchNeedleWorkItem?.cancel()
        searchNeedleWorkItem = nil

        guard !needle.isEmpty else {
            searchState.clearMatches()
            performSearchBinding(needle: needle)
            return
        }

        guard needle.count < 3 else {
            performSearchBinding(needle: needle)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.searchNeedleWorkItem = nil
                guard self.searchState.needle == needle else { return }
                self.performSearchBinding(needle: needle)
            }
        }
        searchNeedleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.searchNeedleDebounceInterval,
            execute: workItem
        )
    }

    func navigateSearch(_ direction: SurfaceSearchNavigationDirection) {
        if performBindingAction("navigate_search:\(direction.bindingValue)") {
            // A manual navigation owns the current search's position: without
            // consuming the one-shot, a total arriving after the user's
            // navigate but before its SEARCH_SELECTED returns would
            // auto-navigate a second time and land on match 2.
            didAutoSelectCurrentSearch = true
        }
    }

    func endSearch() {
        searchNeedleWorkItem?.cancel()
        searchNeedleWorkItem = nil
        lastSearchedNeedle = nil
        didAutoSelectCurrentSearch = false
        performBindingAction("end_search")
        searchState.hide()
        window?.makeFirstResponder(self)
    }

    func updateSearchTotal(_ total: Int) {
        searchState.updateTotal(total)
        autoSelectFirstMatchIfNeeded()
    }

    /// macOS find bars (Safari, Terminal) select the first match as you type;
    /// libghostty only selects on an explicit `navigate_search`, so issue one
    /// when fresh results arrive with no selection. Re-entrant binding action
    /// from inside the SEARCH_TOTAL callback follows the `updateSearchStarted`
    /// precedent (ghostty's navigate only pushes to the search-thread
    /// mailbox). The one-shot is consumed only when ghostty accepts the
    /// action, so a rejected binding (surface gone, search already ended)
    /// cannot burn the attempt. A stale total from a superseded query can
    /// trigger this early for the new query — every such race converges to
    /// selecting the new query's first match or a no-op (navigate with no
    /// results returns without emitting a selection).
    private func autoSelectFirstMatchIfNeeded() {
        guard
            Self.shouldAutoSelectFirstMatch(
                total: searchState.total,
                selected: searchState.selected,
                alreadyRequested: didAutoSelectCurrentSearch
            )
        else { return }
        if performBindingAction(
            "navigate_search:\(SurfaceSearchNavigationDirection.next.bindingValue)"
        ) {
            didAutoSelectCurrentSearch = true
        }
    }

    static func shouldAutoSelectFirstMatch(
        total: Int?,
        selected: Int?,
        alreadyRequested: Bool
    ) -> Bool {
        guard !alreadyRequested, selected == nil, let total, total > 0 else {
            return false
        }
        return true
    }

    func updateSearchSelected(_ selected: Int) {
        searchState.updateSelected(selected)
    }

    func updateSearchStarted(needle: String?) {
        if let needle, !needle.isEmpty {
            searchNeedleWorkItem?.cancel()
            searchNeedleWorkItem = nil
            searchState.present(needle: needle)
            performSearchBinding(needle: needle)
            return
        }

        if searchState.isPresented, needle?.isEmpty != false {
            searchState.present()
        } else {
            searchState.present(needle: needle)
        }
    }

    func updateSearchEnded() {
        searchNeedleWorkItem?.cancel()
        searchNeedleWorkItem = nil
        lastSearchedNeedle = nil
        didAutoSelectCurrentSearch = false
        searchState.hide()
    }

    func presentScrollbackDump() {
        guard searchState.scrollbackDumpText == nil,
            !runtime.isScrollbackDumpSheetPresented
        else {
            return
        }
        searchState.presentScrollbackDump(fullScrollbackText())
        runtime.setScrollbackDumpSheetPresented(true, for: paneID)
    }

    func dismissScrollbackDump() {
        searchState.dismissScrollbackDump()
        runtime.setScrollbackDumpSheetPresented(false, for: paneID)
    }

    func resetSearchStateForSurfaceTeardown() {
        searchNeedleWorkItem?.cancel()
        searchNeedleWorkItem = nil
        lastSearchedNeedle = nil
        didAutoSelectCurrentSearch = false
        if searchState.scrollbackDumpText != nil {
            dismissScrollbackDump()
        }
        searchState.hide()
    }

    func fullScrollbackText() -> String {
        guard let surface else {
            return ""
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }

        return String(cString: text.text)
    }

    private func performSearchBinding(needle: String) {
        guard needle != lastSearchedNeedle else { return }
        lastSearchedNeedle = needle
        // Reset AFTER the dedupe guard: only a genuinely issued search re-arms
        // the auto-select one-shot (a duplicate needle echo must not).
        didAutoSelectCurrentSearch = false
        performBindingAction("search:\(needle)")
    }
}
