import AwesoMuxCore
import DesignSystem
import SwiftUI

@MainActor
struct WorktreeManagerPanel: View {
    @State var model: WorktreeManagerModel
    let onDismiss: () -> Void
    @State private var openError: String?
    @State private var isShowingCreateForm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
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
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "WORKTREE MANAGER", comment: "Worktree Manager kicker."))
                    .awFont(AwFont.Mono.kicker)
                    .tracking(2)
                    .foregroundStyle(Color.aw.text3)
                Text(model.repositoryContext.displayName)
                    .awFont(AwFont.UI.title)
                    .foregroundStyle(Color.aw.text)
            }
            Spacer()
            Button {
                model.resetCreateResult()
                isShowingCreateForm = true
            } label: {
                Label(
                    String(localized: "New Worktree", comment: "Open the create worktree form."),
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderless)
            Button {
                Task { await model.refresh() }
            } label: {
                Label(
                    String(localized: "Refresh", comment: "Refresh Worktree Manager action."),
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, AwSpacing.panelPadding)
        .padding(.trailing, 52)
        .padding(.vertical, 16)
        .overlay(alignment: .bottom) {
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
                rowList(rows: rows, errorMessage: openError ?? message)
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
                Task { await model.refresh() }
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
                        Task { await model.refresh() }
                    }
                }
                .foregroundStyle(Color.aw.peach)
                .padding(12)
                .background(Color.aw.peach.opacity(0.1))
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { row in rowView(row) }
                }
                .padding(8)
            }
        }
    }

    private func rowView(_ row: WorktreeManagerRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.record.isDetached ? "point.topleft.down.to.point.bottomright.curvepath" : "arrow.triangle.branch")
                .foregroundStyle(Color.aw.peach)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.record.displayBranch)
                        .foregroundStyle(Color.aw.text)
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
                Text(row.record.canonicalPath.path)
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(
                row.liveMatch == nil
                    ? String(localized: "Open", comment: "Open a worktree in a new workspace.")
                    : String(localized: "Focus", comment: "Focus an already-open worktree workspace.")
            ) {
                Task { await open(row) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: row))
        .accessibilityAction {
            Task { await open(row) }
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
