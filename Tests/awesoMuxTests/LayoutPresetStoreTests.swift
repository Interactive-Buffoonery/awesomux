import AwesoMuxCore
import Foundation
import Testing
@testable import awesoMux

@Suite struct LayoutPresetStoreTests {
    private let fileManager = FileManager.default

    /// A fresh fake project root; `git: true` plants a `.git` directory.
    private func makeProjectRoot(git: Bool = true) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("layout-preset-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if git {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(".git"),
                withIntermediateDirectories: false
            )
        }
        return root
    }

    private func sampleIntent(title: String? = "A") -> WorkspaceLayoutIntent {
        WorkspaceLayoutIntent(
            root: .split(
                .init(
                    orientation: .vertical,
                    firstFraction: 0.4,
                    first: .terminal(.init(title: title, color: nil)),
                    second: .terminal(.init(title: nil, color: nil))
                )
            )
        )
    }

    // MARK: - Names

    @Test(arguments: ["dev", "Dev Split 2", "tri-row_wide", "  padded  "])
    func acceptableNamesSanitize(raw: String) {
        #expect(LayoutPresetStore.sanitizedPresetName(raw) != nil)
    }

    @Test(arguments: [
        "", "   ", "..", "../evil", "a/b", "a\\b", "name.json", "naïve", "a\u{0000}b",
        String(repeating: "x", count: 65),
    ])
    func hostileNamesAreRejected(raw: String) {
        #expect(LayoutPresetStore.sanitizedPresetName(raw) == nil)
    }

    // MARK: - Root resolution

    @Test func projectRootPrefersGitAncestor() throws {
        let root = try makeProjectRoot()
        let nested = root.appendingPathComponent("src/deep", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let resolved = LayoutPresetStore.projectRoot(forWorkingDirectory: nested.path)
        #expect(resolved?.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func projectRootFallsBackToWorkingDirectoryOutsideGit() throws {
        let root = try makeProjectRoot(git: false)
        let resolved = LayoutPresetStore.projectRoot(forWorkingDirectory: root.path)
        #expect(resolved?.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func projectRootIsNilForMissingDirectory() {
        #expect(
            LayoutPresetStore.projectRoot(
                forWorkingDirectory: "/nonexistent/definitely-not-here-\(UUID().uuidString)"
            ) == nil
        )
    }

    // MARK: - Save / load round trip

    @Test func saveThenLoadRoundTripsFromANestedWorkingDirectory() throws {
        let root = try makeProjectRoot()
        let nested = root.appendingPathComponent("pkg", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)

        let intent = sampleIntent()
        let savedURL = try LayoutPresetStore.save(
            intent, named: "dev", forWorkingDirectory: nested.path
        )
        #expect(savedURL.path.hasSuffix(".awesomux/layouts/dev.json"))
        // Saved at the git ROOT even when invoked from a subdirectory.
        #expect(savedURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path))

        #expect(LayoutPresetStore.presetFileExists(named: "dev", forWorkingDirectory: nested.path))
        let loaded = try LayoutPresetStore.load(named: "dev", forWorkingDirectory: root.path)
        #expect(loaded == intent)
        #expect(LayoutPresetStore.listPresetNames(forWorkingDirectory: nested.path) == ["dev"])
    }

    @Test func saveRejectsInvalidName() throws {
        let root = try makeProjectRoot()
        #expect(throws: LayoutPresetStore.PresetError.invalidName) {
            try LayoutPresetStore.save(
                sampleIntent(), named: "../escape", forWorkingDirectory: root.path
            )
        }
    }

    // MARK: - Symlink containment

    @Test func loadAndSaveRefuseASymlinkedLayoutsDirectory() throws {
        let root = try makeProjectRoot()
        let outside = try makeProjectRoot(git: false)
        let awesomuxDir = root.appendingPathComponent(".awesomux", isDirectory: true)
        try fileManager.createDirectory(at: awesomuxDir, withIntermediateDirectories: false)
        try fileManager.createSymbolicLink(
            at: awesomuxDir.appendingPathComponent("layouts"),
            withDestinationURL: outside
        )

        #expect(throws: LayoutPresetStore.PresetError.directoryUnavailable) {
            try LayoutPresetStore.load(named: "dev", forWorkingDirectory: root.path)
        }
        #expect(throws: LayoutPresetStore.PresetError.directoryUnavailable) {
            try LayoutPresetStore.save(sampleIntent(), named: "dev", forWorkingDirectory: root.path)
        }
        // A symlinked directory also must not leak names into the palette list.
        try (try? JSONEncoder().encode(WorkspaceLayoutPreset(layout: sampleIntent())))
            .map { try $0.write(to: outside.appendingPathComponent("evil.json")) }
        #expect(LayoutPresetStore.listPresetNames(forWorkingDirectory: root.path).isEmpty)
    }

    @Test func loadAndSaveRefuseASymlinkedPresetFile() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        try fileManager.createSymbolicLink(
            at: layouts.appendingPathComponent("dev.json"),
            withDestinationURL: secret
        )

        #expect(throws: LayoutPresetStore.PresetError.notARegularFile) {
            try LayoutPresetStore.load(named: "dev", forWorkingDirectory: root.path)
        }
        #expect(throws: LayoutPresetStore.PresetError.notARegularFile) {
            try LayoutPresetStore.save(sampleIntent(), named: "dev", forWorkingDirectory: root.path)
        }
        // The symlink target must be untouched after the refused save.
        #expect(try Data(contentsOf: secret) == Data("secret".utf8))
    }

    // MARK: - Hostile file contents

    @Test func loadRejectsOversizedFile() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        let big = Data(repeating: UInt8(ascii: " "), count: LayoutPresetStore.maxPresetBytes + 1)
        try big.write(to: layouts.appendingPathComponent("big.json"))

        #expect(throws: LayoutPresetStore.PresetError.fileTooLarge) {
            try LayoutPresetStore.load(named: "big", forWorkingDirectory: root.path)
        }
    }

    @Test func loadRejectsNestingBombBeforeDecoding() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        let depth = LayoutPresetStore.maxPresetNestingDepth + 8
        let bomb = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        try Data(bomb.utf8).write(to: layouts.appendingPathComponent("bomb.json"))

        #expect(throws: LayoutPresetStore.PresetError.nestingTooDeep) {
            try LayoutPresetStore.load(named: "bomb", forWorkingDirectory: root.path)
        }
    }

    @Test func loadSurfacesUnsupportedVersion() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        let future = "{\"version\":2,\"layout\":{\"root\":{\"terminal\":{\"_0\":{}}}}}"
        try Data(future.utf8).write(to: layouts.appendingPathComponent("future.json"))

        #expect(throws: WorkspaceLayoutPresetError.unsupportedVersion(2)) {
            try LayoutPresetStore.load(named: "future", forWorkingDirectory: root.path)
        }
    }

    // MARK: - Listing

    @Test func listingSkipsInvalidNamesAndNonJSONAndSorts() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        for filename in ["zeta.json", "alpha.json", "Mid Split.json", "bad..name.json", "notes.txt", ".hidden.json"] {
            try Data("{}".utf8).write(to: layouts.appendingPathComponent(filename))
        }

        let names = LayoutPresetStore.listPresetNames(forWorkingDirectory: root.path)
        #expect(names == ["alpha", "Mid Split", "zeta"])
    }

    @Test func listingIsEmptyWhenDirectoryMissing() throws {
        let root = try makeProjectRoot()
        #expect(LayoutPresetStore.listPresetNames(forWorkingDirectory: root.path).isEmpty)
    }

    @Test func listingIsCapped() throws {
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        for index in 0..<(LayoutPresetStore.maxListedPresets + 10) {
            try Data("{}".utf8).write(
                to: layouts.appendingPathComponent(String(format: "preset-%03d.json", index))
            )
        }
        let names = LayoutPresetStore.listPresetNames(forWorkingDirectory: root.path)
        #expect(names.count == LayoutPresetStore.maxListedPresets)
    }

    // MARK: - Overwrite

    @Test func saveOverwritesExistingRegularFileAtomically() throws {
        let root = try makeProjectRoot()
        try LayoutPresetStore.save(sampleIntent(title: "old"), named: "dev", forWorkingDirectory: root.path)
        try LayoutPresetStore.save(sampleIntent(title: "new"), named: "dev", forWorkingDirectory: root.path)
        let loaded = try LayoutPresetStore.load(named: "dev", forWorkingDirectory: root.path)
        guard case let .split(split) = loaded.root, case let .terminal(first) = split.first else {
            Issue.record("expected split with terminal first")
            return
        }
        #expect(first.title == "new")
    }
}
