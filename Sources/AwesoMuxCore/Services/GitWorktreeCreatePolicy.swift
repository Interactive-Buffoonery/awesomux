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
    ///
    /// Anchored to `mainRepositoryRoot`, NOT `repositoryContext.invocationRoot`:
    /// worktrees created from inside an already-linked worktree used to nest
    /// under THAT worktree's own root (`invocationRoot` is genuinely that
    /// worktree's own `git rev-parse --show-toplevel`, confirmed against real
    /// git), producing an ever-deepening `.worktrees/a/.worktrees/b/...`
    /// instead of flat siblings under the repo's actual checkout (INT-857
    /// round-8 smoke).
    public func targetContainerPath(repositoryContext: GitRepositoryContext) -> URL {
        mainRepositoryRoot(repositoryContext: repositoryContext).appendingPathComponent(".worktrees", isDirectory: true)
    }

    /// The repo's actual checkout root, resolved the same way regardless of
    /// which worktree you invoke from: a linked worktree's own `.git` is a
    /// FILE pointing back at `<main>/.git/worktrees/<name>`, so
    /// `--git-common-dir` always resolves to `<main>/.git` no matter where
    /// it's run — its parent is the one root every worktree of this repo
    /// agrees on. `invocationRoot`, by contrast, is `--show-toplevel`, which
    /// deliberately reports wherever you're STANDING, not the shared root.
    private func mainRepositoryRoot(repositoryContext: GitRepositoryContext) -> URL {
        repositoryContext.canonicalCommonGitDirectory.deletingLastPathComponent()
    }

    /// The create form's live pre-fill for its Target path field: always the
    /// ungated `candidateTargetPath`, so the BOUND value is never emptier
    /// than what the form displays. A freshly-created linked worktree has no
    /// `.worktrees/` of its own yet — the gated `suggestedTargetPath` returns
    /// nil there, but the form still SHOWED the candidate as if it were real
    /// content, so `submit()` validated an empty bound string against a
    /// visibly-absolute path and failed with "must be absolute" (INT-857
    /// round-7 smoke). `suggestedTargetPath`'s filesystem check exists purely
    /// to gate whether to suggest AT ALL, not to change the resulting path —
    /// for a given repository context and branch name, the two never differ
    /// on the actual string, so preferring the gated call first here only
    /// bought a redundant existence check on every keystroke for no
    /// behavioral difference.
    public func formTargetPathPrefill(
        repositoryContext: GitRepositoryContext,
        branchName: String
    ) -> String {
        candidateTargetPath(repositoryContext: repositoryContext, branchName: branchName)?.path ?? ""
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
            // Only require the repo's actual checkout root itself — which
            // definitely exists — to be writable; git materializes
            // everything under `.worktrees/` on its own. A target OUTSIDE
            // this convention still needs its immediate parent to exist.
            if !fileManager.isWritableFile(atPath: mainRepositoryRoot(repositoryContext: request.repositoryContext).path) {
                issues.append(.parentDirectoryNotWritable)
            }
        } else {
            issues.append(.parentDirectoryMissing)
        }
        if fileManager.fileExists(atPath: request.targetPath.path) {
            issues.append(.targetAlreadyExists)
        }
        // The exemption set for the "target NESTED UNDER an existing
        // worktree" half of this check is {main} ∪ {whichever worktree the
        // request was INVOKED FROM}, unconditionally — not just main (round-5
        // smoke) and not ONLY the invocation root (round-857 smoke: the
        // default suggestion nests under main via `targetContainerPath`, but
        // a hand-typed or "Choose…"-picked path nested under the CURRENT
        // worktree is equally git-allowed and must validate clean too).
        // A target nested under any OTHER worktree still rejects. The OTHER
        // half — an existing worktree nested under the new TARGET, i.e. the
        // target is some ancestor of the worktree you're standing in — stays
        // unconditional: an ancestor of a worktree that already exists on
        // disk always already exists itself, so it's normally caught by
        // `targetAlreadyExists` above regardless, but exempting it here too
        // would be a silent gap if that assumption ever stops holding.
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
