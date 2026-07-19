import AwesoMuxCore
import Darwin
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
    /// Hard cap on directory entries walked per listing call. A checked-in
    /// layouts directory is expected to hold a handful of presets; this cap
    /// only exists to bound a hostile/huge directory, so the top-50 alphabetical
    /// order is exact under normal sizes and a best-effort approximation past
    /// the cap.
    static let maxScannedListingEntries = 4096
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
        fileManager: FileManager = .default,
        scanLimit: Int = maxScannedListingEntries
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
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.nameKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            )
        else {
            return []
        }

        // Bound the enumeration itself, not only the returned count — a huge
        // (hostile) directory must not make this synchronous scan hang the
        // main thread. `enumerator` streams entries lazily, so breaking early
        // skips the rest of the directory instead of materializing it first.
        // `scanLimit` defaults to `maxScannedListingEntries`; overridable so
        // tests can prove the early-break without creating a huge directory.
        let suffix = "." + fileExtension
        var candidates: [String] = []
        var scanned = 0
        for case let entryURL as URL in enumerator {
            scanned += 1
            if scanned > scanLimit { break }
            let entryName = entryURL.lastPathComponent
            guard entryName.hasSuffix(suffix) else { continue }
            let candidate = String(entryName.dropLast(suffix.count))
            guard sanitizedPresetName(candidate) == candidate else { continue }
            candidates.append(candidate)
        }

        return
            candidates
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

        // Pin the validated directory by descriptor right away: every op below
        // is `openat`/`renameat` relative to this fd, never a path re-resolve —
        // closing the TOCTOU window where a symlink swapped in after
        // `validatedLayoutsDirectory` returns could redirect the write.
        let directoryDescriptor = try openDirectoryDescriptor(root: root)
        defer { close(directoryDescriptor) }

        let fileName = clean + "." + fileExtension

        // Refuse to replace anything that isn't a regular file — checked via
        // the pinned descriptor (not a path lookup) so an attacker-planted
        // symlink at the destination is detected, not followed.
        var existingStatus = stat()
        let existingStatResult = fileName.withCString {
            fstatat(directoryDescriptor, $0, &existingStatus, AT_SYMLINK_NOFOLLOW)
        }
        if existingStatResult == 0 {
            guard (existingStatus.st_mode & S_IFMT) == S_IFREG else {
                throw PresetError.notARegularFile
            }
        } else if errno != ENOENT {
            // Anything other than "doesn't exist" (permissions, I/O error,
            // a broken mount) must abort, not silently fall through to
            // "safe to create" — failing open here defeats the check.
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let preset = try WorkspaceLayoutPreset(layout: intent)
        let encoder = JSONEncoder()
        // Pretty + sorted: the file is meant to be checked in, so diffs must be
        // stable and human-reviewable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preset)

        // Save must never write a preset this same build would refuse to
        // load — check the same cap `load` enforces, before any bytes exist.
        guard data.count <= maxPresetBytes else {
            throw PresetError.fileTooLarge
        }

        try writePresetData(data, directoryDescriptor: directoryDescriptor, finalName: fileName)
        return directory.appendingPathComponent(fileName, isDirectory: false)
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

        // `openDirectoryDescriptor` walks `.awesomux`/`layouts` itself (each
        // hop `O_NOFOLLOW`), so it both validates AND pins the directory —
        // a separate `validatedLayoutsDirectory` path-based check first would
        // just re-walk the same components and reopen the same TOCTOU window.
        let directoryDescriptor = try openDirectoryDescriptor(root: root)
        defer { close(directoryDescriptor) }

        let fileName = clean + "." + fileExtension
        let fileDescriptor = fileName.withCString {
            Darwin.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else {
            // `O_NOFOLLOW` turns "the entry is a symlink" into `ELOOP` instead
            // of transparently following it — map that back to the same
            // error a directory/other-non-regular-type entry gets below.
            if errno == ELOOP {
                throw PresetError.notARegularFile
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fileDescriptor) }

        // `fstat` on the descriptor we're about to read — not a path lookup —
        // is both the regular-file gate and the pre-read size gate.
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw PresetError.notARegularFile
        }
        guard status.st_size >= 0, status.st_size <= maxPresetBytes else {
            throw PresetError.fileTooLarge
        }

        let data = try readPresetData(from: fileDescriptor, size: Int(status.st_size))
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

    // MARK: - Descriptor-relative file I/O

    /// Pins `<root>/.awesomux/layouts` by descriptor via a component-by-component
    /// `openat` walk, each hop with `O_NOFOLLOW`. Opening the full joined path
    /// in one `open()` call only guards its FINAL component — an intermediate
    /// component (`.awesomux` itself) swapped for a symlink between
    /// `validatedLayoutsDirectory` returning and that single call would still
    /// be followed. Walking hop-by-hop from `root` closes that gap too.
    private static func openDirectoryDescriptor(root: URL) throws -> Int32 {
        var currentDescriptor = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard currentDescriptor >= 0 else {
            throw PresetError.directoryUnavailable
        }
        for component in directoryComponents {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            close(currentDescriptor)
            guard nextDescriptor >= 0 else {
                throw PresetError.directoryUnavailable
            }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    /// Writes `data` to `finalName` inside `directoryDescriptor` via a
    /// temp-file-then-`renameat` swap, both resolved relative to the same
    /// pinned directory fd. `rename` replaces the destination directory entry
    /// atomically without following it even if that entry is a symlink, so
    /// this is safe regardless of what (if anything) currently sits at
    /// `finalName`.
    private static func writePresetData(
        _ data: Data,
        directoryDescriptor: Int32,
        finalName: String
    ) throws {
        let tempName = finalName + ".tmp-" + UUID().uuidString

        let tempDescriptor = tempName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard tempDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var writeError: Error?
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            guard var pointer = rawBuffer.baseAddress, rawBuffer.count > 0 else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let bytesWritten = Darwin.write(tempDescriptor, pointer, remaining)
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    writeError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    return
                }
                pointer = pointer.advanced(by: bytesWritten)
                remaining -= bytesWritten
            }
        }
        close(tempDescriptor)

        if let writeError {
            // Best-effort cleanup — the write itself already failed, so a
            // failed unlink here has no better error to surface.
            _ = tempName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            throw writeError
        }

        let renamed = tempName.withCString { tempPointer in
            finalName.withCString { finalPointer in
                Darwin.renameat(directoryDescriptor, tempPointer, directoryDescriptor, finalPointer)
            }
        }
        guard renamed == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            _ = tempName.withCString { unlinkat(directoryDescriptor, $0, 0) }
            throw error
        }
    }

    /// Reads exactly `size` bytes (the size `fstat` already measured) from
    /// `descriptor` via `pread`, so a file that grows after that `fstat`
    /// still can't yield more bytes than were validated against
    /// `maxPresetBytes`.
    private static func readPresetData(from descriptor: Int32, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: size)
        var totalRead = 0
        while totalRead < size {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                pread(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: totalRead),
                    size - totalRead,
                    off_t(totalRead)
                )
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if bytesRead == 0 { break }  // file shrank mid-read; stop at what's there
            totalRead += bytesRead
        }
        return Data(buffer[0..<totalRead])
    }
}
