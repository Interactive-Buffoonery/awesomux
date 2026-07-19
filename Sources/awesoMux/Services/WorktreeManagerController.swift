import AppKit
import AwesoMuxConfig
import Observation
import SwiftUI

@MainActor
@Observable
final class WorktreeManagerController {
    @ObservationIgnored private var panel: FloatingSwiftUIPanelWindow?
    @ObservationIgnored private var isDismissing = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    // Cancellation is cooperative: a cancelled task's `await model?.refresh()`
    // keeps running until IT checks cancellation, which `refresh()` never
    // does. Without this token, a stale task from a rapid dismiss-then-show
    // could finish after a newer one starts, clear `refreshTask` out from
    // under it (breaking `hasPendingRefresh`/`waitForPendingRefresh`), and
    // announce ITS result against the panel now showing a different model.
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private weak var activeModel: WorktreeManagerModel?
    @ObservationIgnored var appSettingsStore: AppSettingsStore?

    private(set) var isVisible = false
    var hasPendingRefresh: Bool { refreshTask != nil }

    /// Awaits the in-flight `show()` refresh, if any. Exists so tests can
    /// observe completion deterministically instead of polling `hasPendingRefresh`
    /// across a fixed number of yields — a bounded poll loop loses the race
    /// under real scheduler load (confirmed flaky in the full suite, not just
    /// the filtered run).
    func waitForPendingRefresh() async {
        await refreshTask?.value
    }

    // Rows are branch-name-first with a secondary condensed path, not the
    // full absolute path at row width — 780pt was sized for the latter and
    // read as near-full-window on a typical app window. Matches
    // `FloatingPanelLayout.defaultSize`'s width, the repo's other narrow
    // floating-panel default.
    static let defaultSize = CGSize(width: 640, height: 520)
    private static let screenInset: CGFloat = 16

    func toggle(model: WorktreeManagerModel, relativeTo parentWindow: NSWindow?) {
        if isVisible {
            dismiss()
        } else {
            show(model: model, relativeTo: parentWindow)
        }
    }

    func show(model: WorktreeManagerModel, relativeTo parentWindow: NSWindow?, presentingCreateForm: Bool = false) {
        // A menu/palette re-invoke while already showing this SAME model is
        // just "bring back to front" — not a fresh presentation — so it
        // must not clobber a manually-repositioned panel out from under the
        // user (INT-857 review: toggle→show fixed dismiss-on-reinvoke but
        // regressed this).
        let isReshowingSameModel = isVisible && activeModel === model
        activeModel = model
        if presentingCreateForm {
            model.pendingCreatePresentation = true
        }
        // Refresh/create errors and results are otherwise visual-only —
        // announcements on a non-key window are dropped, so route them
        // through the panel element (same pattern as SessionManagerController).
        model.announce = { [weak self] message in
            self?.postAnnouncement(message)
        }
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        panel.hostSwiftUIContent(makeRootView(model: model))
        if !isReshowingSameModel {
            position(panel, relativeTo: parentWindow)
        }
        panel.presentAndFocus()
        isVisible = true
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { [weak self, weak model] in
            await model?.refresh()
            guard let self, self.refreshGeneration == generation else { return }
            self.refreshTask = nil
        }
    }

    func dismiss() {
        guard activeModel?.createSubmissionState.isSubmitting != true else { return }
        guard !isDismissing else { return }
        isDismissing = true
        isVisible = false
        refreshTask?.cancel()
        refreshTask = nil
        panel?.orderOut(nil)
        activeModel = nil
        isDismissing = false
    }

    @ViewBuilder
    private func makeRootView(model: WorktreeManagerModel) -> some View {
        let root = WorktreeManagerPanel(
            model: model,
            onDismiss: { [weak self] in self?.dismiss() }
        )
        if let appSettingsStore {
            root.appearanceBridge(appSettingsStore)
        } else {
            root
        }
    }

    private func makePanel(model: WorktreeManagerModel) -> FloatingSwiftUIPanelWindow {
        let panel = FloatingSwiftUIPanelWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            backing: .buffered,
            defer: false
        )
        panel.hostSwiftUIContent(makeRootView(model: model))
        panel.title = String(localized: "Worktree Manager", comment: "Worktree Manager panel title.")
        panel.setAccessibilityLabel(
            String(localized: "Worktree Manager", comment: "Worktree Manager accessibility title."))
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.handlesKeyEvent = { [weak panel] event in
            if FloatingPanelEventPolicy.isDismissChord(
                type: event.type,
                keyCode: event.keyCode,
                isARepeat: event.isARepeat,
                modifiers: event.modifierFlags
            ) || FloatingPanelEventPolicy.isCloseChord(event) {
                panel?.onDismiss?()
                return true
            }
            return false
        }
        return panel
    }

    private func position(
        _ panel: FloatingSwiftUIPanelWindow,
        relativeTo anchorWindow: NSWindow?
    ) {
        let screenFrame =
            anchorWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        guard let screenFrame else {
            panel.center()
            return
        }
        let inset = Self.screenInset
        let size = CGSize(
            width: min(Self.defaultSize.width, max(0, screenFrame.width - inset * 2)),
            height: min(Self.defaultSize.height, max(0, screenFrame.height - inset * 2))
        )
        panel.setFixedContentSize(size)
        let reference = anchorWindow?.frame ?? screenFrame
        let minX = screenFrame.minX + inset
        let minY = screenFrame.minY + inset
        panel.setFrameOrigin(
            CGPoint(
                x: min(max(reference.midX - size.width / 2, minX), max(minX, screenFrame.maxX - size.width - inset)),
                y: min(max(reference.midY - size.height / 2, minY), max(minY, screenFrame.maxY - size.height - inset))
            ))
        panel.invalidateShadow()
    }

    private func postAnnouncement(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}
