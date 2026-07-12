import XCTest
@testable import AwesoMuxCore

final class WorkingDirectoryValidatorTests: XCTestCase {
    func testAcceptsExistingUserOwnedAbsoluteDirectory() throws {
        let directory = try makeTemporaryDirectory()

        XCTAssertEqual(
            WorkingDirectoryValidator.validatedReportedDirectory(directory.path),
            directory.path
        )
    }

    func testStripsLocalFileURLPrefixes() throws {
        let directory = try makeTemporaryDirectory()

        XCTAssertEqual(
            WorkingDirectoryValidator.validatedReportedDirectory(directory.absoluteString),
            directory.path
        )
        XCTAssertEqual(
            WorkingDirectoryValidator.validatedReportedDirectory("file://localhost\(directory.path)"),
            directory.path
        )
    }

    func testRejectsRemoteFileURLHosts() throws {
        let directory = try makeTemporaryDirectory()

        XCTAssertNil(
            WorkingDirectoryValidator.validatedReportedDirectory("file://example.test\(directory.path)")
        )
    }

    func testRejectsRelativeMissingNonDirectoryAndControlCharacterPaths() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)

        XCTAssertNil(WorkingDirectoryValidator.validatedReportedDirectory("relative/path"))
        XCTAssertNil(WorkingDirectoryValidator.validatedReportedDirectory(directory.appendingPathComponent("missing").path))
        XCTAssertNil(WorkingDirectoryValidator.validatedReportedDirectory(file.path))
        XCTAssertNil(WorkingDirectoryValidator.validatedReportedDirectory("\(directory.path)\u{0}"))
        XCTAssertNil(WorkingDirectoryValidator.validatedReportedDirectory("file://localhost\(directory.path)%00"))
    }

    func testValidatesStartupDirectoryBeforeGhosttyLaunch() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = try makeTemporaryDirectory()

        // Canonical form: identical to raw `home` on a non-symlinked home, but
        // asserting the canonical form keeps this meaningful on machines whose
        // home is symlinked (INT-498).
        XCTAssertEqual(
            WorkingDirectoryValidator.validatedStartupDirectory("~"),
            WorkingDirectoryValidator.canonicalizedPath(home)
        )
        XCTAssertEqual(
            WorkingDirectoryValidator.validatedStartupDirectory(directory.path),
            directory.path
        )
        XCTAssertNil(WorkingDirectoryValidator.validatedStartupDirectory("/tmp"))
    }

    func testReportedDirectoryFollowsIntoDirectoriesTheUserDoesNotOwn() throws {
        // INT-576: a user can `cd` into a root-owned system directory, so the
        // reported-cwd validator must accept it — otherwise the path bar froze at
        // the persisted cwd for every non-user-owned directory (/usr/share, /tmp,
        // …). Ownership is required only for the startup dir (a shell spawns
        // there), which stays rejected. /usr/share is a stable root-owned dir.
        XCTAssertEqual(
            WorkingDirectoryValidator.validatedReportedDirectory("/usr/share"),
            "/usr/share"
        )
        XCTAssertNil(WorkingDirectoryValidator.validatedStartupDirectory("/usr/share"))
    }

    func testFirstValidatedReportedDirectoryPrefersActiveCandidate() throws {
        let activePaneDirectory = try makeTemporaryDirectory()
        let sessionDirectory = try makeTemporaryDirectory()

        XCTAssertEqual(
            WorkingDirectoryValidator.firstValidatedReportedDirectory(
                from: [activePaneDirectory.path, sessionDirectory.path]
            ),
            activePaneDirectory.path
        )
    }

    func testFirstValidatedReportedDirectoryFallsBackAndExpandsTilde() throws {
        let homeDirectory = try makeTemporaryHomeDirectory()
        let missingActiveDirectory = homeDirectory.appendingPathComponent("missing").path

        XCTAssertEqual(
            WorkingDirectoryValidator.firstValidatedReportedDirectory(
                from: [missingActiveDirectory, "~/\(homeDirectory.lastPathComponent)"]
            ),
            WorkingDirectoryValidator.canonicalizedPath(homeDirectory.path)
        )
    }

    func testFirstValidatedReportedDirectoryKeepsReportedCwdOwnershipSemantics() {
        XCTAssertEqual(
            WorkingDirectoryValidator.firstValidatedReportedDirectory(from: ["/tmp"]),
            WorkingDirectoryValidator.canonicalizedPath("/tmp")
        )
        XCTAssertNil(WorkingDirectoryValidator.validatedStartupDirectory("/tmp"))
    }

    func testSanitizesRestoredDirectoriesWithoutEscapingHome() throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let home = homeURL.path
        let restoredDirectory = try makeTemporaryHomeDirectory()
        let restoredRelativePath = "~/\(restoredDirectory.lastPathComponent)/ProjectCase"
        let restoredAbsolutePath = restoredDirectory
            .appendingPathComponent("ProjectCase", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: restoredAbsolutePath,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("~"), "~")
        XCTAssertEqual(
            WorkingDirectoryValidator.sanitizedRestoredDirectory(restoredRelativePath),
            restoredRelativePath
        )
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory(home), home)
        XCTAssertEqual(
            WorkingDirectoryValidator.sanitizedRestoredDirectory(restoredAbsolutePath),
            restoredAbsolutePath
        )
        XCTAssertEqual(
            WorkingDirectoryValidator.sanitizedRestoredDirectory("~/\(restoredDirectory.lastPathComponent)/./ProjectCase"),
            restoredRelativePath
        )
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/../Shared"), "~")
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("\(home)/../Shared"), "~")
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("/tmp"), "~")
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/Dev\u{2028}elopment"), "~")
        XCTAssertEqual(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/Dev\u{00A0}elopment"), "~")
    }

    func testSanitizedRestoredDirectoryRejectsSymlinkEscapes() throws {
        let outsideHome = try makeTemporaryDirectory()
        let link = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("awesomux-working-directory-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideHome
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: link)
        }

        XCTAssertEqual(
            WorkingDirectoryValidator.sanitizedRestoredDirectory("~/" + link.lastPathComponent),
            "~"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-working-directory-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        // Resolved so round-trip assertions hold now that the validator
        // canonicalizes its return (INT-498): the raw temp path sits behind the
        // /var -> /private/var symlink.
        return directory.resolvingSymlinksInPath()
    }

    private func makeTemporaryHomeDirectory() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("awesomux-working-directory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
