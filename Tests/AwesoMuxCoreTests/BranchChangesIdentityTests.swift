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

    @Test(arguments: [
        ("fix\u{202E}gnp.js", "awesomux", "fixgnp.js", "awesomux"),
        ("feature/x", "repo\u{0085}\u{200B}name", "feature/x", "reponame"),
    ])
    func sanitizedTitle(branch: String, repository: String, displayBranch: String, displayRepository: String) throws {
        let identity = try #require(makeIdentity(branch: branch, repository: repository))
        #expect(identity.displayBranch == displayBranch)
        #expect(identity.displayRepositoryName == displayRepository)
        #expect(identity.gitBranch == branch)
    }

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

    @Test("a snapshot carrying an unrenderable identity is rejected on the way in")
    func decodeRevalidates() throws {
        let data = Data(#"{"baseRef":"","repositoryName":"awesomux"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BranchChangesIdentity.self, from: data)
        }
    }

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
}
