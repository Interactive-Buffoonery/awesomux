import AwesoMuxCore
import Foundation

/// Reads and writes named, checked-in layout presets under
/// `<projectRoot>/.awesomux/layouts/<name>.json` (INT-757).
///
/// Preset files are UNTRUSTED input — checked into repos and shared — so every
/// path through this store enforces the same containment rules:
///
/// - **Names** are a strict allowlist (`sanitizedPresetName`): letters, digits,
///   spaces, `-`, `_`, at most `maxNameLength` characters. No dots, no
///   separators — path traversal is unrepresentable, and the filename doubles
///   as the preset's display name.
/// - **Directories**: each `.awesomux` / `layouts` component must be a real
///   directory, never a symlink — a checked-in symlink would redirect save
///   (arbitrary overwrite) or load (arbitrary read) outside the project.
///   `attributesOfItem` does not traverse a trailing symlink, so the `.type`
///   check sees the link itself.
/// - **Files**: only regular files are read or overwritten, size-capped BEFORE
///   the bytes are handed to a decoder, and byte-level nesting pre-scanned
///   before `JSONDecoder` runs (the decoder-level depth guard in
///   `WorkspaceLayoutIntent` cannot protect the JSON parser's own recursion —
///   same layering as `SessionPersistence.load`).
/// - Semantic caps (split depth, terminal count) live in
///   `WorkspaceLayoutPreset`'s decode, so nothing here can create a pane.
///
/// The project root is the nearest `.git` ancestor of the workspace's
/// (tilde-expanded) working directory, falling back to that directory itself —
/// the same walker the path bar uses (`GitRepoRootLocator`).
enum LayoutPresetStore {
    static let maxPresetBytes = 128 * 1024
    static let maxNameLength = 64
    static let maxListedPresets = 50
    /// Byte-level `{`/`[` nesting cap applied before `JSONDecoder`. The preset
    /// format spends a handful of braces per split level, so anything within
    /// `WorkspaceLayoutPreset.maxSplitDepth` sits far below this; anything
    /// above it is a crafted file trying to overflow the JSON parser.
    static let maxPresetNestingDepth = 128

    private static let fileExtension = "json"
    private static let directoryComponents = [".awesomux", "layouts"]

    enum PresetError: Error, Equatable {
        case invalidName
        case rootUnavailable
        case directoryUnavailable
        case notARegularFile
        case fileTooLarge
        case nestingTooDeep
    }

    // MARK: - Names

    /// Strict allowlist; returns the trimmed name or `nil` when unusable.
    static func sanitizedPresetName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength else { return nil }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-"
        )
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    // MARK: - Root resolution

    /// Nearest `.git` ancestor of the tilde-expanded working directory, else
    /// the directory itself. `nil` when the directory does not exist — a preset
    /// root must be a real place before we create anything under it.
    static func projectRoot(
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let expanded = NSString(string: workingDirectory).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        let url = URL(fileURLWithPath: expanded)
        return GitRepoRootLocator.repoRootURL(startingAt: url, fileManager: fileManager)
            ?? url.standardizedFileURL
    }

    // MARK: - Listing

    /// Preset names for the palette/picker: `*.json` basenames that round-trip
    /// the name allowlist, sorted, capped. Invalid or missing directories list
    /// as empty — listing must never alert. Per-file validation (regular file,
    /// size, decode) happens at load time, when the user actually picks one.
    // ponytail: one synchronous bounded readdir at palette summon; move behind
    // an off-main-actor snapshot if a pathological checked-in directory ever
    // measurably stalls palette presentation.
    static func listPresetNames(
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        guard
            let root = projectRoot(
                forWorkingDirectory: workingDirectory,
                fileManager: fileManager
            ),
            let directory = try? validatedLayoutsDirectory(
                root: root,
                fileManager: fileManager,
                createIfMissing: false
            ),
            let entries = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else {
            return []
        }

        let suffix = "." + fileExtension
        return
            entries
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .filter { sanitizedPresetName($0) == $0 }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(maxListedPresets)
            .map { $0 }
    }

    // MARK: - Save

    static func presetFileExists(
        named name: String,
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let clean = sanitizedPresetName(name),
            let root = projectRoot(
                forWorkingDirectory: workingDirectory,
                fileManager: fileManager
            ),
            let directory = try? validatedLayoutsDirectory(
                root: root,
                fileManager: fileManager,
                createIfMissing: false
            )
        else {
            return false
        }
        return fileManager.fileExists(
            atPath: presetFileURL(named: clean, in: directory).path
        )
    }

    @discardableResult
    static func save(
        _ intent: WorkspaceLayoutIntent,
        named name: String,
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let clean = sanitizedPresetName(name) else {
            throw PresetError.invalidName
        }
        guard
            let root = projectRoot(
                forWorkingDirectory: workingDirectory,
                fileManager: fileManager
            )
        else {
            throw PresetError.rootUnavailable
        }
        let directory = try validatedLayoutsDirectory(
            root: root,
            fileManager: fileManager,
            createIfMissing: true
        )
        let fileURL = presetFileURL(named: clean, in: directory)

        // Refuse to replace anything that isn't a regular file — an
        // attacker-planted symlink at the destination must not silently become
        // (or briefly act as) the write target.
        if let existingType = try? fileManager.attributesOfItem(atPath: fileURL.path)[.type]
            as? FileAttributeType
        {
            guard existingType == .typeRegular else {
                throw PresetError.notARegularFile
            }
        }

        let encoder = JSONEncoder()
        // Pretty + sorted: the file is meant to be checked in, so diffs must be
        // stable and human-reviewable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(WorkspaceLayoutPreset(layout: intent))
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - Load

    static func load(
        named name: String,
        forWorkingDirectory workingDirectory: String,
        fileManager: FileManager = .default
    ) throws -> WorkspaceLayoutIntent {
        guard let clean = sanitizedPresetName(name) else {
            throw PresetError.invalidName
        }
        guard
            let root = projectRoot(
                forWorkingDirectory: workingDirectory,
                fileManager: fileManager
            )
        else {
            throw PresetError.rootUnavailable
        }
        let directory = try validatedLayoutsDirectory(
            root: root,
            fileManager: fileManager,
            createIfMissing: false
        )
        let fileURL = presetFileURL(named: clean, in: directory)

        // `attributesOfItem` sees a trailing symlink as `.typeSymbolicLink`
        // (no traversal), so this one call is both the regular-file gate and
        // the pre-read size gate.
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw PresetError.notARegularFile
        }
        if let size = attributes[.size] as? Int, size > maxPresetBytes {
            throw PresetError.fileTooLarge
        }

        let data = try Data(contentsOf: fileURL)
        guard data.count <= maxPresetBytes else {
            throw PresetError.fileTooLarge
        }
        guard SessionPersistence.maxJSONNestingDepth(in: data) <= maxPresetNestingDepth else {
            throw PresetError.nestingTooDeep
        }

        return try JSONDecoder().decode(WorkspaceLayoutPreset.self, from: data).layout
    }

    // MARK: - Directory validation

    /// Walks `<root>/.awesomux/layouts`, requiring every EXISTING component to
    /// be a real (non-symlink) directory and optionally creating missing ones.
    /// Because component names come from a fixed list and preset names from the
    /// no-separator allowlist, passing this validation proves the final path
    /// cannot escape `root` — no resolved-prefix comparison needed.
    private static func validatedLayoutsDirectory(
        root: URL,
        fileManager: FileManager,
        createIfMissing: Bool
    ) throws -> URL {
        var current = root
        for component in directoryComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            if let type = try? fileManager.attributesOfItem(atPath: current.path)[.type]
                as? FileAttributeType
            {
                guard type == .typeDirectory else {
                    throw PresetError.directoryUnavailable
                }
            } else if createIfMissing {
                try fileManager.createDirectory(
                    at: current,
                    withIntermediateDirectories: false
                )
                // Re-check after creation: if something raced a symlink into
                // place, refuse rather than write through it.
                guard
                    (try? fileManager.attributesOfItem(atPath: current.path)[.type]
                        as? FileAttributeType) == .typeDirectory
                else {
                    throw PresetError.directoryUnavailable
                }
            } else {
                throw PresetError.directoryUnavailable
            }
        }
        return current
    }

    private static func presetFileURL(named clean: String, in directory: URL) -> URL {
        directory.appendingPathComponent(
            clean + "." + fileExtension,
            isDirectory: false
        )
    }
}
