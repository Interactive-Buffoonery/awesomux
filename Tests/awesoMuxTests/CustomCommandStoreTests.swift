import Foundation
import Testing
@testable import awesoMux

@Suite("CustomCommandStore")
@MainActor
struct CustomCommandStoreTests {

    // MARK: - CRUD

    @Test("add appends a validated command with sanitized name and trimmed command")
    func addAppendsValidatedCommand() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let added = try #require(store.add(name: "  Run Tests  ", command: "  swift test \n"))
        #expect(added.name == "Run Tests")
        #expect(added.command == "swift test")
        #expect(store.commands == [added])
    }

    @Test("update preserves the UUID and list position")
    func updatePreservesUUIDAndOrder() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(store.add(name: "First", command: "echo 1"))
        let second = try #require(store.add(name: "Second", command: "echo 2"))
        let third = try #require(store.add(name: "Third", command: "echo 3"))

        #expect(store.update(id: second.id, name: "Renamed", command: "make build"))

        #expect(store.commands.map(\.id) == [first.id, second.id, third.id])
        let updated = try #require(store.command(id: second.id))
        #expect(updated.name == "Renamed")
        #expect(updated.command == "make build")
    }

    @Test("update of an unknown id fails without side effects")
    func updateUnknownIDFails() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = try #require(store.add(name: "Keep", command: "ls"))
        #expect(!store.update(id: UUID(), name: "Ghost", command: "pwd"))
        #expect(store.commands == [existing])
    }

    @Test("remove deletes only the targeted command")
    func removeDeletesTargetedCommand() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(store.add(name: "First", command: "echo 1"))
        let second = try #require(store.add(name: "Second", command: "echo 2"))

        store.remove(id: first.id)
        #expect(store.commands == [second])

        // Unknown id is a no-op.
        store.remove(id: UUID())
        #expect(store.commands == [second])
    }

    @Test("duplicate names are allowed — ids distinguish entries")
    func duplicateNamesAllowed() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(store.add(name: "Deploy", command: "make deploy"))
        let second = try #require(store.add(name: "Deploy", command: "make deploy-staging"))
        #expect(first.id != second.id)
        #expect(store.commands.count == 2)
    }

    // MARK: - Persistence

    @Test("commands round-trip through UserDefaults in stable order")
    func persistenceRoundTrip() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try #require(store.add(name: "First", command: "echo 1"))
        let second = try #require(store.add(name: "Second", command: "./script.sh"))
        let third = try #require(store.add(name: "Third", command: "FOO=1 make"))

        let reloaded = CustomCommandStore(defaults: defaults)
        #expect(reloaded.commands == [first, second, third])
    }

    @Test("corrupt JSON payload decodes to an empty list, not a crash")
    func corruptPayloadFallsBackToEmpty() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data("not json {]".utf8), forKey: CustomCommandStore.defaultsKey)
        #expect(CustomCommandStore(defaults: defaults).commands.isEmpty)

        // Valid JSON of the wrong shape is equally corrupt.
        defaults.set(Data(#"{"id": 7}"#.utf8), forKey: CustomCommandStore.defaultsKey)
        #expect(CustomCommandStore(defaults: defaults).commands.isEmpty)
    }

    @Test("missing payload yields an empty list")
    func missingPayloadYieldsEmpty() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(store.commands.isEmpty)
    }

    // MARK: - Load-time re-validation (tampered payloads)

    @Test("tampered entries are dropped on load; valid entries keep their ids")
    func loadRevalidatesTamperedEntries() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let valid = CustomCommand(id: UUID(), name: "Keep", command: "echo ok")
        let newline = CustomCommand(id: UUID(), name: "Multi", command: "echo a\necho b")
        let invisibleName = CustomCommand(id: UUID(), name: "\u{200B}\u{FEFF}", command: "ls")
        let control = CustomCommand(id: UUID(), name: "Esc", command: "printf '\u{001B}[2J'")
        let joiner = CustomCommand(id: UUID(), name: "ZWJ", command: "echo a\u{200D}b")
        try defaults.set(
            JSONEncoder().encode([newline, valid, invisibleName, control, joiner]),
            forKey: CustomCommandStore.defaultsKey
        )

        let loaded = CustomCommandStore(defaults: defaults).commands
        #expect(loaded == [valid])
        #expect(loaded.first?.id == valid.id)
    }

    @Test("duplicate ids in a tampered payload keep the first occurrence")
    func loadDedupesDuplicateIDs() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedID = UUID()
        let first = CustomCommand(id: sharedID, name: "First", command: "echo 1")
        let impostor = CustomCommand(id: sharedID, name: "Impostor", command: "echo 2")
        let other = CustomCommand(id: UUID(), name: "Other", command: "echo 3")
        try defaults.set(
            JSONEncoder().encode([first, impostor, other]),
            forKey: CustomCommandStore.defaultsKey
        )

        #expect(CustomCommandStore(defaults: defaults).commands == [first, other])
    }

    @Test("an invalid entry does not claim its id — a later valid duplicate loads")
    func loadInvalidEntryDoesNotPoisonDuplicateID() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedID = UUID()
        let invalid = CustomCommand(id: sharedID, name: "Broken", command: "echo a\necho b")
        let valid = CustomCommand(id: sharedID, name: "Fixed", command: "echo ok")
        try defaults.set(
            JSONEncoder().encode([invalid, valid]),
            forKey: CustomCommandStore.defaultsKey
        )

        #expect(CustomCommandStore(defaults: defaults).commands == [valid])
    }

    @Test("loaded names are re-sanitized while ids survive")
    func loadResanitizesNames() throws {
        let (_, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tampered = CustomCommand(
            id: UUID(),
            name: "Run\u{202E} Tests\u{0007}",
            command: "  swift test  "
        )
        try defaults.set(
            JSONEncoder().encode([tampered]),
            forKey: CustomCommandStore.defaultsKey
        )

        let loaded = try #require(CustomCommandStore(defaults: defaults).commands.first)
        #expect(loaded.id == tampered.id)
        #expect(loaded.name == "Run Tests")
        #expect(loaded.command == "swift test")
    }

    // MARK: - Name hygiene (workspace-title policy)

    @Test("invisible, bidi, and control scalars are stripped from names")
    func nameHygieneStripsHostileScalars() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Zero-width space, bidi override, BEL control character.
        let added = try #require(store.add(
            name: "Run\u{200B} \u{202E}Tests\u{0007}",
            command: "swift test"
        ))
        #expect(added.name == "Run Tests")
    }

    @Test("names that sanitize to empty are rejected", arguments: [
        "",
        "   ",
        "\u{200B}\u{FEFF}",
        "\u{202E}\u{202D}",
        "\u{0007}\u{001B}"
    ])
    func emptyAfterSanitizeNameRejected(rawName: String) throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(store.add(name: rawName, command: "ls") == nil)
        #expect(store.commands.isEmpty)

        let existing = try #require(store.add(name: "Valid", command: "ls"))
        #expect(!store.update(id: existing.id, name: rawName, command: "ls"))
        #expect(store.command(id: existing.id)?.name == "Valid")
    }

    // MARK: - Command validation

    @Test("commands with embedded newlines are rejected, not stripped")
    func embeddedNewlineCommandRejected() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(store.add(name: "Multi", command: "echo a\necho b") == nil)
        #expect(store.add(name: "Multi", command: "echo a\r\necho b") == nil)
        #expect(store.commands.isEmpty)

        let existing = try #require(store.add(name: "Single", command: "echo a"))
        #expect(!store.update(id: existing.id, name: "Single", command: "echo a\necho b"))
        #expect(store.command(id: existing.id)?.command == "echo a")
    }

    @Test("leading/trailing whitespace and newlines trim away; empty command rejected")
    func commandTrimming() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let added = try #require(store.add(name: "List", command: "\n  ls -la  \n"))
        #expect(added.command == "ls -la")

        #expect(store.add(name: "Empty", command: "   \n ") == nil)
    }

    @Test("commands with hostile scalars are rejected, not stripped", arguments: [
        "echo a\u{0008}b",      // backspace
        "printf \u{001B}[2J",   // ESC
        "echo \u{202E}gpj.exe", // bidi override
        // Title hygiene keeps these five (joiners + directional hints);
        // commands must not — invisible and shell-significant.
        "echo a\u{200C}b",      // ZWNJ
        "echo a\u{200D}b",      // ZWJ
        "echo a\u{200E}b",      // LRM
        "echo a\u{200F}b",      // RLM
        "echo a\u{061C}b",      // ALM
        // Known ceiling (documented on isCommandDisallowedScalar): emoji
        // built from variation selectors or ZWJ sequences are rejected too.
        "echo \u{2665}\u{FE0F}",        // ♥️ — VS16 variation selector
        "echo 👩\u{200D}💻"             // 👩‍💻 — ZWJ emoji sequence
    ])
    func hostileScalarCommandRejected(rawCommand: String) throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(store.add(name: "Hostile", command: rawCommand) == nil)
        #expect(store.commands.isEmpty)

        let existing = try #require(store.add(name: "Valid", command: "ls"))
        #expect(!store.update(id: existing.id, name: "Valid", command: rawCommand))
        #expect(store.command(id: existing.id)?.command == "ls")
    }

    @Test("tab stays allowed in commands")
    func tabAllowedInCommands() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let added = try #require(store.add(name: "Tabbed", command: "awk '{print $1\t$2}'"))
        #expect(added.command.contains("\t"))
    }

    @Test("visible non-ASCII text stays allowed in commands", arguments: [
        "echo 你好世界",           // CJK
        "echo 🚀",                 // single-scalar emoji
        "echo cafe\u{0301}"        // combining acute accent
    ])
    func visibleUnicodeCommandAllowed(rawCommand: String) throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let added = try #require(store.add(name: "Unicode", command: rawCommand))
        #expect(added.command == rawCommand)
    }

    @Test("command length cap is 4096 UTF-8 bytes, boundary inclusive")
    func commandLengthCapBoundary() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefix = "echo "
        let atCap = prefix + String(repeating: "a", count: 4096 - prefix.utf8.count)
        #expect(atCap.utf8.count == 4096)
        #expect(store.add(name: "At Cap", command: atCap) != nil)

        let overCap = atCap + "a"
        #expect(store.add(name: "Over Cap", command: overCap) == nil)

        // Multi-byte scalars count in bytes, not characters.
        let emoji = String(repeating: "🚀", count: 1025) // 4100 bytes
        #expect(store.add(name: "Emoji", command: emoji) == nil)
    }

    // MARK: - Palette factory

    @Test("factory maps a custom command onto a palette entry")
    func factoryMapsPaletteEntry() throws {
        let customCommand = CustomCommand(id: UUID(), name: "Run Tests", command: "swift test")

        var didRun = false
        let paletteCommand = PaletteCommand.customCommand(customCommand) {
            didRun = true
        }

        #expect(paletteCommand.id == "customCommand.\(customCommand.id.uuidString)")
        #expect(paletteCommand.title == "Run Tests")
        #expect(paletteCommand.subtitle == "swift test")
        #expect(paletteCommand.keywords.contains("custom"))
        #expect(paletteCommand.keywords.contains("swift test"))
        #expect(paletteCommand.shortcut == nil)
        #expect(paletteCommand.isEnabled)

        paletteCommand.run()
        #expect(didRun)
    }

    @Test("factory ids are unique per command and resolvable via the registry helper")
    func factoryIDsResolveInRegistry() throws {
        let first = CustomCommand(id: UUID(), name: "One", command: "echo 1")
        let second = CustomCommand(id: UUID(), name: "Two", command: "echo 2")
        let commands = [
            PaletteCommand.customCommand(first) {},
            PaletteCommand.customCommand(second) {}
        ]

        let resolved = PaletteCommandRegistry.command(
            id: "customCommand.\(second.id.uuidString)",
            in: commands
        )
        #expect(resolved?.title == "Two")
        #expect(commands[0].id != commands[1].id)
    }
}

@MainActor
private func makeStore() throws -> (
    store: CustomCommandStore,
    defaults: UserDefaults,
    suiteName: String
) {
    let suiteName = "CustomCommandStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (CustomCommandStore(defaults: defaults), defaults, suiteName)
}
