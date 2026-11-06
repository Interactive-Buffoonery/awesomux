import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite("Palette search")
struct PaletteSearchTests {
    @Test(
        "Workspace matches take precedence over executable queries",
        arguments: ["top", "  top  ", "ssh", "top notes"])
    @MainActor
    func workspaceIsNotHiddenByQuickRun(query: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["top", "ssh"] {
            let executable = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let sessions = [
            TerminalSession(title: "top", workingDirectory: "/tmp"),
            TerminalSession(title: "top notes", workingDirectory: "/tmp"),
            TerminalSession(title: "tooling project", workingDirectory: "/tmp"),
            TerminalSession(title: "Remote", workingDirectory: "/tmp/ssh/project"),
        ]
        let groups = [SessionGroup(name: "Main", sessions: sessions)]
        // A missing executable gives the existing navigation ordering as the baseline.
        let navigation = PaletteSearch.results(
            groups: groups, commands: [], rawQuery: query, quickRunSearchPath: ""
        )
        let results = PaletteSearch.results(
            groups: groups, commands: [], rawQuery: query, quickRunSearchPath: directory.path
        )
        #expect(!navigation.flattened.isEmpty)
        #expect(results.mode == .unified)
        #expect(results.flattened.map(\.id) == navigation.flattened.map(\.id))
        #expect(results.defaultSelectionIndex == 0)

        let bareCommand = PaletteSearch.results(
            groups: [], commands: [], rawQuery: query, quickRunSearchPath: directory.path
        )
        #expect(bareCommand.mode == .quickRun)
        let commandOnly = PaletteSearch.results(
            groups: groups, commands: [], rawQuery: "top -l 1", quickRunSearchPath: directory.path
        )
        #expect(commandOnly.mode == .quickRun)
        let actionsOnly = PaletteSearch.results(
            groups: groups, commands: [], rawQuery: ">top", quickRunSearchPath: directory.path
        )
        #expect(actionsOnly.mode == .actionsOnly)
        #expect(actionsOnly.flattened.isEmpty)
        let empty = PaletteSearch.results(groups: groups, commands: [], rawQuery: "  ")
        #expect(empty.defaultSelectionIndex == nil)
    }

    @Test(
        "An app action remains searchable when its first word is an executable",
        arguments: ["view", "view f", "View Files", "  view files  "])
    @MainActor
    func actionIsNotHiddenByQuickRun(query: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("view")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = PaletteCommand(
            id: "viewFiles", title: "View Files", subtitle: nil, keywords: ["files", "markdown"],
            shortcut: nil, isEnabled: true, selectionScope: .pane, run: {}
        )
        let results = PaletteSearch.results(
            groups: [], commands: [command], rawQuery: query, quickRunSearchPath: directory.path
        )
        #expect(
            results.flattened.contains {
                if case .command(let result) = $0 { return result.commandID == "viewFiles" }
                return false
            })
        let shellResults = PaletteSearch.results(
            groups: [], commands: [command], rawQuery: "view notes.md", quickRunSearchPath: directory.path
        )
        #expect(shellResults.mode == .quickRun)
    }
}
