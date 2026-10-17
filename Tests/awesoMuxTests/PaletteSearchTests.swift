import Foundation
import Testing
@testable import awesoMux

@Suite("Palette search")
struct PaletteSearchTests {
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
