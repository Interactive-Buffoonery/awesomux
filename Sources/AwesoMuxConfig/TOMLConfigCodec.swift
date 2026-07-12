import Foundation
import os
import TOML

private let configLogger = Logger(
    subsystem: "com.interactivebuffoonery.awesomux",
    category: "settings.config"
)

public struct TOMLConfigCodec: Sendable {
    static let maxInputSize = 256 * 1024
    static var inputTooLargeError: ConfigLoadError {
        .invalidValue(path: "$", message: "Input exceeds maximum size of \(maxInputSize) bytes")
    }
    private static let ownedTerminalTableKeys: Set<String> = [
        "clipboard_write_policy",
        "confirm_clipboard_read",
        "copy_on_select",
        "command_bridge_enabled",
        "daemon_idle_cap_enabled",
        "daemon_idle_cap_minutes"
    ]
    /// Owned sections whose unknown body lines are preserved via
    /// `extractSectionPreservation`. Unknown sub-tables under these roots
    /// (`[terminal.cursor]`, `[appearance.custom]`) are captured by the
    /// top-level pass so they are not silently dropped either.
    private static let linePreservedSectionRoots: Set<String> = ["terminal", "appearance"]

    /// Sections whose unrecognized keys get a log warning. `@TOMLDefault`
    /// means a typoed key name silently defaults instead of failing decode,
    /// so this diagnostic is the remaining typo-surfacing seam. `[terminal]`
    /// and `[appearance]` are excluded because unknown lines there are
    /// preserved passthrough by design (see `linePreservedSectionRoots`), and
    /// `[agent_integrations]` because its keys live in nested sub-tables this
    /// flat scan does not model.
    private static let diagnosedSectionKeys: [String: Set<String>] = [
        "general": Set(GeneralConfig.CodingKeys.allCases.map(\.rawValue)),
        "notifications": Set(NotificationConfig.CodingKeys.allCases.map(\.rawValue)),
        "agents": Set(AgentConfig.CodingKeys.allCases.map(\.rawValue)),
        "workspaces": Set(WorkspaceConfig.CodingKeys.allCases.map(\.rawValue)),
        "advanced": Set(AdvancedConfig.CodingKeys.allCases.map(\.rawValue))
    ]

    public init() {}

    public func decode(_ data: Data) throws(ConfigLoadError) -> AwesoMuxConfig {
        guard data.count <= Self.maxInputSize else {
            throw Self.inputTooLargeError
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw .invalidValue(path: "$", message: "Input is not valid UTF-8")
        }

        return try decode(string)
    }

    public func decode(_ string: String) throws(ConfigLoadError) -> AwesoMuxConfig {
        guard string.utf8.count <= Self.maxInputSize else {
            throw Self.inputTooLargeError
        }

        do {
            let terminalPreservation = extractSectionPreservation(
                from: string,
                sectionName: "terminal",
                ownedKeys: Self.ownedTerminalTableKeys
            )
            let appearancePreservation = extractSectionPreservation(
                from: string,
                sectionName: "appearance",
                ownedKeys: AppearanceConfig.ownedTOMLKeys
            )
            var config = try configuredDecoder().decode(AwesoMuxConfig.self, from: string)
            try validate(config)
            config.unknownTopLevelTables = extractUnknownTopLevelTables(from: string)
            config.unknownTerminalTableLines = terminalPreservation.unknownLines
            config.terminalTableLineLayout = terminalPreservation.layout
            config.unknownAppearanceTableLines = appearancePreservation.unknownLines
            config.appearanceTableLineLayout = appearancePreservation.layout
            logUnknownOwnedSectionKeys(in: string)
            return config
        } catch let error as ConfigLoadError {
            throw error
        } catch {
            throw normalize(error)
        }
    }

    /// Scans raw TOML for top-level `[table]` blocks whose name is not in
    /// `AwesoMuxConfig.knownTopLevelTableNames` and returns them keyed by
    /// table name with the raw body text. Conservative on purpose:
    /// arrays-of-tables (`[[name]]`) and bracketed-keys inside arrays are
    /// skipped to keep round-trip safety predictable.
    ///
    /// Dotted-key sub-tables of a known root (`[general.foo]`) are likewise
    /// skipped — EXCEPT roots in `linePreservedSectionRoots`: awesoMux owns a
    /// fixed set of keys inside those tables, so a hand-written
    /// `[terminal.cursor]` or `[appearance.custom]` would otherwise be dropped
    /// on the next rewrite. Those sub-tables are captured here (keyed by their
    /// full dotted name) and re-emitted intact.
    ///
    /// This is not a generic owned-section preservation pass. Unknown
    /// key/value lines inside owned sections are preserved separately by
    /// `extractSectionPreservation` for the sections that opt in.
    private func extractUnknownTopLevelTables(from source: String) -> [String: String] {
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
        var captured: [String: [String]] = [:]
        var currentName: String?
        var currentBody: [String] = []
        var scan = TOMLValueScanState()

        func commit() {
            guard let name = currentName, !currentBody.isEmpty || !captured.keys.contains(name) else {
                currentName = nil
                currentBody = []
                return
            }
            captured[name, default: []].append(contentsOf: currentBody)
            currentBody = []
            currentName = nil
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasMidValue = scan.isMidValue
            advanceValueScan(&scan, over: rawLine)

            // A `[name]`-shaped line inside a multi-line string or an open
            // array is value content, not a table header — treating it as one
            // would split the value across two tables and brick the next load.
            if wasMidValue {
                if currentName != nil {
                    currentBody.append(rawLine)
                }
                continue
            }
            if let inner = parseTableHeader(trimmed) {
                commit()
                let root = inner.split(separator: ".", maxSplits: 1).first.map(String.init) ?? inner
                let isUnknownRoot = !AwesoMuxConfig.knownTopLevelTableNames.contains(root)
                // Roots whose bodies are line-preserved are owned; but an
                // unknown sub-table like `[terminal.cursor]` has no owner and
                // would be silently dropped, so capture it here keyed by its
                // full dotted name.
                let isUnknownOwnedSubtable = Self.linePreservedSectionRoots.contains(root) && inner != root
                if isUnknownRoot || isUnknownOwnedSubtable {
                    currentName = inner
                }
            } else if currentName != nil {
                currentBody.append(rawLine)
            }
        }
        commit()

        return captured.mapValues {
            $0.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
    }

    /// Preserve raw body lines in an owned section when their normalized key is
    /// not one of that section's owned keys, so adopting structured keys does
    /// not erase hand-written settings that awesoMux does not understand.
    private func extractSectionPreservation(
        from source: String,
        sectionName: String,
        ownedKeys: Set<String>
    ) -> (unknownLines: String, layout: [SectionLineLayout]) {
        let source = source.replacingOccurrences(of: "\r\n", with: "\n")
        var isInSection = false
        var hasSeenSection = false
        var preserved: [String] = []
        var layout: [SectionLineLayout] = []
        var scan = TOMLValueScanState()
        var preserveMidValueLines = false

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let wasMidValue = scan.isMidValue
            advanceValueScan(&scan, over: rawLine)

            // A `[name]`-shaped line inside a multi-line string or an open
            // array is value content, not a table header — treating it as one
            // would split the value across two tables and drop part of it.
            if wasMidValue {
                if preserveMidValueLines {
                    preserved.append(rawLine)
                    layout.append(.unknownLine(preserved.count - 1))
                }
                continue
            }

            if let inner = parseTableHeader(trimmed) {
                // Latch onto the FIRST matching section only. A spec-compliant TOML
                // parser rejects a duplicate section before we get here, but
                // not merging bodies from a second one keeps this helper honest if
                // the caller ever changes — re-emitting both under one header
                // would manufacture duplicate keys the next load can't read.
                if inner == sectionName, !hasSeenSection {
                    isInSection = true
                    hasSeenSection = true
                } else {
                    isInSection = false
                }
                preserveMidValueLines = false
                continue
            }

            guard isInSection else {
                preserveMidValueLines = false
                continue
            }
            let shouldPreserve = shouldPreserveUnknownSectionLine(trimmed, ownedKeys: ownedKeys)
            if shouldPreserve {
                preserved.append(rawLine)
                layout.append(.unknownLine(preserved.count - 1))
            } else if let key = normalizedSectionLineKey(trimmed) {
                layout.append(.knownKey(key))
            }
            preserveMidValueLines = scan.isMidValue && shouldPreserve
        }

        let unknownLines = preserved
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        return (unknownLines, unknownLines.isEmpty ? [] : layout)
    }

    private func shouldPreserveUnknownSectionLine(_ trimmed: String, ownedKeys: Set<String>) -> Bool {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
            return true
        }
        guard let equalsIndex = trimmed.firstIndex(of: "=") else {
            return true
        }
        let key = normalizedTOMLDottedKey(
            trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return !ownedKeys.contains(key)
    }

    /// Diagnostic only — never changes decode semantics. Best-effort line
    /// scan: a key-shaped line inside a multi-line string value can produce a
    /// spurious warning, which is acceptable for a log message.
    private func logUnknownOwnedSectionKeys(in source: String) {
        var currentSection: String?

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let inner = parseTableHeader(trimmed) {
                currentSection = inner
                continue
            }
            guard let section = currentSection,
                  let ownedKeys = Self.diagnosedSectionKeys[section],
                  !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equalsIndex = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = normalizedTOMLDottedKey(
                trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if !ownedKeys.contains(key) {
                configLogger.warning(
                    "Unrecognized key '\(key, privacy: .public)' in [\(section, privacy: .public)]; possible typo — the owned setting falls back to its default"
                )
            }
        }
    }

    private func normalizedSectionLineKey(_ trimmed: String) -> String? {
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
              let equalsIndex = trimmed.firstIndex(of: "=") else {
            return nil
        }
        return normalizedTOMLDottedKey(
            trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Line-scan value-continuation state: inside a multi-line string (and
    /// which delimiter closes it) or inside an unbalanced array/inline-table
    /// bracket run. While mid-value, subsequent physical lines are value
    /// content — never table headers or new key/value pairs.
    private struct TOMLValueScanState {
        var multilineDelimiter: String?
        var bracketDepth = 0
        var isMidValue: Bool { multilineDelimiter != nil || bracketDepth > 0 }
    }

    /// Advances the value scan across one physical line. This is not a TOML
    /// parser — it only tracks enough structure (strings, escapes, brackets)
    /// to know whether the next line continues a value. Escapes matter: in a
    /// basic multi-line string a `\"` can never begin the closing `"""`, so
    /// a `\"""` line must not be read as a terminator. Literal `'''` strings
    /// have no escapes and are scanned verbatim.
    private func advanceValueScan(_ state: inout TOMLValueScanState, over line: String) {
        let chars = Array(line)
        var index = 0

        func matches(_ delimiter: String) -> Bool {
            let delimiterChars = Array(delimiter)
            guard index + delimiterChars.count <= chars.count else { return false }
            return Array(chars[index ..< index + delimiterChars.count]) == delimiterChars
        }

        while index < chars.count {
            if let delimiter = state.multilineDelimiter {
                if delimiter == "\"\"\"", chars[index] == "\\" {
                    index += 2
                    continue
                }
                if matches(delimiter) {
                    state.multilineDelimiter = nil
                    index += delimiter.count
                    continue
                }
                index += 1
                continue
            }

            switch chars[index] {
            case "#":
                return
            case "\"":
                if matches("\"\"\"") {
                    state.multilineDelimiter = "\"\"\""
                    index += 3
                    continue
                }
                index += 1
                while index < chars.count {
                    if chars[index] == "\\" {
                        index += 2
                        continue
                    }
                    if chars[index] == "\"" {
                        index += 1
                        break
                    }
                    index += 1
                }
            case "'":
                if matches("'''") {
                    state.multilineDelimiter = "'''"
                    index += 3
                    continue
                }
                index += 1
                while index < chars.count, chars[index] != "'" {
                    index += 1
                }
                if index < chars.count {
                    index += 1
                }
            case "[", "{":
                state.bracketDepth += 1
                index += 1
            case "]", "}":
                state.bracketDepth = max(0, state.bracketDepth - 1)
                index += 1
            default:
                index += 1
            }
        }
    }

    /// Collapses all three TOML key/header forms — bare (`copy_on_select`),
    /// basic-string (`"copy_on_select"`, with escapes), and literal-string
    /// (`'copy_on_select'`) — to the single logical key the parser resolves
    /// them to. A quoted spelling of an owned key must not be preserved
    /// as an extra unknown line, or the next write can produce duplicate
    /// keys that fail to load.
    private func normalizedTOMLKey(_ text: String) -> String {
        guard text.count >= 2 else { return text }

        if text.first == "'", text.last == "'" {
            // Literal strings are verbatim by definition — no escape processing.
            return String(text.dropFirst().dropLast())
        }

        if text.first == "\"", text.last == "\"" {
            return unescapeTOMLBasicString(String(text.dropFirst().dropLast()))
        }

        return text
    }

    private func normalizedTOMLDottedKey(_ text: some StringProtocol) -> String {
        splitTOMLDottedKeySegments(String(text))
            .map { normalizedTOMLKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .joined(separator: ".")
    }

    private func splitTOMLDottedKeySegments(_ text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var isInBasicString = false
        var isInLiteralString = false
        var isEscapingBasicString = false

        for character in text {
            if isEscapingBasicString {
                current.append(character)
                isEscapingBasicString = false
                continue
            }

            if isInBasicString, character == "\\" {
                current.append(character)
                isEscapingBasicString = true
                continue
            }

            if character == "\"", !isInLiteralString {
                isInBasicString.toggle()
                current.append(character)
                continue
            }

            if character == "'", !isInBasicString {
                isInLiteralString.toggle()
                current.append(character)
                continue
            }

            if character == ".", !isInBasicString, !isInLiteralString {
                segments.append(current)
                current = ""
                continue
            }

            current.append(character)
        }

        segments.append(current)
        return segments
    }

    /// Unescapes the TOML basic-string escape set so a key like
    /// `"copy_on_select"` normalizes to `copy_on_select`. Malformed or
    /// unrecognized escapes are preserved literally rather than guessed at, so
    /// we never *mis*-fold an unknown key onto an owned one.
    private func unescapeTOMLBasicString(_ inner: String) -> String {
        guard inner.contains("\\") else { return inner }

        let chars = Array(inner)
        var result = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            guard char == "\\" else {
                result.append(char)
                index += 1
                continue
            }

            index += 1
            guard index < chars.count else {
                result.append("\\")
                break
            }
            let escape = chars[index]
            index += 1
            switch escape {
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "u", "U":
                let width = escape == "u" ? 4 : 8
                guard index + width <= chars.count,
                      let scalarValue = UInt32(String(chars[index ..< index + width]), radix: 16),
                      let unicode = Unicode.Scalar(scalarValue) else {
                    result.append("\\")
                    result.append(escape)
                    continue
                }
                result.append(Character(unicode))
                index += width
            default:
                result.append("\\")
                result.append(escape)
            }
        }
        return result
    }

    /// Parses a stripped line as a standard (`[name]`) table header,
    /// tolerating a trailing `# comment`. Returns the inner name or
    /// `nil` for anything else (including the `[[name]]` array-of-tables
    /// shape, which we deliberately skip).
    private func parseTableHeader(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") else {
            return nil
        }
        // Everything after `]` is allowed to be a TOML comment.
        guard let closeIndex = trimmed.firstIndex(of: "]") else { return nil }
        let afterClose = trimmed[trimmed.index(after: closeIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !afterClose.isEmpty && !afterClose.hasPrefix("#") {
            return nil
        }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<closeIndex]
        // Normalize quoted headers (`["terminal"]`, `['terminal']`) to the same
        // logical name as the bare form, so an owned table written quoted is
        // recognized as owned instead of preserved as a duplicate `[terminal]`.
        return normalizedTOMLDottedKey(String(inner))
    }

    public func encode(_ config: AwesoMuxConfig) throws(ConfigLoadError) -> Data {
        guard let data = try encodeString(config).data(using: .utf8) else {
            throw .invalidValue(path: "$", message: "Unable to encode config as UTF-8")
        }
        // Symmetric with the decode cap: refuse to write a config bigger
        // than the parser is willing to read back. Today the schema is
        // fixed-size and this is unreachable; once any field grows into a
        // list (recent workspaces, palette overrides), this guard prevents
        // a self-bricking config that the next launch can't load.
        guard data.count <= Self.maxInputSize else {
            throw .invalidValue(
                path: "$",
                message: "Encoded config exceeds maximum size of \(Self.maxInputSize) bytes"
            )
        }
        return data
    }

    public func encodeString(_ config: AwesoMuxConfig) throws(ConfigLoadError) -> String {
        do {
            try validate(config)

            let encoder = TOMLEncoder()
            encoder.keyEncodingStrategy = .useDefaultKeys
            encoder.outputFormatting = [.sortedKeys]
            let structured = try encoder.encodeToString(config)
            let withTerminalExtras = appendSectionExtraLines(
                structured,
                sectionName: "terminal",
                extras: config.unknownTerminalTableLines,
                layout: config.terminalTableLineLayout
            )
            let withAppearanceExtras = appendSectionExtraLines(
                withTerminalExtras,
                sectionName: "appearance",
                extras: config.unknownAppearanceTableLines,
                layout: config.appearanceTableLineLayout
            )
            return appendUnknownTopLevelTables(withAppearanceExtras, extras: config.unknownTopLevelTables)
        } catch let error as ConfigLoadError {
            throw error
        } catch {
            throw normalize(error)
        }
    }

    private func appendUnknownTopLevelTables(_ structured: String, extras: [String: String]) -> String {
        guard !extras.isEmpty else { return structured }

        let trimmed = structured.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedExtras = extras.sorted { $0.key < $1.key }
        let blocks = sortedExtras.map { name, body -> String in
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedBody.isEmpty ? "[\(name)]" : "[\(name)]\n\(trimmedBody)"
        }
        return trimmed + "\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    private func appendSectionExtraLines(
        _ structured: String,
        sectionName: String,
        extras: String,
        layout: [SectionLineLayout]
    ) -> String {
        let trimmedExtras = extras.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedExtras.isEmpty else { return structured }

        var lines = structured
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let sectionHeaderIndex = lines.firstIndex(where: {
            parseTableHeader($0.trimmingCharacters(in: .whitespacesAndNewlines)) == sectionName
        }) else {
            return structured.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n[\(sectionName)]\n\(trimmedExtras)\n"
        }

        var insertIndex = lines.index(after: sectionHeaderIndex)
        while insertIndex < lines.endIndex {
            let trimmed = lines[insertIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if parseTableHeader(trimmed) != nil {
                break
            }
            insertIndex = lines.index(after: insertIndex)
        }

        let extraLines = trimmedExtras
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !layout.isEmpty else {
            lines.insert(contentsOf: extraLines, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        let generatedLines = Array(lines[lines.index(after: sectionHeaderIndex)..<insertIndex])
        let generatedByKey: [String: String] = Dictionary(
            uniqueKeysWithValues: generatedLines.compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let key = normalizedSectionLineKey(trimmed) else { return nil }
                return (key, line)
            }
        )

        var rebuiltBody: [String] = []
        var usedGeneratedKeys: Set<String> = []
        var usedUnknownLineIndexes: Set<Int> = []

        for item in layout {
            switch item {
            case .knownKey(let key):
                guard let line = generatedByKey[key], !usedGeneratedKeys.contains(key) else {
                    continue
                }
                rebuiltBody.append(line)
                usedGeneratedKeys.insert(key)
            case .unknownLine(let index):
                guard extraLines.indices.contains(index), !usedUnknownLineIndexes.contains(index) else {
                    continue
                }
                rebuiltBody.append(extraLines[index])
                usedUnknownLineIndexes.insert(index)
            }
        }

        rebuiltBody.append(contentsOf: generatedLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = normalizedSectionLineKey(trimmed) else { return true }
            return !usedGeneratedKeys.contains(key)
        })
        rebuiltBody.append(contentsOf: extraLines.enumerated().compactMap { index, line in
            usedUnknownLineIndexes.contains(index) ? nil : line
        })

        lines.replaceSubrange(lines.index(after: sectionHeaderIndex)..<insertIndex, with: rebuiltBody)
        return lines.joined(separator: "\n")
    }

    private func configuredDecoder() -> TOMLDecoder {
        let decoder = TOMLDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.limits = TOMLDecoder.DecodingLimits(
            maxInputSize: Self.maxInputSize,
            maxDepth: 16,
            maxTableKeys: 128,
            maxArrayLength: 256,
            maxStringLength: 8 * 1024
        )
        return decoder
    }

    private func validate(_ config: AwesoMuxConfig) throws(ConfigLoadError) {
        try config.appearance.validate()
        try config.workspaces.validate()

        let version = config.advanced.configSchemaVersion
        guard version >= AdvancedConfig.minimumConfigSchemaVersion else {
            throw .invalidValue(
                path: "advanced.config_schema_version",
                message: "Schema version must be at least \(AdvancedConfig.minimumConfigSchemaVersion)"
            )
        }

        guard version <= AdvancedConfig.supportedConfigSchemaVersion else {
            throw .unsupportedSchemaVersion(version)
        }
    }

    private func normalize(_ error: any Error) -> ConfigLoadError {
        if let tomlError = error as? TOMLDecodingError {
            return normalize(tomlError)
        }

        if let decodingError = error as? DecodingError {
            return normalize(decodingError)
        }

        if let encodingError = error as? TOMLEncodingError {
            return .invalidValue(path: "$", message: encodingError.description)
        }

        return .invalidValue(path: "$", message: String(describing: error))
    }

    private func normalize(_ error: TOMLDecodingError) -> ConfigLoadError {
        switch error {
        case .invalidSyntax(let line, let column, let message):
            return .invalidSyntax(line: line, column: column, message: message)
        case .typeMismatch(let expected, let found, let codingPath):
            return .invalidValue(
                path: pathDescription(codingPath),
                message: "Expected \(expected), found \(found)"
            )
        case .keyNotFound(let key, let availableKeys):
            return .invalidValue(
                path: key.stringValue,
                message: "Required key is missing. Available keys: \(availableKeys.joined(separator: ", "))"
            )
        case .valueNotFound(let type, let codingPath):
            return .invalidValue(
                path: pathDescription(codingPath),
                message: "Expected value of type \(type)"
            )
        case .dataCorrupted(let message, let codingPath):
            return .invalidValue(path: pathDescription(codingPath), message: message)
        case .invalidData(let message):
            return .invalidValue(path: "$", message: message)
        }
    }

    private func normalize(_ error: DecodingError) -> ConfigLoadError {
        switch error {
        case .typeMismatch(let type, let context):
            return .invalidValue(
                path: pathDescription(context.codingPath),
                message: "Expected \(type): \(context.debugDescription)"
            )
        case .valueNotFound(let type, let context):
            return .invalidValue(
                path: pathDescription(context.codingPath),
                message: "Expected \(type): \(context.debugDescription)"
            )
        case .keyNotFound(let key, let context):
            return .invalidValue(
                path: pathDescription(context.codingPath + [key]),
                message: context.debugDescription
            )
        case .dataCorrupted(let context):
            return .invalidValue(
                path: pathDescription(context.codingPath),
                message: context.debugDescription
            )
        @unknown default:
            return .invalidValue(path: "$", message: String(describing: error))
        }
    }

    private func pathDescription(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "$"
        }

        return codingPath.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }
        .joined(separator: ".")
    }
}
