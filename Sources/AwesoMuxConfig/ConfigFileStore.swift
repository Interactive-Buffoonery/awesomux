import Darwin
import Foundation
import SecureFileIO

public struct ConfigFileStore: Sendable {
    public let configURL: URL

    private let codec: TOMLConfigCodec
    private let effectiveUID: uid_t

    public init(
        pathResolver: ConfigPathResolver = .default,
        codec: TOMLConfigCodec = TOMLConfigCodec()
    ) {
        self.configURL = pathResolver.configFileURL
        self.codec = codec
        self.effectiveUID = geteuid()
    }

    public init(
        configURL: URL,
        codec: TOMLConfigCodec = TOMLConfigCodec()
    ) {
        self.configURL = configURL
        self.codec = codec
        self.effectiveUID = geteuid()
    }

    init(
        configURL: URL,
        codec: TOMLConfigCodec = TOMLConfigCodec(),
        effectiveUID: uid_t
    ) {
        self.configURL = configURL
        self.codec = codec
        self.effectiveUID = effectiveUID
    }

    public func bootstrap(legacySnapshot: LegacySettingsSnapshot? = nil) throws(ConfigFileStoreError) -> ConfigLoadResult {
        if FileManager.default.fileExists(atPath: configURL.path) {
            let existingResult = load()
            if existingResult.source != .createdDefault {
                return existingResult
            }
        }

        // No file, or file present but effectively empty — treat both as
        // "first run" and re-seed defaults. An accidentally-truncated
        // config.toml in nvim is functionally equivalent to never having
        // had one, and that's the less-scary user model.
        let config = legacySnapshot?.migratedConfig() ?? .defaultValue
        try save(config)

        if legacySnapshot != nil {
            // Mark the legacy domain so a future deletion of config.toml
            // doesn't trigger a second migration from stale state.
            LegacySettingsSnapshot.markMigratedToTOMLv2()
        }

        return ConfigLoadResult(
            config: config,
            source: legacySnapshot == nil ? .createdDefault : .migratedLegacy,
            configURL: configURL
        )
    }

    public func load() -> ConfigLoadResult {
        do {
            let contents = try SecureFileReader.read(
                at: configURL,
                maximumBytes: TOMLConfigCodec.maxInputSize,
                effectiveUID: effectiveUID
            )
            let data = contents.data

            // Empty / whitespace-only file → treat as a missing file at
            // load time. Watcher reloads will pick up the in-memory
            // default; the next setting change writes the file back to
            // a real default-shaped TOML.
            if data.isEmpty || isEffectivelyEmpty(data) {
                return ConfigLoadResult(
                    config: .defaultValue,
                    source: .createdDefault,
                    configURL: configURL
                )
            }

            let config = try codec.decode(data)

            return ConfigLoadResult(
                config: config,
                source: .existingFile,
                configURL: configURL
            )
        } catch let error as ConfigLoadError {
            return ConfigLoadResult(
                config: nil,
                source: .invalidExistingFile,
                error: error,
                configURL: configURL
            )
        } catch SecureFileReadError.tooLarge {
            return ConfigLoadResult(
                config: nil,
                source: .invalidExistingFile,
                error: TOMLConfigCodec.inputTooLargeError,
                configURL: configURL
            )
        } catch SecureFileReadError.notRegularFile {
            return ConfigLoadResult(
                config: nil,
                source: .unreadableExistingFile,
                error: .notAFile(configURL),
                configURL: configURL
            )
        } catch {
            return ConfigLoadResult(
                config: nil,
                source: .unreadableExistingFile,
                error: .unreadable(configURL),
                configURL: configURL
            )
        }
    }

    private func isEffectivelyEmpty(_ data: Data) -> Bool {
        data.allSatisfy { byte in
            // ASCII whitespace; the TOML grammar's "blank file" is the
            // same shape.
            byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C
                || byte == 0x0D || byte == 0x20
        }
    }

    public func save(_ config: AwesoMuxConfig) throws(ConfigFileStoreError) {
        let data: Data
        do {
            data = try codec.encode(config)
        } catch {
            throw .invalidConfig(error)
        }

        // If configURL is a symlink (dotfiles-managed configs are common),
        // write through to its target so the user's stow/chezmoi setup
        // isn't silently broken when replaceItemAt would otherwise replace
        // the symlink itself with a regular file.
        let effectiveURL = resolvedConfigURL()
        let directoryURL = effectiveURL.deletingLastPathComponent()
        try createParentDirectoryIfNeeded(directoryURL)

        let tempURL = directoryURL.appendingPathComponent(".config.toml.\(UUID().uuidString).tmp")
        var shouldRemoveTempFile = true
        defer {
            if shouldRemoveTempFile, FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        do {
            // Create the temp file locked to owner-only *before* any bytes
            // land. `Data.write` would create it with the process umask first
            // (typically 022 → 0o644, world-readable) and only fix perms
            // afterward, leaving a brief window where another local user could
            // open the config — which grows into tool-trust state.
            //   - O_CREAT|O_EXCL preserves the exclusive-create guarantee the
            //     old `.withoutOverwriting` option provided, and refuses to
            //     follow a symlink planted at the temp path.
            //   - O_CLOEXEC keeps the fd from leaking into the shell/agent child
            //     processes Ghostty surfaces spawn (matching the agent-event
            //     writer); a fork mid-save must not inherit a write fd here.
            let descriptor = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                // Capture errno into a local immediately — it's thread-local and
                // any future call inserted before the read would clobber it.
                let savedErrno = errno
                throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
            }
            // `open`'s mode is masked by umask (0o600 & ~umask), which can only
            // clear bits — never world-readable, but a restrictive umask could
            // leave the file at 0o400/000. fchmod pins it to exactly 0o600,
            // restoring the exact-mode guarantee the old write-then-chmod had,
            // still before any bytes are written.
            if fchmod(descriptor, 0o600) != 0 {
                let savedErrno = errno
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if FileManager.default.fileExists(atPath: effectiveURL.path) {
                try preservePermissionsIfNeeded(on: tempURL, from: effectiveURL)
                _ = try FileManager.default.replaceItemAt(
                    effectiveURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
                // `replaceItemAt` restores the *original* file's mode onto the
                // swapped-in result, which would re-widen a 0o644 config past
                // owner-only — clamping the temp above isn't enough. Clamp the
                // final file too so the owner bits are preserved but group/other
                // access never survives a save. INT-539.
                try clampToOwnerOnly(at: effectiveURL)
            } else {
                // Temp file was already created 0o600 above, so there's no
                // umask window left to close — just move it into place.
                try FileManager.default.moveItem(at: tempURL, to: effectiveURL)
            }

            shouldRemoveTempFile = false
        } catch {
            throw .cannotWrite(effectiveURL, message: String(describing: error))
        }
    }

    /// Resolves `configURL` through one level of symlink if present so save
    /// writes land at the symlink target. Returns the original URL when
    /// the path is not a symlink, doesn't exist, or the destination can't
    /// be read.
    private func resolvedConfigURL() -> URL {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: configURL.path
        ) else {
            return configURL
        }

        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }

        return configURL
            .deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
    }

    private func createParentDirectoryIfNeeded(_ directoryURL: URL) throws(ConfigFileStoreError) {
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }

        do {
            // Owner-only: the config holds agent-permission posture and
            // (eventually) tool-trust state.
            try FileManager.default.createOwnerOnlyDirectory(at: directoryURL)
        } catch {
            throw .cannotCreateDirectory(directoryURL, message: String(describing: error))
        }
    }

    private func preservePermissionsIfNeeded(on tempURL: URL, from existingURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: existingURL.path)
        guard let rawPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else {
            return
        }

        // Preserve the existing file's owner bits so dotfiles tooling
        // (stow/chezmoi) and deliberate chmods survive a save — but clamp off
        // every group/other bit. The config holds agent-permission posture and
        // (eventually) tool-trust state, so it must never end up wider than
        // owner-only, even if a prior tool left it world-readable (e.g. a 0o644
        // restore). The first-write path already lands at 0o600; this keeps the
        // replace path from re-widening it. INT-539.
        let clampedPermissions = rawPermissions & ~UInt16(0o077)

        try FileManager.default.setAttributes(
            [.posixPermissions: clampedPermissions],
            ofItemAtPath: tempURL.path
        )
    }

    /// Clears every group/other permission bit on `url`, leaving the owner bits
    /// untouched. The config must never end up wider than owner-only (INT-539);
    /// the replace path needs this because `replaceItemAt` restores the original
    /// file's mode onto the swapped-in result, overriding the clamped temp.
    private func clampToOwnerOnly(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let rawPermissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else {
            return
        }

        let clamped = rawPermissions & ~UInt16(0o077)
        guard clamped != rawPermissions else { return }

        try FileManager.default.setAttributes(
            [.posixPermissions: clamped],
            ofItemAtPath: url.path
        )
    }
}
