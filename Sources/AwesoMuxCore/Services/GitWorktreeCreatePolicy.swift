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
        let candidate = canonicalPathComponents(request.targetPath)
        let parent = request.targetPath.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let parentIsRealDirectory = fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) && isDirectory.boolValue
        if parentIsRealDirectory {
            if !fileManager.isWritableFile(atPath: parent.path) {
                issues.append(.parentDirectoryNotWritable)
            }
        } else if candidate.starts(with: canonicalPathComponents(targetContainerPath(repositoryContext: request.repositoryContext))) {
            // `git worktree add` creates missing intermediate directories
            // itself (verified against the installed `git`), and this app's
            // OWN `.worktrees/` convention routinely doesn't exist yet for a
            // freshly-created worktree — the exact suggested path this form
            // pre-fills was still blocked here even after the prefill fix
            // closed the placeholder/bound-value split (INT-857 round-7
            // smoke: the error changed from "must be absolute" to "parent
            // directory does not exist", but Create still never succeeded).
            // Only require the invocation root itself — which definitely
            // exists — to be writable; git materializes everything under
            // `.worktrees/` on its own. A target OUTSIDE this convention
            // still needs its immediate parent to already exist.
            if !fileManager.isWritableFile(atPath: request.repositoryContext.invocationRoot.path) {
                issues.append(.parentDirectoryNotWritable)
            }
        } else {
            issues.append(.parentDirectoryMissing)
        }
        if fileManager.fileExists(atPath: request.targetPath.path) {
            issues.append(.targetAlreadyExists)
        }
        // Whichever worktree the request was INVOKED FROM is exempt from the
        // "target NESTED UNDER an existing worktree" half of this check, not
        // just the main one: git allows linked worktrees nested under it, and
        // `.worktrees/` — this app's own suggested convention — always lives
        // under the invocation root, main or linked (round-5 smoke covered
        // main; round-857 smoke found the same false overlap from a Worktree
        // Manager opened inside a LINKED worktree, since only `isMainWorktree`
        // was ever exempted). The OTHER half — an existing worktree nested
        // under the new TARGET, i.e. the target is some ancestor of the
        // worktree you're standing in — stays unconditional: an ancestor of
        // a worktree that already exists on disk always already exists
        // itself, so it's normally caught by `targetAlreadyExists` above
        // regardless, but exempting it here too would be a silent gap if
        // that assumption ever stops holding.
        let invocationRoot = canonicalPathComponents(request.repositoryContext.invocationRoot)
        for record in currentWorktrees where !record.isMainWorktree {
            let existing = canonicalPathComponents(record.canonicalPath)
            let isOwnInvocationRoot = existing == invocationRoot
            if !isOwnInvocationRoot, candidate.starts(with: existing) {
                issues.append(.targetOverlapsWorktree(record.canonicalPath))
                break
            }
            if existing.starts(with: candidate) {
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
