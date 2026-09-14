import Foundation
import Testing

/// Guard for the app-wide settings VoiceOver pass: a bare control in a
/// settings pane must get its name from somewhere, or VoiceOver announces
/// it as a nameless "switch"/"text field" (WCAG 4.1.2).
///
/// No SwiftUI accessibility-introspection dependency exists in this repo, so
/// this is a source scan: every `.labelsHidden()` or `TextField(`
/// call site under Views/Settings must either sit inside
/// a `SettingsField` that forwards accessibility, or carry an explicit
/// `.accessibilityLabel` nearby. The before-scan stops at the nearest
/// enclosing `SettingsField(` so one row's forwarding can't vouch for its
/// neighbor. Comment lines never count as evidence. Window sizes are
/// generous heuristics — if this fires falsely on a new layout, widen the
/// window rather than deleting the check.
/// Segmented rows instead retain a visible field label, with names and selected
/// state on individual buttons. These source contracts do not replace VoiceOver QA.
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

    /// Non-comment lines from the nearest preceding `SettingsField(` (or a
    /// fixed fallback window when the control isn't in one, e.g. card views)
    /// through `after` lines past the trigger.
    private static func evidenceWindow(in lines: [String], around index: Int, before: Int = 15, after: Int = 13) -> String {
        var start = max(0, index - before)
        for candidate in stride(from: index, through: max(0, index - 40), by: -1)
            where lines[candidate].contains("SettingsField(") && !isComment(lines[candidate]) {
            start = candidate
            break
        }
        let end = min(lines.count, index + after)
        return lines[start..<end].filter { !isComment($0) }.joined(separator: "\n")
    }

    // This convention check accepts direct field children and literal labels.
    // More elaborate layouts need an explicit guard update and VoiceOver QA.
    private static func segmentedFieldProvidesOrientation(in lines: [String], before index: Int) -> Bool {
        let prefix = lines[..<index].filter { !isComment($0) }
        guard let start = prefix.lastIndex(where: { $0.contains("SettingsField(") }) else { return false }
        let field = prefix[start...].joined(separator: "\n")
        guard let body = field.range(of: #"\)\s*\{\s*$"#, options: .regularExpression) else { return false }
        let arguments = String(field[..<body.lowerBound])
        guard !arguments.contains("{"), !arguments.contains("}") else { return false }
        let hasLabel =
            arguments.range(
                of: #"label:\s*(?:String\(\s*localized:\s*)?"[^"\s][^"]*""#,
                options: .regularExpression
            ) != nil
        let compact = arguments.filter { !$0.isWhitespace }
        let keepsLabel =
            !compact.contains("forwardsAccessibilityToControl:")
            || compact.hasSuffix("forwardsAccessibilityToControl:false")
            || compact.contains("forwardsAccessibilityToControl:false,")
        return hasLabel && keepsLabel
    }

    @Test("Segmented settings rows retain their field orientation")
    func segmentedRowsHaveVisibleFieldLabels() throws {
        for (name, lines) in try Self.settingsSourceFiles() {
            for (index, line) in lines.enumerated()
            where line.contains("SettingsSegmented(") && !Self.isComment(line) {
                #expect(
                    Self.segmentedFieldProvidesOrientation(in: lines, before: index),
                    "\(name):\(index + 1): Put segmented choices directly in a labeled SettingsField without accessibility forwarding."
                )
            }
        }
    }

    @Test("Segment buttons preserve their name, selection and optional hint")
    func segmentButtonsHaveAccessibility() throws {
        let files = try Self.settingsSourceFiles()
        let lines = try #require(files.first { $0.name == "SettingsSegmented.swift" }).lines
        let source = lines.filter { !Self.isComment($0) }.joined(separator: "\n")
        #expect(source.contains(".accessibilityElement(children: .contain)"))
        #expect(source.contains(".accessibilityLabel(option.accessibilityLabel ?? option.label)"))
        #expect(source.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"))
        #expect(source.contains("if let hint = option.accessibilityHint"))
        #expect(source.contains("button.accessibilityHint(hint)"))
    }

    @Test(
        "Segmented rows use their own visible field label",
        arguments: [
            ("SettingsField(label: \"Visibility\") {", true),
            ("SettingsField(label: String(localized: \"Visibility\")) {", true),
            ("SettingsField(label: \"Visibility\", forwardsAccessibilityToControl: false) {", true),
            ("SettingsField(label: \"Visibility\", forwardsAccessibilityToControl: true) {", false),
            ("SettingsField(label: \"\") {", false),
            ("SettingsField(label: \"   \") {", false),
            ("SettingsField(hint: \"No label\") {", false),
            ("SettingsField(label: \"Previous row\") { Text(\"Other\") }", false),
            ("// SettingsField(label: \"Comment\") {", false),
            ("VStack {", false),
        ])
    func segmentedFieldEvidence(prefix: String, expected: Bool) {
        let lines = [prefix, "SettingsSegmented(options: options, selection: $selection)"]
        #expect(Self.segmentedFieldProvidesOrientation(in: lines, before: 1) == expected)
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
