import Foundation

public enum GitWorktreeCreateValidationIssue: Equatable, Sendable {
    case blankBranchName
    case targetPathMustBeAbsolute
    case parentDirectoryMissing
    case parentDirectoryNotWritable
    case targetAlreadyExists
    case targetOverlapsWorktree(URL)
}

public struct GitWorktreeCreatePolicy: Sendable {
    public init() {}

    public func suggestedTargetPath(
        repositoryContext: GitRepositoryContext,
        branchName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let candidate = candidateTargetPath(repositoryContext: repositoryContext, branchName: branchName) else {
            return nil
        }
        let parent = candidate.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    /// The same `<repo>/.worktrees/<branch>` convention as `suggestedTargetPath`,
    /// but computed with no filesystem check — used to show a hint even before
    /// that container directory exists (the create form's "Choose…" panel can
    /// create it), where the gated version would return `nil`.
    ///
    /// `.worktrees/` inside the repo, not a `<repo>-worktrees` sibling: that's
    /// the convention every worktree this app actually creates already lands
    /// in (see the repo's own `.gitignore`) — a sibling folder nobody's disk
    /// has ever matched read as an opaque, made-up suggestion (round-4 smoke).
    public func candidateTargetPath(
        repositoryContext: GitRepositoryContext,
        branchName: String
    ) -> URL? {
        let component = sanitizedPathComponent(branchName)
        guard !component.isEmpty else { return nil }
        return targetContainerPath(repositoryContext: repositoryContext).appendingPathComponent(component, isDirectory: true)
    }

    /// Just the `.worktrees/` container, no branch leaf — lets a caller show
    /// where a worktree WILL land before a branch name exists to complete
    /// `candidateTargetPath` (round-6 smoke: an empty branch name left the
    /// create form's Target path hint completely blank).
    public func targetContainerPath(repositoryContext: GitRepositoryContext) -> URL {
        repositoryContext.invocationRoot.appendingPathComponent(".worktrees", isDirectory: true)
    }

    /// The create form's live pre-fill for its Target path field: prefers the
    /// filesystem-confirmed `suggestedTargetPath`, falling back to the
    /// unconfirmed `candidateTargetPath` so the BOUND value is never emptier
    /// than what the form displays. A freshly-created linked worktree has no
    /// `.worktrees/` of its own yet — `suggestedTargetPath` correctly returns
    /// nil there, but the form still SHOWED the candidate as if it were real
    /// content, so `submit()` validated an empty bound string against a
    /// visibly-absolute path and failed with "must be absolute" (INT-857
    /// round-7 smoke).
    public func formTargetPathPrefill(
        repositoryContext: GitRepositoryContext,
        branchName: String,
        fileManager: FileManager = .default
    ) -> String {
        suggestedTargetPath(repositoryContext: repositoryContext, branchName: branchName, fileManager: fileManager)?.path
            ?? candidateTargetPath(repositoryContext: repositoryContext, branchName: branchName)?.path
            ?? ""
    }

    public func validate(
        _ request: GitWorktreeCreateRequest,
        currentWorktrees: [GitWorktreeRecord],
        fileManager: FileManager = .default
    ) -> [GitWorktreeCreateValidationIssue] {
        var issues: [GitWorktreeCreateValidationIssue] = []
        if request.mode.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankBranchName)
        }
        guard request.targetPath.path.hasPrefix("/") else {
            issues.append(.targetPathMustBeAbsolute)
            return issues
        }
        let parent = request.targetPath.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            issues.append(.parentDirectoryMissing)
        } else if !fileManager.isWritableFile(atPath: parent.path) {
            issues.append(.parentDirectoryNotWritable)
        }
        if fileManager.fileExists(atPath: request.targetPath.path) {
            issues.append(.targetAlreadyExists)
        }
        let candidate = canonicalPathComponents(request.targetPath)
        // Whichever worktree the request was INVOKED FROM is exempt, not just
        // the main one: git allows linked worktrees nested under it, and
        // `.worktrees/` — this app's own suggested convention — always lives
        // under the invocation root, main or linked (round-5 smoke covered
        // main; round-857 smoke found the same false overlap from a Worktree
        // Manager opened inside a LINKED worktree, since only `isMainWorktree`
        // was ever exempted). Only some OTHER worktree's path can genuinely
        // conflict; without this exemption every suggested `.worktrees/...`
        // target "overlapped" the entry you're standing in and validation
        // could never pass.
        let invocationRoot = canonicalPathComponents(request.repositoryContext.invocationRoot)
        for record in currentWorktrees where !record.isMainWorktree {
            let existing = canonicalPathComponents(record.canonicalPath)
            guard existing != invocationRoot else { continue }
            if candidate.starts(with: existing) || existing.starts(with: candidate) {
                issues.append(.targetOverlapsWorktree(record.canonicalPath))
                break
            }
        }
        return issues
    }

    public func sanitizedPathComponent(_ branchName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        // Trim stray leading/trailing dots and spaces only — NOT hyphens.
        // Branch names routinely end in "-" mid-typing (e.g. "test-" before
        // "branch" lands), and the live-suggestion path in
        // `WorktreeCreateForm.suggestPath()` recomputes this on every
        // keystroke; trimming the hyphen away used to leave the suggestion
        // showing a truncated "test" instead of "test-branch" (round-4 smoke).
        return branchName.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}

public func canonicalPathComponents(_ url: URL) -> [String] {
    url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
}
