import Foundation
import Testing

@testable import AwesoMuxCore

@Suite("BranchChangesIdentity")
struct BranchChangesIdentityTests {

    private func makeIdentity(
        branch: String? = "feature/x",
        base: String = "refs/remotes/origin/main",
        repository: String = "awesomux"
    ) -> BranchChangesIdentity? {
        BranchChangesIdentity(gitBranch: branch, baseRef: base, repositoryName: repository)
    }

    // MARK: - Title

    @Test("the title names both sides of the comparison and the repository")
    func titleNamesBothSidesAndRepository() throws {
        let title = try #require(makeIdentity()).documentTitle
        #expect(title.contains("feature/x"))
        #expect(title.contains("origin/main"))
        #expect(title.contains("awesomux"))
    }

    @Test("a detached HEAD reads as HEAD rather than as a blank")
    func detachedHeadIsNamed() throws {
        let identity = try #require(makeIdentity(branch: nil))
        #expect(identity.gitBranch == nil)
        #expect(identity.displayBranch == "HEAD")
        #expect(identity.documentTitle.contains("HEAD"))
    }

    @Test("the ref namespace is stripped for display only")
    func displayDropsTheRefNamespace() throws {
        let identity = try #require(makeIdentity(base: "refs/heads/main"))
        #expect(identity.baseRef == "refs/heads/main")
        #expect(identity.displayBaseRef == "main")
    }

    // MARK: - Sanitization

    @Test("a bidi override in a branch name cannot reach the title")
    func titleStripsBidiOverrides() throws {
        let identity = try #require(makeIdentity(branch: "fix\u{202E}gnp.js"))
        #expect(!identity.displayBranch.unicodeScalars.contains { $0.value == 0x202E })
        // The raw value is preserved: it is half of the cache slot key, and
        // sanitizing before hashing would merge two different branches.
        #expect(identity.gitBranch == "fix\u{202E}gnp.js")
    }

    @Test("C1 controls and zero-width scalars cannot reach the title")
    func titleStripsInvisibleScalars() throws {
        let identity = try #require(makeIdentity(repository: "repo\u{0085}\u{200B}name"))
        #expect(identity.displayRepositoryName == "reponame")
    }

    @Test("an overlong branch name is bounded before it reaches the title")
    func titleBoundsComponentLength() throws {
        let long = String(repeating: "b", count: 5000)
        let identity = try #require(makeIdentity(branch: long))
        #expect(identity.gitBranch == long)
        #expect(identity.displayBranch.count == BranchChangesIdentity.displayComponentLimit)
        #expect(identity.documentTitle.count < 200)
    }

    @Test(
        "a component with nothing visible left has no honest title, so there is no identity",
        arguments: ["", "\u{200B}\u{200B}", "\u{202E}"]
    )
    func rejectsUnrenderableComponents(unrenderable: String) {
        #expect(makeIdentity(branch: unrenderable) == nil)
        #expect(makeIdentity(base: unrenderable) == nil)
        #expect(makeIdentity(repository: unrenderable) == nil)
    }

    @Test("a base ref that is nothing but a namespace prefix is rejected")
    func rejectsBareNamespacePrefix() {
        #expect(makeIdentity(base: "refs/heads/") == nil)
    }

    // MARK: - Slots

    @Test("two branches sharing a long prefix are distinct identities")
    func longSharedPrefixesStayDistinct() throws {
        let prefix = String(repeating: "release/2026-08-", count: 4)
        let first = try #require(makeIdentity(branch: prefix + "a"))
        let second = try #require(makeIdentity(branch: prefix + "b"))
        #expect(first != second)
        #expect(first.hashValue != second.hashValue)
        // Both clip to the same display string, which is exactly why the raw
        // field — not the display one — is what the cache slot is keyed on.
        #expect(first.displayBranch == second.displayBranch)
    }

    // MARK: - Codable

    @Test("a branch identity round-trips through a snapshot")
    func codableRoundTrip() throws {
        for branch in ["feature/x", nil] as [String?] {
            let original = try #require(makeIdentity(branch: branch))
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(BranchChangesIdentity.self, from: data) == original)
        }
    }

    @Test("a snapshot carrying an unrenderable identity is rejected on the way in")
    func decodeRevalidates() throws {
        let data = Data(#"{"baseRef":"","repositoryName":"awesomux"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BranchChangesIdentity.self, from: data)
        }
    }

    // MARK: - Document pane

    @Test("a tab carrying branch provenance is not editable")
    func branchChangesTabIsReadOnly() throws {
        let identity = try #require(makeIdentity())
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/cache/abc.branch-changes.md"),
            title: identity.documentTitle,
            branchChangesIdentity: identity
        )
        #expect(!tab.isEditable)
        // Not a remote snapshot: widening that would disable the send bar and
        // strip local-file access from unrelated tabs in the same group.
        #expect(!tab.isReadOnlySnapshot)
    }

    @Test("a tab decoded without the field is still a tab")
    func olderSnapshotsDecodeWithoutTheField() throws {
        let tab = DocumentPane(
            fileURL: URL(fileURLWithPath: "/tmp/notes.md"),
            title: "notes.md"
        )
        let data = try JSONEncoder().encode(tab)
        let decoder = JSONDecoder()
        decoder.userInfo[.snapshotSchemaVersion] = SessionSnapshot.currentSchemaVersion
        let decoded = try decoder.decode(DocumentPane.self, from: data)
        #expect(decoded.branchChangesIdentity == nil)
        #expect(decoded.isEditable)
    }
}
