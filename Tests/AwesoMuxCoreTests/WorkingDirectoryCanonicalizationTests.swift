import Foundation
import Testing
@testable import AwesoMuxCore

/// INT-498: working directories are canonicalized once at ingest so the raw
/// home-prefix strips in the display layer stay correct under a symlinked /
/// non-canonical home.
@Suite struct WorkingDirectoryCanonicalizationTests {

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

}
