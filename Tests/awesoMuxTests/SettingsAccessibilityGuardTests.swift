import Foundation
import Testing

/// Guard for the app-wide settings VoiceOver pass: a bare control in a
/// settings pane must get its name from somewhere, or VoiceOver announces
/// it as a nameless "switch"/"text field" (WCAG 4.1.2).
///
/// No SwiftUI accessibility-introspection dependency exists in this repo, so
/// this is a source scan. Bare controls with hidden labels must receive an
/// explicit name. `SettingsSegmented` is different: its buttons carry their
/// own names and selected traits, while the enclosing `SettingsField` supplies
/// row-level context. Comment lines never count as evidence. Window sizes are
/// generous heuristics — if this fires falsely on a new layout, widen the
/// window rather than deleting the check.
@Suite("Settings accessibility guard")
struct SettingsAccessibilityGuardTests {
    private static func settingsSourceFiles() throws -> [(name: String, lines: [String])] {
        let settingsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // awesoMuxTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/awesoMux/Views/Settings")

        let enumerator = try #require(
            FileManager.default.enumerator(at: settingsDirectory, includingPropertiesForKeys: nil)
        )
        return try enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { file in
                (file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)
                    .components(separatedBy: "\n"))
            }
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    private static func nearestSettingsFieldIndex(in lines: [String], before index: Int) -> Int? {
        stride(from: index, through: max(0, index - 40), by: -1)
            .first { lines[$0].contains("SettingsField(") && !isComment(lines[$0]) }
    }

    /// Non-comment lines from the nearest preceding `SettingsField(` (or a
    /// fixed fallback window when the control isn't in one, e.g. card views)
    /// through `after` lines past the trigger.
    private static func evidenceWindow(in lines: [String], around index: Int, before: Int = 15, after: Int = 13) -> String {
        let start = nearestSettingsFieldIndex(in: lines, before: index) ?? max(0, index - before)
        let end = min(lines.count, index + after)
        return lines[start..<end].filter { !isComment($0) }.joined(separator: "\n")
    }

    private static func settingsRowWindow(in lines: [String], fieldIndex: Int, from index: Int) -> String {
        let fieldIndent = lines[fieldIndex].prefix(while: \.isWhitespace).count
        let end =
            lines.indices.dropFirst(index + 1).first {
                lines[$0].trimmingCharacters(in: .whitespaces) == "}"
                    && lines[$0].prefix(while: \.isWhitespace).count == fieldIndent
            } ?? lines.count
        return lines[index..<end].filter { !isComment($0) }.joined(separator: "\n")
    }

    @Test("Bare settings controls have a VoiceOver name")
    func bareSettingsControlsHaveVoiceOverNames() throws {
        let triggers = [".labelsHidden()", "TextField("]
        var violations: [String] = []

        for (name, lines) in try Self.settingsSourceFiles() {
            for (index, line) in lines.enumerated() {
                guard triggers.contains(where: line.contains), !Self.isComment(line) else { continue }
                let window = Self.evidenceWindow(in: lines, around: index)
                let hasName = window.contains("forwardsAccessibilityToControl: true")
                    || window.contains(".accessibilityLabel")
                if !hasName {
                    violations.append("\(name):\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            Settings controls with no VoiceOver name. Give the enclosing \
            SettingsField `forwardsAccessibilityToControl: true`, or put an \
            explicit `.accessibilityLabel` on the control:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Segmented controls use labeled field context")
    func segmentedControlsUseLabeledFieldContext() throws {
        var violations: [String] = []

        for (name, lines) in try Self.settingsSourceFiles() {
            for (index, line) in lines.enumerated() {
                guard line.contains("SettingsSegmented("), !Self.isComment(line) else { continue }
                guard let fieldIndex = Self.nearestSettingsFieldIndex(in: lines, before: index) else {
                    violations.append("\(name):\(index + 1) — missing enclosing SettingsField")
                    continue
                }

                let fieldHeader = lines[fieldIndex...index]
                    .filter { !Self.isComment($0) }
                    .joined(separator: "\n")
                if !fieldHeader.contains("label:") {
                    violations.append("\(name):\(index + 1) — SettingsField has no label")
                }

                let row = Self.settingsRowWindow(in: lines, fieldIndex: fieldIndex, from: index)
                if row.contains(".accessibilityLabel") || row.contains(".accessibilityHint") {
                    violations.append("\(name):\(index + 1) — redundant container accessibility metadata")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            Segmented controls use their SettingsField label and hint for row \
            context; their child buttons already carry the option names and \
            selected traits. Remove container accessibility metadata or add a \
            labeled SettingsField:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    @Test("Controls that opt out of hint forwarding supply their own hint")
    func hintOptOutsSupplyTheirOwnHint() throws {
        var violations: [String] = []

        for (name, lines) in try Self.settingsSourceFiles() {
            for (index, line) in lines.enumerated() {
                guard line.contains("forwardsHintToControl: false"), !Self.isComment(line) else { continue }
                let end = min(lines.count, index + 20)
                let window = lines[index..<end].filter { !Self.isComment($0) }.joined(separator: "\n")
                if !window.contains(".accessibilityHint") {
                    violations.append("\(name):\(index + 1)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            """
            `forwardsHintToControl: false` means the field's hint is hidden \
            from assistive tech — the control must carry its own \
            `.accessibilityHint`:
            \(violations.joined(separator: "\n"))
            """
        )
    }
}
