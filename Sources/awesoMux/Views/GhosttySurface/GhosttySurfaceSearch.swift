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
        guard !runtime.isScrollbackDumpSheetPresented,
            let request = searchState.beginScrollbackDump()
        else {
            return
        }
        runtime.setScrollbackDumpSheetPresented(true, for: paneID)

        let initial = scrollbackDumpPolicyInput()
        switch ScrollbackDumpPolicy.decision(for: initial) {
        case .allow:
            scheduleScrollbackDumpRead(request: request)
        case let .block(reason):
            finishBlockedScrollbackDump(reason: reason, request: request)
        }
    }

    func dismissScrollbackDump(restoringFocus: Bool = true) {
        scrollbackDumpWorkItem?.cancel()
        scrollbackDumpWorkItem = nil
        searchState.dismissScrollbackDump()
        runtime.setScrollbackDumpSheetPresented(false, for: paneID)
        if restoringFocus {
            window?.makeFirstResponder(self)
        }
    }

    func resetSearchStateForSurfaceTeardown() {
        searchNeedleWorkItem?.cancel()
        searchNeedleWorkItem = nil
        lastSearchedNeedle = nil
        didAutoSelectCurrentSearch = false
        if searchState.scrollbackDump != nil {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "The pane changed, so Show Scrollback was canceled. Try again.",
                    comment: "VoiceOver announcement when a terminal surface is replaced while Show Scrollback is loading"
                )
            )
            dismissScrollbackDump(restoringFocus: false)
        }
        searchState.hide()
    }

    private func scheduleScrollbackDumpRead(
        request: UInt64
    ) {
        let expectedSurface = surface
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrollbackDumpWorkItem = nil
                guard self.searchState.isCurrentScrollbackDumpRequest(request) else {
                    return
                }
                guard self.surface == expectedSurface,
                    self.runtime.cachedSurfaceView(for: self.paneID) === self
                else {
                    self.dismissScrollbackDump()
                    return
                }

                let current = self.scrollbackDumpPolicyInput()
                switch ScrollbackDumpPolicy.decision(for: current) {
                case let .block(reason):
                    self.finishBlockedScrollbackDump(reason: reason, request: request)
                case .allow:
                    Task { @MainActor [self] in
                        guard self.searchState.isCurrentScrollbackDumpRequest(request),
                            self.surface == expectedSurface,
                            let surface = self.surface
                        else { return }
                        let result = await self.fullScrollbackText(surface: surface)
                        guard self.searchState.isCurrentScrollbackDumpRequest(request),
                            self.surface == expectedSurface,
                            self.runtime.cachedSurfaceView(for: self.paneID) === self
                        else { return }
                        switch result {
                        case let .loaded(text):
                            self.searchState.finishScrollbackDump(.loaded(text: text), request: request)
                        case .tooLarge:
                            self.finishBlockedScrollbackDump(reason: .nativeResultTooLarge, request: request)
                        case .busy:
                            self.finishBlockedScrollbackDump(reason: .readInProgress, request: request)
                        case .failed:
                            self.searchState.finishScrollbackDump(.failed, request: request)
                        }
                    }
                }
            }
        }
        scrollbackDumpWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func scrollbackDumpPolicyInput() -> ScrollbackDumpPolicy.Input {
        guard let surface else {
            return .init(
                totalRows: nil,
                currentColumns: 0,
                widestObservedColumns: widestObservedScrollbackColumns
            )
        }
        let size = ghostty_surface_size(surface)
        let columns = UInt64(size.columns)
        widestObservedScrollbackColumns = max(widestObservedScrollbackColumns, columns)
        return .init(
            totalRows: scrollbar?.total,
            currentColumns: columns,
            widestObservedColumns: widestObservedScrollbackColumns
        )
    }

    private func finishBlockedScrollbackDump(
        reason: ScrollbackDumpPolicy.BlockReason,
        request: UInt64
    ) {
        Self.terminalDiagnosticsLogger.info(
            "scrollback-dump blocked reason=\(String(describing: reason), privacy: .public) pane=\(self.paneID.uuidString.prefix(8), privacy: .public)"
        )
        searchState.finishScrollbackDump(
            .blocked(reason: reason),
            request: request
        )
    }

    private func fullScrollbackText(surface: ghostty_surface_t) async -> ScrollbackDumpReader.Result {
        // Only the worker dereferences this address. The coordinator defers
        // surface free and app reload until it has returned to the main actor.
        let address = UInt(bitPattern: surface)
        let limits = ScrollbackDumpPolicy.Limits.default
        return await runtime.scrollbackReadCoordinator.read(surfaceID: address) {
            ScrollbackDumpReader.read(maximumBytes: Int(limits.maximumNativeTextBytes)) { buffer, written in
                awesomux_surface_read_scrollback(
                    UnsafeMutableRawPointer(bitPattern: address),
                    Int(limits.maximumRows),
                    Int(limits.maximumEstimatedBytes / limits.estimatedBytesPerCell),
                    ScrollbackDumpPolicy.maximumNativePageBytes,
                    buffer.baseAddress!,
                    buffer.count,
                    &written
                )
            }
        }
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
