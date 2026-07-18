import AwesoMuxCore
import DesignSystem
import SwiftUI

@MainActor
struct WorktreeCreateForm: View {
    enum Mode: String, CaseIterable, Identifiable {
        case existing
        case new

        var id: Self { self }
    }

    @State var model: WorktreeManagerModel
    let onDismiss: () -> Void

    @State private var mode: Mode = .existing
    @State private var branches: [String] = []
    @State private var selectedBranch = ""
    @State private var newBranchName = ""
    @State private var targetPath = ""
    @State private var lastSuggestedPath: String?
    @State private var validationMessage: String?
    // Bridges the gap between tapping Create and `model.createSubmissionState`
    // actually flipping to `.submitting` (which only happens once `create()`
    // is invoked): the new-branch-name check below awaits before that call,
    // and without this flag Cancel/dismiss stay enabled during that await —
    // letting a "cancelled" sheet still create a worktree behind the scenes.
    @State private var isValidatingBeforeSubmit = false

    private var isBusy: Bool { isValidatingBeforeSubmit || model.createSubmissionState.isSubmitting }

    private let policy = GitWorktreeCreatePolicy()

    var body: some View {
        Form {
            Picker(String(localized: "Branch mode", comment: "Worktree create branch mode label."), selection: $mode) {
                Text(String(localized: "Existing local branch", comment: "Existing branch create mode."))
                    .tag(Mode.existing)
                Text(String(localized: "New branch from HEAD", comment: "New branch create mode."))
                    .tag(Mode.new)
            }
            .pickerStyle(.segmented)

            if mode == .existing {
                Picker(String(localized: "Branch", comment: "Existing local branch picker label."), selection: $selectedBranch) {
                    ForEach(branches, id: \.self) { Text($0).tag($0) }
                }
            } else {
                TextField(
                    String(localized: "New branch name", comment: "New worktree branch name field label."),
                    text: $newBranchName
                )
            }

            TextField(
                String(localized: "Target path", comment: "New worktree target path field label."),
                text: $targetPath
            )

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(Color.aw.peach)
            }

            if case .result(let result) = model.createSubmissionState {
                Text(message(for: result))
                    .foregroundStyle(result.isSuccess ? Color.aw.teal : Color.aw.peach)
            }

            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Cancel worktree creation action."), action: onDismiss)
                    .disabled(isBusy)
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) {
                    Text(
                        isBusy
                            ? String(localized: "Creating…", comment: "Worktree creation in progress button label.")
                            : String(localized: "Create", comment: "Create worktree submit button label.")
                    )
                }
                .disabled(isBusy)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(
                    isBusy
                        ? String(localized: "Creating…", comment: "Worktree creation in progress accessibility label.")
                        : String(localized: "Create", comment: "Create worktree accessibility label."))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
        .interactiveDismissDisabled(isBusy)
        .task { await loadBranches() }
        .onChange(of: mode) { _, _ in suggestPath() }
        .onChange(of: selectedBranch) { _, _ in suggestPath() }
        .onChange(of: newBranchName) { _, _ in suggestPath() }
    }

    private func loadBranches() async {
        if case .success(let names) = await model.branches() {
            branches = names
            if selectedBranch.isEmpty { selectedBranch = names.first ?? "" }
            suggestPath()
        } else {
            validationMessage = String(
                localized: "Couldn’t load local branches.", comment: "Branch loading failure in worktree create form.")
        }
    }

    private func suggestPath() {
        guard targetPath.isEmpty || targetPath == lastSuggestedPath else { return }
        let name = mode == .existing ? selectedBranch : newBranchName
        let suggestion =
            policy.suggestedTargetPath(
                repositoryContext: model.repositoryContext,
                branchName: name
            )?.path ?? ""
        targetPath = suggestion
        lastSuggestedPath = suggestion
    }

    private func submit() {
        guard !isBusy else { return }
        guard let groupID = model.destinationWorkspaceGroupID else {
            validationMessage = String(
                localized: "The current workspace group is no longer available.", comment: "Worktree creation target group failure.")
            return
        }
        guard targetPath.hasPrefix("/") else {
            validationMessage = String(localized: "Target path must be absolute.", comment: "Worktree target absolute path validation.")
            return
        }
        let createMode: GitWorktreeCreateMode =
            mode == .existing
            ? .existingBranch(selectedBranch)
            : .newBranchFromHEAD(newBranchName)
        let request = GitWorktreeCreateRequest(
            repositoryContext: model.repositoryContext,
            mode: createMode,
            targetPath: URL(fileURLWithPath: targetPath),
            destinationWorkspaceGroupID: groupID
        )
        let issues = policy.validate(request, currentWorktrees: model.state.rows.map(\.record))
        guard issues.isEmpty else {
            validationMessage = validationText(for: issues[0])
            return
        }
        validationMessage = nil
        isValidatingBeforeSubmit = true
        Task {
            defer { isValidatingBeforeSubmit = false }
            if mode == .new, !(await model.validateNewBranchName(newBranchName)) {
                validationMessage = String(localized: "Enter a valid Git branch name.", comment: "Invalid new Git branch name validation.")
                return
            }
            _ = await model.create(request: request)
        }
    }

    private func validationText(for issue: GitWorktreeCreateValidationIssue) -> String {
        switch issue {
        case .blankBranchName: String(localized: "Choose or enter a branch name.", comment: "Blank branch validation.")
        case .targetPathMustBeAbsolute: String(localized: "Target path must be absolute.", comment: "Absolute path validation.")
        case .parentDirectoryMissing:
            String(localized: "The target parent directory does not exist.", comment: "Missing target parent validation.")
        case .parentDirectoryNotWritable:
            String(localized: "The target parent directory is not writable.", comment: "Unwritable target parent validation.")
        case .targetAlreadyExists: String(localized: "The target path already exists.", comment: "Existing worktree target validation.")
        case .targetOverlapsWorktree:
            String(localized: "The target overlaps an existing worktree.", comment: "Worktree target overlap validation.")
        }
    }

    private func message(for result: WorktreeManagerCreateResult) -> String {
        switch result {
        case .opened: String(localized: "Worktree created and opened.", comment: "Successful worktree create result.")
        case .worktreeCreatedWorkspaceOpenFailed:
            String(
                localized: "Worktree created; workspace could not be opened.", comment: "Worktree created but workspace open failed result."
            )
        case .branchCreatedWithoutWorktree(let branch):
            String(
                localized: "Branch \(branch) was created, but the worktree was not.",
                comment: "Branch-only partial worktree creation result.")
        case .failed(let message): message
        }
    }
}

private extension WorktreeManagerCreateResult {
    var isSuccess: Bool {
        if case .opened = self { return true }
        return false
    }
}
