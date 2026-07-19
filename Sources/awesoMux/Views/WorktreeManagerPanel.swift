import AwesoMuxCore
import DesignSystem
import SwiftUI

@MainActor
struct WorktreeManagerPanel: View {
    // NOT `@State`: `model` is owned and swapped by `WorktreeManagerController`
    // (a new `WorktreeManagerModel` per repository, see
    // `AwesoMuxApp.refreshWorktreeRepositoryContext()`), and the controller
    // reuses the SAME hosting view across `show()` calls rather than
    // recreating it — `@State`'s initializer only seeds storage on a view
    // identity's FIRST appearance, so a later `show()` with a genuinely
    // different model would have silently kept rendering the OLD one. A
    // plain property picks up whatever `model` the hosting reassignment
    // hands it, every time (INT-857 round-7 smoke).
    let model: WorktreeManagerModel
    let onDismiss: () -> Void
    // Controlled-clock seam (deterministic-guard requirement: new sleeps
    // outside Tests/ need an injection point, not a bare wait) — production
    // keeps the real wait, a test can substitute a gate. Matches this
    // codebase's own `TerminalPathBarProcess.Delay` convention.
    var sleep: @Sendable (Duration) async -> Void = { try? await ContinuousClock().sleep(for: $0) }
    @State private var openError: String?
    @State private var isShowingCreateForm = false
    // The panel window is reused across `show()` calls (see
    // `WorktreeManagerController`), so the `.sheet` content below keeps its
    // SwiftUI identity across a dismiss-then-represent cycle and its `@State`
    // (branch name, target path, validation message) survives with it. A
    // fresh token per presentation forces `WorktreeCreateForm` to rebuild
    // from scratch every time instead of reopening with the PREVIOUS
    // presentation's leftover fields (INT-857 round-7 smoke).
    @State private var createFormPresentationToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.aw.surface.window)
        .clipShape(RoundedRectangle(cornerRadius: AwRadius.window))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.window)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            FloatingPanelCloseButton(
                accessibilityLabel: String(
                    localized: "Close Worktree Manager",
                    comment: "Accessibility label for the Worktree Manager close button."
                ),
                action: {
                    guard !model.createSubmissionState.isSubmitting else { return }
                    onDismiss()
                }
            )
            .padding(.top, 12)
            .padding(.trailing, FloatingPanelChromeMetrics.closeButtonEdgeInset)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            String(localized: "Worktree Manager", comment: "Worktree Manager panel accessibility label.")
        )
        .sheet(isPresented: $isShowingCreateForm, onDismiss: model.resetCreateResult) {
            WorktreeCreateForm(model: model) { isShowingCreateForm = false }
                .id(createFormPresentationToken)
        }
        // `.task(id:)`, not `.onChange` — the palette's "Create Worktree…"
        // route sets the flag before this view ever mounts, and `.onChange`
        // only fires on a later flip, not on the value a fresh mount starts
        // with. Self-resets `pendingCreatePresentation`, so this also
        // re-fires (harmlessly, guarded) on the id's return trip to `false`.
        .task(id: model.pendingCreatePresentation) {
            guard model.pendingCreatePresentation else { return }
            model.pendingCreatePresentation = false
            // The palette's "Create Worktree…" route calls `show(...,
            // presentingCreateForm: true)` even while this sheet is ALREADY
            // open (`presentWorktreeCreateForm()`'s own `isAnySheetPresented`
            // guard doesn't see into this floating panel's sheet) — minting a
            // fresh presentation token in that case would silently discard
            // whatever the user already typed. Only (re)present when it's
            // not already up; already-open just no-ops, leaving the form and
            // its in-progress fields alone (INT-857 round-7 smoke).
            guard !isShowingCreateForm else { return }
            model.resetCreateResult()
            createFormPresentationToken = UUID()
            isShowingCreateForm = true
        }
        // Round-6 smoke: "After the worktree is created and opened we should
        // close this window." Focus already moved to the new workspace
        // behind the sheet — leaving it (and the panel) open just to show a
        // banner nobody's looking at is dead weight. The failure path is
        // untouched: only `.opened` closes anything, the sheet stays put
        // with the error otherwise. Brief delay so the success text is
        // actually readable before both windows go away.
        // `model` is reassigned by the controller across `show()` calls but
        // this hosted view (and its `@State`) is reused, not recreated —
        // same reason `createFormPresentationToken` exists above. Without
        // this, `openError` from a PRIOR model's failed Open survives into
        // whatever model gets hosted next: the controller's OWN automatic
        // refresh in `show()` doesn't route through `refreshClearingOpenError()`
        // (that only covers this view's own Refresh/Retry buttons), and even
        // if it did, `.onChange(of: model.state)` wouldn't reliably fire here
        // — a refresh landing on the SAME rows is a no-op state change.
        // Keying on the model's own identity clears it the instant a
        // genuinely different model gets hosted, before any refresh even
        // runs (INT-857 review).
        .task(id: ObjectIdentifier(model)) {
            openError = nil
        }
        .onChange(of: model.createSubmissionState) { _, newValue in
            guard case .result(.opened) = newValue else { return }
            // Capture the presentation this success belongs to: if the user
            // dismisses and reopens the create form inside the 700ms window
            // (`try? await Task.sleep` swallows cancellation, so a plain
            // `Task { }` here doesn't stop on its own), this stale success
            // must not reach out and close a form the user just reopened.
            let presentationAtSuccess = createFormPresentationToken
            Task {
                await self.sleep(.milliseconds(700))
                guard createFormPresentationToken == presentationAtSuccess else { return }
                isShowingCreateForm = false
                onDismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "WORKTREE MANAGER", comment: "Worktree Manager kicker."))
                .awFont(AwFont.Mono.kicker)
                .tracking(2)
                .foregroundStyle(Color.aw.text3)
            Text(model.repositoryContext.displayName)
                .awFont(AwFont.UI.title)
                .foregroundStyle(Color.aw.text)
        }
        .padding(.horizontal, AwSpacing.panelPadding)
        .padding(.trailing, 52)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
    }

    // Moved off the title row (INT-857 round 3): "+ New Worktree / Refresh"
    // crowded the title next to the close button. Bottom toolbar mirrors
    // SessionManagerPanel's header/list/footer layout precedent — including
    // the spacer-before-actions placement, which right-aligns them the same
    // way SessionManagerPanel's own footer right-aligns its trailing content
    // (round-6 smoke: these read as left-aligned stragglers otherwise).
    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button {
                model.resetCreateResult()
                createFormPresentationToken = UUID()
                isShowingCreateForm = true
            } label: {
                Label(
                    String(localized: "New Worktree", comment: "Open the create worktree form."),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderless)
            Button {
                Task { await refreshClearingOpenError() }
            } label: {
                Label(
                    String(localized: "Refresh", comment: "Refresh Worktree Manager action."),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.aw.surface.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "Loading worktrees…", comment: "Worktree Manager loading state."))
                    .foregroundStyle(Color.aw.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let rows):
            if rows.isEmpty {
                emptyState
            } else {
                rowList(rows: rows, errorMessage: openError)
            }
        case .error(let rows, let message):
            if rows.isEmpty {
                errorState(message)
            } else {
                // `message` is this refresh's own failure and is always the
                // more current fact than a stale `openError` from a PRIOR
                // Open attempt — `refreshClearingOpenError()` only clears
                // `openError` once a refresh lands in `.loaded`, and this
                // branch is `.error`, so a leftover `openError` could still
                // be sitting here. Showing `message` unconditionally, rather
                // than `openError ?? message`, keeps the banner honest about
                // what just happened.
                rowList(rows: rows, errorMessage: message)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28))
                .foregroundStyle(Color.aw.text3)
            Text(String(localized: "No worktrees", comment: "Worktree Manager empty-state title."))
                .awFont(AwFont.UI.title)
            Text(
                String(
                    localized: "This Git repository has no healthy worktrees to show.",
                    comment: "Worktree Manager empty-state detail."
                )
            )
            .foregroundStyle(Color.aw.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Color.aw.peach)
            Text(String(localized: "Worktrees unavailable", comment: "Worktree Manager error title."))
                .awFont(AwFont.UI.title)
            Text(message).foregroundStyle(Color.aw.text2).multilineTextAlignment(.center)
            Button(String(localized: "Retry", comment: "Retry Worktree Manager refresh action.")) {
                Task { await refreshClearingOpenError() }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowList(rows: [WorktreeManagerRow], errorMessage: String?) -> some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                    Spacer()
                    Button(String(localized: "Retry", comment: "Retry Worktree Manager refresh action.")) {
                        Task { await refreshClearingOpenError() }
                    }
                }
                .foregroundStyle(Color.aw.peach)
                .padding(12)
                .background(Color.aw.peach.opacity(0.1))
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in rowView(row) }
                }
                .padding(8)
            }
        }
    }

    private func rowView(_ row: WorktreeManagerRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.record.isDetached ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.triangle.branch")
                .foregroundStyle(Color.aw.peach)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(row.record.displayBranch)
                        .awFont(AwFont.UI.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.aw.text)
                        .lineLimit(1)
                    if row.record.isMainWorktree {
                        Label(
                            String(localized: "Current", comment: "Main worktree indicator."),
                            systemImage: "house"
                        )
                        .foregroundStyle(Color.aw.teal)
                    }
                    if row.record.lockReason != nil {
                        Label(
                            String(localized: "Locked", comment: "Locked worktree indicator."),
                            systemImage: "lock"
                        )
                        .foregroundStyle(Color.aw.text2)
                    }
                }
                // Component-aware, not character-aware: plain `.middle`
                // truncation on the raw string can land inside the leaf
                // directory name itself on these long
                // `<repo>/.worktrees/<branch>` paths, which reads as noise
                // rather than a recognizable path. `.truncationMode(.middle)`
                // stays on as a fallback for a leaf name too long on its own.
                Text(WorktreePathDisplay.condensed(row.record.canonicalPath.path))
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(
                row.liveMatch == nil
                    ? String(localized: "Open", comment: "Open a worktree in a new workspace.")
                    : String(localized: "Focus", comment: "Focus an already-open worktree workspace.")
            ) {
                Task { await open(row) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityAction {
            Task { await open(row) }
        }
    }

    // Routes every Refresh/Retry action through here so a refresh that lands
    // in `.loaded` also clears a stale `openError` from a prior failed Open
    // — otherwise that banner keeps showing under `rowList` even after the
    // refresh it was supposedly about has long since succeeded.
    private func refreshClearingOpenError() async {
        await model.refresh()
        if case .loaded = model.state {
            openError = nil
        }
    }

    private func open(_ row: WorktreeManagerRow) async {
        let outcome = await model.open(row: row)
        if case .failed(let message) = outcome {
            openError = message
            // The button shows this visually; VoiceOver users invoking the
            // same action (via the accessibility action above) need the
            // equivalent spoken feedback — refresh/create already route
            // through this same announce hook.
            model.announce(message)
        } else {
            openError = nil
        }
    }

    private func accessibilityLabel(for row: WorktreeManagerRow) -> String {
        let branchState =
            row.record.isDetached
            ? String(localized: "Detached", comment: "Accessibility state for a detached worktree.")
            : String(localized: "Branch", comment: "Accessibility state for a branch worktree.")
        let currentState =
            row.record.isMainWorktree
            ? String(localized: "current worktree", comment: "Accessibility state for the main worktree.")
            : String(localized: "linked worktree", comment: "Accessibility state for a linked worktree.")
        let openState =
            row.liveMatch == nil
            ? String(localized: "not open", comment: "Accessibility state for a worktree without a live workspace.")
            : String(localized: "open", comment: "Accessibility state for a worktree with a live workspace.")
        let action =
            row.liveMatch == nil
            ? String(localized: "Open", comment: "Accessibility action for opening a worktree workspace.")
            : String(localized: "Focus", comment: "Accessibility action for focusing an open worktree workspace.")
        // Path last: VoiceOver users hear the action and state first, the
        // (often long) POSIX path only once that's established.
        return String(
            localized:
                "\(action), \(branchState), \(row.record.displayBranch), \(currentState), \(openState), \(row.record.canonicalPath.path)",
            comment:
                "Accessibility label for a worktree row. Includes its action, branch state, branch name, current or linked state, open state, and path."
        )
    }
}

/// Trailing-component path condensing for the row list, kept separate from
/// SwiftUI so it's directly unit-testable.
enum WorktreePathDisplay {
    static func condensed(_ path: String, keepingTrailingComponents count: Int = 2) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > count else { return path }
        return "…/" + components.suffix(count).joined(separator: "/")
    }
}
