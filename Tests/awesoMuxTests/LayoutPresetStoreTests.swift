import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@Suite struct LayoutPresetStoreTests {
    private let fileManager = FileManager.default

    /// Owns every directory this suite creates. Previously each
    /// `makeProjectRoot()` minted a `NSTemporaryDirectory()` root that nothing
    /// ever removed — 4,140 of them had accumulated in one `$TMPDIR`, the
    /// largest single leaker in the test suite. Roots stay UUID-suffixed
    /// underneath it because several tests need two distinct roots at once.
    private let temporaryDirectory: TemporaryDirectory

    init() throws {
        temporaryDirectory = try TemporaryDirectory(prefix: "layout-preset-tests")
    }

    /// A fresh fake project root; `git: true` plants a `.git` directory.
    private func makeProjectRoot(git: Bool = true) throws -> URL {
        let root = temporaryDirectory.url
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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

    @Test(arguments: [
        "", "   ", "..", "../evil", "a/b", "a\\b", "name.json", "naïve", "a\u{0000}b",
        String(repeating: "x", count: 65),
    ])
    func hostileNamesAreRejected(raw: String) {
        #expect(LayoutPresetStore.sanitizedPresetName(raw) == nil)
    }

    // MARK: - Save / load round trip

    @Test func saveFromLinkedWorktreeLandsInTheWorktreeRootNotTheMainRepo() throws {
        // A linked worktree's `.git` is a FILE (gitdir pointer). The walker
        // must stop at the worktree's own root — the preset belongs to the
        // checkout the user is working in, never silently to the main repo.
        let mainRepo = try makeProjectRoot()
        let worktree = temporaryDirectory.url
            .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        let nested = worktree.appendingPathComponent("src", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("gitdir: \(mainRepo.path)/.git/worktrees/wt\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        let intent = sampleIntent()
        let savedURL = try LayoutPresetStore.save(
            intent, named: "dev", forWorkingDirectory: nested.path
        )

        #expect(
            savedURL.standardizedFileURL.path
                == worktree.standardizedFileURL
                .appendingPathComponent(".awesomux/layouts/dev.json").path
        )
        #expect(
            !fileManager.fileExists(
                atPath: mainRepo.appendingPathComponent(".awesomux").path
            )
        )
        // List and load resolve to the same root from the same anchor.
        #expect(LayoutPresetStore.listPresetNames(forWorkingDirectory: nested.path) == ["dev"])
        #expect(try LayoutPresetStore.load(named: "dev", forWorkingDirectory: nested.path) == intent)
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

    // MARK: - Listing

    @Test func listingStopsScanningAtTheInjectedCapRegardlessOfDirectorySize() throws {
        // Proves the scan itself is bounded (not just the returned count):
        // with a scan cap far below both the file count and `maxListedPresets`,
        // the result must be capped at `scanLimit`, not at `maxListedPresets`.
        let root = try makeProjectRoot()
        let layouts = root.appendingPathComponent(".awesomux/layouts", isDirectory: true)
        try fileManager.createDirectory(at: layouts, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data("{}".utf8).write(
                to: layouts.appendingPathComponent(String(format: "preset-%03d.json", index))
            )
        }

        let names = LayoutPresetStore.listPresetNames(
            forWorkingDirectory: root.path,
            scanLimit: 3
        )
        #expect(names.count == 3)
    }

}
