import AppKit
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

    // `model.createSubmissionState` flips to `.submitting` as the first
    // statement in `create(request:)`, before any `await` — so this is
    // busy from the moment Create is tapped, with no separate pre-submit
    // flag needed. (An earlier version re-validated the new branch name
    // here first, which left a gap where dismissal wasn't blocked yet;
    // `GitWorktreeService.create` already re-validates it internally, so
    // that duplicate check was removed rather than patched.)
    private var isBusy: Bool { model.createSubmissionState.isSubmitting }

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

            HStack(spacing: 8) {
                TextField(
                    String(localized: "Target path", comment: "New worktree target path field label."),
                    text: $targetPath,
                    prompt: Text(targetPathPlaceholder)
                )
                Button(String(localized: "Choose…", comment: "Open a folder picker for the worktree target path.")) {
                    chooseTargetPath()
                }
            }

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
        // 520 clipped Target path mid-word with no ellipsis for anything but
        // the shortest branch names (round-4 smoke). 640 matches
        // WorktreeManagerController's panel width — still no truncation
        // affordance for a very deep home directory, but that's a real
        // AppKit-level fix (head-truncating NSTextField), not a width tweak.
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isBusy)
        .task { await loadBranches() }
        .onChange(of: mode) { _, _ in
            suggestPath(); validationMessage = nil
        }
        .onChange(of: selectedBranch) { _, _ in
            suggestPath(); validationMessage = nil
        }
        .onChange(of: newBranchName) { _, _ in
            suggestPath(); validationMessage = nil
        }
        // Round-3 smoke bug: a failed submit's error stuck around after the
        // user fixed the field it complained about — e.g. Create pressed on
        // an empty Target path shows "must be absolute", then as the user
        // types a real absolute path the stale message just sits there,
        // reading as if the freshly-typed value were still rejected. The
        // message belongs to a submit attempt, not the field's live value —
        // clear it the moment any field the next submit reads changes.
        .onChange(of: targetPath) { _, _ in validationMessage = nil }
    }

    // Pre-submit and branch-loading failures previously only set the visible
    // `validationMessage` Text — a sighted user sees it, but nothing spoken
    // reaches VoiceOver (unlike refresh/create results, which already
    // announce through the model). Route every validation message through
    // this so all of them do too.
    private func reportValidation(_ message: String) {
        validationMessage = message
        model.announce(message)
    }

    private func loadBranches() async {
        if case .success(let names) = await model.branches() {
            branches = names
            if selectedBranch.isEmpty { selectedBranch = names.first ?? "" }
            suggestPath()
        } else {
            reportValidation(
                String(
                    localized: "Couldn’t load local branches.", comment: "Branch loading failure in worktree create form."))
        }
    }

    // Shown as the field's grayed prompt even when `suggestPath()` can't
    // pre-fill for real (the repo's `.worktrees` container doesn't exist
    // yet) — otherwise a first-time create has a bare empty field with no
    // hint at all about where the worktree will land.
    private var targetPathPlaceholder: String {
        let name = mode == .existing ? selectedBranch : newBranchName
        return policy.candidateTargetPath(repositoryContext: model.repositoryContext, branchName: name)?.path ?? ""
    }

    private func chooseTargetPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Confirm button for the worktree target path picker.")
        panel.message = String(
            localized: "Choose the folder that will contain the new worktree.",
            comment: "Worktree target path picker guidance message.")
        panel.directoryURL = startingDirectoryForChoosePanel()
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let name = mode == .existing ? selectedBranch : newBranchName
        let component = policy.sanitizedPathComponent(name)
        targetPath = component.isEmpty ? chosen.path : chosen.appendingPathComponent(component, isDirectory: true).path
    }

    // A bare NSOpenPanel opens wherever the user last browsed — not this
    // repo — which is how round-4 smoke ended up with "/test" (picked the
    // volume root, then appended the branch name). Prefer the already-typed
    // path's parent (refining an existing choice); fall back to the repo
    // root itself, which always exists, rather than the system default.
    private func startingDirectoryForChoosePanel() -> URL {
        existingParentDirectoryURL() ?? model.repositoryContext.invocationRoot
    }

    private func existingParentDirectoryURL() -> URL? {
        guard !targetPath.isEmpty else { return nil }
        let parent = URL(fileURLWithPath: targetPath).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return parent
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
            reportValidation(
                String(
                    localized: "The current workspace group is no longer available.",
                    comment: "Worktree creation target group failure."))
            return
        }
        guard targetPath.hasPrefix("/") else {
            reportValidation(
                String(localized: "Target path must be absolute.", comment: "Worktree target absolute path validation."))
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
            reportValidation(validationText(for: issues[0]))
            return
        }
        validationMessage = nil
        Task {
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
