import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkingDirectoryValidatorTests {
    private enum Reported: CaseIterable {
        case directory, fileURL, localhost, remoteHost, relative, missing, file, nul, encodedNul, system, symlink
    }

    @Test(arguments: Reported.allCases)
    private func reportedDirectory(scenario: Reported) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let link = directory.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/share"))
        let raw: String
        let expected: String?
        switch scenario {
        case .directory: raw = directory.path; expected = directory.path
        case .fileURL: raw = directory.absoluteString; expected = directory.path
        case .localhost: raw = "file://localhost\(directory.path)"; expected = directory.path
        case .remoteHost: raw = "file://example.test\(directory.path)"; expected = nil
        case .relative: raw = "relative/path"; expected = nil
        case .missing: raw = directory.appendingPathComponent("missing").path; expected = nil
        case .file: raw = file.path; expected = nil
        case .nul: raw = "\(directory.path)\u{0}"; expected = nil
        case .encodedNul: raw = "file://localhost\(directory.path)%00"; expected = nil
        case .system: raw = "/usr/share"; expected = "/usr/share"
        case .symlink: raw = link.path; expected = "/usr/share"
        }
        #expect(WorkingDirectoryValidator.validatedReportedDirectory(raw) == expected)
    }

    @Test(arguments: ["~", "temporary", "/tmp", "/usr/share", "symlink"])
    func startupOwnership(input: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/usr/share"))
        let raw = input == "temporary" ? directory.path : input == "symlink" ? link.path : input
        let expected: String? =
            input == "~"
            ? WorkingDirectoryValidator.canonicalizedPath(FileManager.default.homeDirectoryForCurrentUser.path)
            : input == "temporary" ? directory.path : nil
        #expect(WorkingDirectoryValidator.validatedStartupDirectory(raw) == expected)
    }

    @Test func testSanitizesRestoredDirectoriesWithoutEscapingHome() throws {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let home = homeURL.path
        let restoredDirectory = try makeTemporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: restoredDirectory) }
        let restoredRelativePath = "~/\(restoredDirectory.lastPathComponent)/ProjectCase"
        let restoredAbsolutePath = restoredDirectory
            .appendingPathComponent("ProjectCase", isDirectory: true)
            .path
        try FileManager.default.createDirectory(
            atPath: restoredAbsolutePath,
            withIntermediateDirectories: true
        )

        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("~") == "~")
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory(restoredRelativePath) == restoredRelativePath)
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory(home) == home)
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory(restoredAbsolutePath) == restoredAbsolutePath)
        #expect(
            WorkingDirectoryValidator.sanitizedRestoredDirectory("~/\(restoredDirectory.lastPathComponent)/./ProjectCase")
                == restoredRelativePath)
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/../Shared") == "~")
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("\(home)/../Shared") == "~")
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("/tmp") == "~")
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/Dev\u{2028}elopment") == "~")
        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/Dev\u{00A0}elopment") == "~")
    }

    @Test func testSanitizedRestoredDirectoryRejectsSymlinkEscapes() throws {
        let outsideHome = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outsideHome) }
        let link = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("awesomux-working-directory-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outsideHome
        )
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(WorkingDirectoryValidator.sanitizedRestoredDirectory("~/" + link.lastPathComponent) == "~")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("awesomux-working-directory-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
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
        return directory
    }
}
