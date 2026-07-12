import AwesoMuxCore
import Foundation
import UnicodeHygiene

/// A user-defined command-palette shortcut: a display name plus the shell
/// command sent to a fresh workspace tab when the palette entry runs.
///
/// Codable-evolution contract: this array persists in `UserDefaults`, and a
/// throwing decode wipes every stored command on the next persist. New fields
/// must be optional or `decodeIfPresent`-defaulted — never a new required
/// stored property.
struct CustomCommand: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var command: String
}

/// Owns the persisted list of custom commands. One shared instance is
/// created by the app and injected via `.environment()` so Settings and the
/// command palette observe the same data.
///
/// Persistence is a JSON-encoded array in `UserDefaults`
/// (`SidebarWidthPreferenceStore` sidecar precedent). A corrupt or missing
/// payload decodes to an empty list — never a crash.
@Observable
@MainActor
final class CustomCommandStore {
    static let defaultsKey = "awesomux.customCommands"

    private(set) var commands: [CustomCommand]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.commands = Self.load(from: defaults)
    }

    // MARK: - Validation

    /// Names render in Settings rows, palette entries, accessibility text,
    /// and pinned tab titles — the same surfaces as workspace titles, so they
    /// ride the same display-string hygiene (INT-92/93/434 policy).
    nonisolated static func sanitizedName(_ raw: String) -> String {
        SessionStore.sanitizedTitle(raw)
    }

    /// Commands are trimmed only. Any hygiene beyond trimming could change
    /// shell meaning, so embedded newlines are *rejected* by `isValid` (and
    /// surfaced by the editor) rather than silently stripped — stripping
    /// could join two lines into one token.
    nonisolated static func trimmedCommand(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func commandHasEmbeddedNewline(_ raw: String) -> Bool {
        trimmedCommand(raw).contains(where: \.isNewline)
    }

    /// Commands run verbatim in the shell, so hostile scalars (controls, ESC,
    /// bidi overrides, zero-width) are *rejected*, mirroring the newline
    /// posture — stripping could change shell meaning. Tab is the one control
    /// scalar with a legitimate place in a command line, so it stays allowed.
    nonisolated static func commandHasDisallowedScalar(_ raw: String) -> Bool {
        trimmedCommand(raw).unicodeScalars.contains(where: isCommandDisallowedScalar)
    }

    /// Title hygiene deliberately keeps ZWNJ/ZWJ joiners and LRM/RLM/ALM
    /// directional hints because rendered names need them; a shell command
    /// does not — there they are invisible and shell-significant. So commands
    /// reject everything titles disallow PLUS every default-ignorable
    /// (invisible-format) scalar, closing that title-only exemption.
    ///
    /// Known ceiling: this also rejects emoji built from ZWJ sequences or
    /// variation selectors (👩‍💻, ♥️) in command text, while plain CJK,
    /// single-scalar emoji, and combining marks pass. Deliberate — a blanket
    /// rejection has no bypass surface; add context-aware VS16/ZWJ allowances
    /// only if real command text actually hits this.
    private nonisolated static func isCommandDisallowedScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        guard scalar.value != 0x09 else {
            return false
        }
        return UnicodeHygiene.isDisallowedScalar(scalar)
            || scalar.properties.isDefaultIgnorableCodePoint
    }

    /// UTF-8 byte cap on a stored command — same bounded-work posture as
    /// `UnicodeHygiene.rawScalarCap` for titles.
    nonisolated static let maxCommandUTF8Bytes = 4096

    nonisolated static func commandExceedsLengthCap(_ raw: String) -> Bool {
        trimmedCommand(raw).utf8.count > maxCommandUTF8Bytes
    }

    // MARK: - CRUD

    func command(id: UUID) -> CustomCommand? {
        commands.first { $0.id == id }
    }

    /// Appends a validated command. Returns `nil` (and stores nothing) when
    /// the name sanitizes to empty or the command is empty/multi-line.
    @discardableResult
    func add(name: String, command: String) -> CustomCommand? {
        guard let validated = Self.validated(name: name, command: command) else {
            return nil
        }
        let newCommand = CustomCommand(
            id: UUID(),
            name: validated.name,
            command: validated.command
        )
        commands.append(newCommand)
        persist()
        return newCommand
    }

    /// In-place update that preserves the UUID and list position — the
    /// palette's run closures re-resolve by id at run time, so identity must
    /// survive edits.
    @discardableResult
    func update(id: UUID, name: String, command: String) -> Bool {
        guard let index = commands.firstIndex(where: { $0.id == id }),
              let validated = Self.validated(name: name, command: command) else {
            return false
        }
        commands[index].name = validated.name
        commands[index].command = validated.command
        persist()
        return true
    }

    func remove(id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else {
            return
        }
        commands.remove(at: index)
        persist()
    }

    // MARK: - Persistence

    private static func validated(
        name: String,
        command: String
    ) -> (name: String, command: String)? {
        let name = sanitizedName(name)
        let command = trimmedCommand(command)
        guard !name.isEmpty,
              !command.isEmpty,
              !command.contains(where: \.isNewline),
              !commandHasDisallowedScalar(command),
              !commandExceedsLengthCap(command) else {
            return nil
        }
        return (name, command)
    }

    private static func load(from defaults: UserDefaults) -> [CustomCommand] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CustomCommand].self, from: data) else {
            return []
        }
        // The payload is plaintext-editable (`defaults write`), so entries are
        // re-validated on the way in — the per-entry version of the
        // corrupt-payload → empty posture. Failures drop, ids are preserved,
        // and a duplicated id keeps its first *valid* occurrence (the palette
        // resolves runs by id). Validation runs before the id claim so an
        // invalid entry can't poison its id and drop a later valid duplicate.
        var seenIDs = Set<UUID>()
        return decoded.compactMap { entry in
            guard let validated = validated(name: entry.name, command: entry.command),
                  seenIDs.insert(entry.id).inserted else {
                return nil
            }
            return CustomCommand(id: entry.id, name: validated.name, command: validated.command)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(commands) else {
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
