import Foundation
import Testing
@testable import AwesoMuxCore

/// INT-498: working directories are canonicalized once at ingest so the raw
/// home-prefix strips in the display layer stay correct under a symlinked /
/// non-canonical home.
@Suite struct WorkingDirectoryCanonicalizationTests {
    @Test func validatedReportedDirectoryResolvesSymlinks() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-int498-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let target = base.appendingPathComponent("target", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        // Assert against the RESOLVED target path: the temp base itself sits
        // behind the /var -> /private/var symlink, so comparing to the raw
        // target path would fail for the wrong reason.
        let resolvedTarget = WorkingDirectoryValidator.canonicalizedPath(target.path)
        #expect(
            WorkingDirectoryValidator.validatedReportedDirectory(link.path) == resolvedTarget
        )
    }

    @Test func symlinkedHomeDoesNotLeakHomePathIntoDisplayContext() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-int498-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        // Simulated symlinked-home layout: `FileManager` would report the
        // symlink form (`home-link`) while the shell's OSC 7 (getcwd) reports
        // the physical path under `real-home`.
        let realHome = base.appendingPathComponent("real-home", isDirectory: true)
        try fileManager.createDirectory(
            at: realHome.appendingPathComponent("project", isDirectory: true),
            withIntermediateDirectories: true
        )
        let linkHome = base.appendingPathComponent("home-link")
        try fileManager.createSymbolicLink(at: linkHome, withDestinationURL: realHome)

        // Both production transforms, on DIVERGENT input forms: the stored cwd
        // goes through the validator on the physical path; the home constant is
        // derived by canonicalizing the symlink-form home. Before INT-498 the
        // home side stayed raw, the prefix strip failed, and the absolute home
        // path surfaced in displayContext.
        let physicalProject = WorkingDirectoryValidator.canonicalizedPath(realHome.path)
            + "/project"
        let storedCwd = try #require(
            WorkingDirectoryValidator.validatedReportedDirectory(physicalProject)
        )
        let homeConstant = WorkingDirectoryValidator.canonicalizedPath(linkHome.path)

        // Same title + same cwd in two groups forces the group-plus-FULL-path
        // fallback — the shape where an unstripped home leaks every component
        // of the absolute path. (A lone session resolves to its leaf at depth 1
        // whether or not the strip worked, so it can't catch this.)
        let first = TerminalSession(
            title: "agent",
            workingDirectory: storedCwd,
            agentKind: .claudeCode
        )
        let second = TerminalSession(
            title: "agent",
            workingDirectory: storedCwd,
            agentKind: .claudeCode
        )
        let contexts = WorkspaceNotificationEvent.displayContextsBySessionID(
            in: [
                SessionGroup(name: "Work", sessions: [first]),
                SessionGroup(name: "Scratch", sessions: [second])
            ],
            homeDirectory: homeConstant
        )

        #expect(contexts[first.id] == "Work · project")
        #expect(contexts[second.id] == "Scratch · project")
        #expect(contexts[first.id]?.contains("real-home") == false)
    }

    @Test func startupOwnershipGuardChecksTheSymlinkTarget() throws {
        // `attributesOfItem` does not traverse a final symlink, so pre-INT-498
        // a user-owned symlink into a root-owned directory satisfied the spawn
        // ownership guard. The guard now runs on the canonical path.
        let fileManager = FileManager.default
        let link = fileManager.temporaryDirectory
            .appendingPathComponent("awesomux-int498-link-to-usr-share-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/usr/share", isDirectory: true)
        )
        defer { try? fileManager.removeItem(at: link) }

        #expect(WorkingDirectoryValidator.validatedStartupDirectory(link.path) == nil)
        // The relaxed reported-cwd path still follows it (display-only, INT-576).
        #expect(
            WorkingDirectoryValidator.validatedReportedDirectory(link.path) == "/usr/share"
        )
    }

    @Test func processHomeDirectoryIsCanonical() {
        // Pins the constant wiring; a no-op on machines whose home is already
        // canonical, load-bearing under a symlinked home.
        #expect(
            WorkspaceNotificationEvent.processHomeDirectory
                == WorkingDirectoryValidator.canonicalizedPath(
                    FileManager.default.homeDirectoryForCurrentUser.path
                )
        )
        #expect(
            WorkingDirectoryValidator.canonicalHomeDirectory
                == WorkingDirectoryValidator.canonicalizedPath(
                    FileManager.default.homeDirectoryForCurrentUser.path
                )
        )
    }
}
