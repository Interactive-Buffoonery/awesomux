import Foundation
import UnicodeHygiene

/// Durable provenance for a document tab showing an app-rendered branch diff:
/// which branch, against which base, in which repository.
///
/// This is the tab's identity; the rendered `.md` under the branch-changes
/// cache is regenerable implementation storage, exactly as `ResourceIdentity`
/// is the identity of a remote Markdown snapshot and its downloaded cache file
/// is not.
///
/// It is stored ON the document rather than asked of the adjacent pane for the
/// same reason `AgentTranscriptIdentity` is: a pane outlives the comparison
/// rendered beside it. Show the changes on `feature/a`, switch that terminal to
/// `main`, and an accessor that consults the pane now answers `main` while the
/// tab still shows the old diff. A tab answers with what it was actually
/// rendered from, forever.
///
/// Validity is a construction invariant. The initialiser rejects anything that
/// could not become a readable tab title, so no consumer has to re-check and
/// there is no way to hold an instance whose title is blank or spoofed.
public struct BranchChangesIdentity: Hashable, Sendable {
    /// The raw local branch name (`refs/heads/<name>`), or `nil` for a detached
    /// HEAD. Raw — never the sanitized display form — because this is half of
    /// the cache slot key, and sanitizing before hashing would collapse two
    /// genuinely different branches onto one file.
    public let gitBranch: String?
    /// The raw full or short ref the diff was taken against, e.g.
    /// `origin/main`. Raw, for the same reason as `gitBranch`.
    public let baseRef: String
    /// The repository's directory name, used only for the tab title.
    public let repositoryName: String

    /// The longest each component may be in the tab title. A tab pill is a few
    /// dozen points wide; the cap exists so a multi-kilobyte branch name cannot
    /// become a multi-kilobyte accessibility label.
    static let displayComponentLimit = 48

    /// Returns `nil` unless every component still names something visible after
    /// sanitization — an all-bidi branch name, an empty base, or a repository
    /// directory made of zero-width scalars has no honest title to show, and a
    /// tab titled `Changes:  vs  — ` is worse than the alert that replaces it.
    public init?(gitBranch: String?, baseRef: String, repositoryName: String) {
        self.gitBranch = gitBranch
        self.baseRef = baseRef
        self.repositoryName = repositoryName
        // Validated through the very accessors the title is built from, rather
        // than through a parallel set of checks on the raw fields: the display
        // form drops a ref namespace prefix, so `refs/heads/` is a non-empty
        // raw value with an empty display and only this shape catches it.
        guard !displayBranch.isEmpty, !displayBaseRef.isEmpty, !displayRepositoryName.isEmpty
        else { return nil }
    }

    /// The branch as it is shown to a person: sanitized and bounded. `HEAD` for
    /// a detached checkout, which is what git itself calls that state.
    public var displayBranch: String {
        guard let gitBranch else { return "HEAD" }
        return Self.display(gitBranch)
    }

    /// The base as it is shown to a person. The stored value is a full refname
    /// so that git can never read it as a path, but `refs/remotes/origin/main`
    /// on a tab pill is four words of ceremony around the one word that says
    /// anything, so the namespace prefix comes off for display only.
    public var displayBaseRef: String {
        for prefix in ["refs/remotes/", "refs/heads/"] where baseRef.hasPrefix(prefix) {
            return Self.display(String(baseRef.dropFirst(prefix.count)))
        }
        return Self.display(baseRef)
    }
    public var displayRepositoryName: String { Self.display(repositoryName) }

    /// The tab title for a branch-changes document. The file it points at is
    /// named after a hash, so the identity is the only readable name available.
    ///
    /// Both sides of the comparison are named, because "Changes" alone does not
    /// say whether the user is looking at the working tree or the branch, and
    /// the repository is named because two workspaces can be on same-named
    /// branches in different checkouts.
    public var documentTitle: String {
        String(
            localized: "Changes: \(displayBranch) vs \(displayBaseRef) — \(displayRepositoryName)",
            comment:
                "Document tab title for a rendered branch diff, e.g. 'Changes: feature/x vs origin/main — awesomux'"
        )
    }

    /// The one sanitizer every displayed component goes through.
    ///
    /// Branch names, base refs, and directory names all arrive from another
    /// repository's on-disk state — a clone, a dependency, an agent's checkout
    /// — and land in a tab pill, a menu, and a VoiceOver label. `UnicodeHygiene`
    /// is the house fence for exactly that: it folds compatibility look-alikes,
    /// strips bidi overrides, C1 controls, and zero-width scalars, and clips the
    /// result.
    static func display(_ raw: String) -> String {
        UnicodeHygiene.sanitize(raw, maxLength: displayComponentLimit)
    }
}

extension BranchChangesIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case gitBranch
        case baseRef
        case repositoryName
    }

    /// Re-validates on the way in. A snapshot is a same-UID-writable file, so a
    /// persisted identity is untrusted input and gets the same gate as a fresh
    /// one rather than being reconstructed around it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let identity = BranchChangesIdentity(
                gitBranch: try container.decodeIfPresent(String.self, forKey: .gitBranch),
                baseRef: try container.decode(String.self, forKey: .baseRef),
                repositoryName: try container.decode(String.self, forKey: .repositoryName)
            )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseRef,
                in: container,
                debugDescription:
                    "A branch changes identity requires a base ref and repository name that survive display sanitization."
            )
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try container.encode(baseRef, forKey: .baseRef)
        try container.encode(repositoryName, forKey: .repositoryName)
    }
}
