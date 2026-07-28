import Foundation
import Testing

@testable import awesoMux

/// The socket directory is cleared once per test process so a recycled pid can
/// never inherit a dead run's status files (#296). That sweep runs inside a lazy
/// `static let`, where no test can observe it — so the decision and the deletion
/// live in a function that can be pointed at a directory of our own instead.
@Suite("AmxBackend socket directory residue")
struct AmxBackendSocketDirectoryResidueTests {
    private func makeDirectoryWithResidue() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: directory.appending(path: "dddddddd-dddd.status.jsonl"))
        return directory
    }

    @Test("a test profile discards a prior run's residue")
    func testProfileDiscardsResidue() throws {
        let directory = try makeDirectoryWithResidue()
        defer { try? FileManager.default.removeItem(at: directory) }

        AmxBackend.discardResidueOfPriorRun(at: directory.path, profile: .test(processID: 4242))

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// The far more dangerous direction. These directories belong to an app that
    /// may be running right now, so a sweep that fired here would delete a live
    /// session's sockets out from under it.
    @Test(
        "no other profile is ever swept",
        arguments: [
            AppRuntimeProfile.production,
            .development(worktreeID: nil),
            .development(worktreeID: "0123456789ab"),
        ]
    )
    func otherProfilesAreNeverSwept(profile: AppRuntimeProfile) throws {
        let directory = try makeDirectoryWithResidue()
        defer { try? FileManager.default.removeItem(at: directory) }

        AmxBackend.discardResidueOfPriorRun(at: directory.path, profile: profile)

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "dddddddd-dddd.status.jsonl").path
            )
        )
    }

    /// A first-ever run has no directory yet, which must be a no-op rather than
    /// an error the caller has to care about.
    @Test("a missing directory is not an error")
    func missingDirectoryIsNotAnError() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        AmxBackend.discardResidueOfPriorRun(at: directory.path, profile: .test(processID: 4242))

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
