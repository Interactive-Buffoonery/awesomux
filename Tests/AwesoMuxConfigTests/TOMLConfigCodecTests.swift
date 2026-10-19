import Foundation
import Testing
import TOML
@testable import AwesoMuxConfig

@Suite("TOMLConfigCodec")
struct TOMLConfigCodecTests {
    private let codec = TOMLConfigCodec()

    private struct ParsedUnknownHeaders: Decodable {
        let external: [String: [String: Bool]]
        let literalExternalTool: [String: Bool]

        enum CodingKeys: String, CodingKey {
            case external
            case literalExternalTool = "external.tool"
        }
    }

    @Test("129 always-managed destinations are rejected before writing", arguments: [false, true])
    func alwaysManagedDestinationsOverTableLimitRejected(remote: Bool) throws {
        let entries = Dictionary(
            uniqueKeysWithValues: (0..<129).map {
                ("user@host\($0).example.com", ManagedSSHAlwaysManagedEntry(sessionName: remote ? "work" : nil))
            })
        let config = AwesoMuxConfig(workspaces: WorkspaceConfig(managedSSHAlwaysManaged: entries))
        let expectedError = ConfigLoadError.invalidValue(
            path: "workspaces.managed_ssh_always_managed",
            message: "Always-managed SSH destinations must contain at most 128 entries"
        )

        #expect(throws: expectedError) { try codec.encode(config) }
        #expect(throws: expectedError) { try codec.encodeString(config) }
    }

    private struct RoundTripCase: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let verify: @Sendable (AwesoMuxConfig, String, AwesoMuxConfig) throws -> Void
        var testDescription: String { name }
    }

    private static var roundTripCases: [RoundTripCase] {
        let codec = TOMLConfigCodec()
        var cases: [RoundTripCase] = []
        do {
            let toml =
                defaultTOML + """

                    [external_tool]
                    enabled = true
                    note = "kept outside awesoMux schema"
                    """
            cases.append(
                RoundTripCase(name: "unknownTopLevelTableSurvivesLoadAndSave", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(reEncoded.contains("[external_tool]"))
                    #expect(reEncoded.contains("enabled = true"))
                    #expect(reEncoded.contains("kept outside awesoMux schema"))
                    #expect(reDecoded.unknownTopLevelTables["external_tool"]?.contains("enabled = true") == true)
                })
        }
        do {
            let toml =
                defaultTOML + """

                    [external.tool]
                    bare = true

                    ["external.tool"]
                    quoted = true

                    ["external tool"]
                    spaced = true

                    [""]
                    empty = true

                    ["éxternal"]
                    unicode = true

                    [external."tool space"]
                    partial = true

                    ["name]#"]
                    brackets = true

                    ["quote\\\"key"]
                    escaped = true
                    """
            cases.append(
                RoundTripCase(name: "quotedUnknownTableHeadersRemainValidAndDistinct", source: toml) { decoded, reEncoded, reDecoded in
                    let parsed = try TOMLDecoder().decode(ParsedUnknownHeaders.self, from: reEncoded)

                    #expect(decoded.unknownTopLevelTables["external.tool"]?.contains("bare = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""external.tool""#]?.contains("quoted = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""external tool""#]?.contains("spaced = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""""#]?.contains("empty = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""éxternal""#]?.contains("unicode = true") == true)
                    #expect(decoded.unknownTopLevelTables[#"external."tool space""#]?.contains("partial = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""name]#""#]?.contains("brackets = true") == true)
                    #expect(decoded.unknownTopLevelTables[#""quote\"key""#]?.contains("escaped = true") == true)
                    #expect(decoded.unknownTopLevelTables.count == 8)
                    #expect(reEncoded.contains("[external.tool]"))
                    #expect(reEncoded.contains(#"["external.tool"]"#))
                    #expect(reEncoded.contains(#"["external tool"]"#))
                    #expect(reEncoded.contains(#"[""]"#))
                    #expect(reEncoded.contains(#"["éxternal"]"#))
                    #expect(reEncoded.contains(#"[external."tool space"]"#))
                    #expect(reEncoded.contains(#"["name]#"]"#))
                    #expect(reEncoded.contains(#"["quote\"key"]"#))
                    #expect(reDecoded.unknownTopLevelTables.count == 8)
                    #expect(parsed.external["tool"]?["bare"] == true)
                    #expect(parsed.literalExternalTool["quoted"] == true)
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    clipboard_write_policy = "ask"
                    custom_shell_integration = true
                    """
            )
            cases.append(
                RoundTripCase(name: "unknownTerminalKeySurvivesLoadAndSave", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))
                    #expect(reEncoded.contains("custom_shell_integration = true"))
                    #expect(reDecoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))
                })
        }
        do {
            let appearanceExtras = [
                "glow_strength = 0.65",
                "custom_ml = \"\"\"",
                #"\""""#,
                "[not_a_table]",
                "still content",
                "\"\"\"",
            ].joined(separator: "\n")
            let toml = defaultTOML.replacing("glow_strength = 0.65", with: appearanceExtras)
            cases.append(
                RoundTripCase(name: "escapedQuoteInsideMultilineStringDoesNotTerminateIt", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.unknownTopLevelTables["not_a_table"] == nil)
                    #expect(reEncoded.contains("still content"))
                    #expect(reEncoded.contains("[not_a_table]"))
                    #expect(reEncoded.components(separatedBy: "[not_a_table]").count - 1 == 1)
                    #expect(reDecoded.unknownAppearanceTableLines.contains("still content"))
                })
        }
        do {
            let appearanceExtras = [
                "glow_strength = 0.65",
                "custom_prompts = [",
                "\"\"\"",
                "alpha",
                "[not_a_table]",
                "\"\"\",",
                #""beta""#,
                "]",
            ].joined(separator: "\n")
            let toml = defaultTOML.replacing("glow_strength = 0.65", with: appearanceExtras)
            cases.append(
                RoundTripCase(name: "multilineStringInsideArrayDoesNotSplitSection", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.unknownTopLevelTables["not_a_table"] == nil)
                    #expect(reEncoded.contains("custom_prompts = ["))
                    #expect(reEncoded.contains("alpha"))
                    #expect(reEncoded.contains(#""beta""#))
                    #expect(reEncoded.components(separatedBy: "[not_a_table]").count - 1 == 1)
                    #expect(reDecoded.unknownAppearanceTableLines.contains(#""beta""#))
                })
        }
        do {
            let toml =
                defaultTOML
                .replacing(
                    """
                    clipboard_write_policy = "ask"
                    confirm_clipboard_read = true
                    """,
                    with: """
                        clipboard_write_policy = "ask"
                        confirm_clipboard_read = true
                        custom_multiline = \"\"\"
                        first line
                        [appearance]
                        second line
                        \"\"\"
                        """
                )
                .replacing(
                    "glow_strength = 0.65",
                    with: """
                        glow_strength = 0.65
                        custom_note = "preserved appearance extra"
                        """
                )
            cases.append(
                RoundTripCase(name: "headerShapedLineInsideMultilineExtraDoesNotCorruptLaterSectionSplice", source: toml) {
                    decoded, reEncoded, reDecoded in
                    #expect(
                        reEncoded.contains(
                            """
                            custom_multiline = \"\"\"
                            first line
                            [appearance]
                            second line
                            \"\"\"
                            """))
                    #expect(reEncoded.contains(#"custom_note = "preserved appearance extra""#))
                    #expect(reEncoded.components(separatedBy: "[appearance]").count - 1 == 2)
                    #expect(reDecoded.unknownTerminalTableLines.contains("[appearance]"))
                    #expect(reDecoded.unknownAppearanceTableLines.contains(#"custom_note = "preserved appearance extra""#))
                })
        }
        do {
            let toml =
                defaultTOML
                .replacing(
                    "glow_strength = 0.65",
                    with: "glow_strength = 0.65\nfont_ligatures = true"
                )
                .replacing("\n", with: "\r\n")
            cases.append(
                RoundTripCase(name: "crlfInputPreservesUnknownSectionKeys", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.unknownAppearanceTableLines.contains("font_ligatures = true"))
                    #expect(!decoded.unknownAppearanceTableLines.contains("\r"))
                    #expect(reEncoded.contains("font_ligatures = true"))
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    "clipboard_write_policy" = "allow"
                    "copy_on_select" = "on"
                    """
            )
            cases.append(
                RoundTripCase(name: "quotedOwnedTerminalKeysDoNotReEncodeAsUnknownLines", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.terminal.clipboardWritePolicy == .allow)
                    #expect(decoded.terminal.copyOnSelect == .on)
                    #expect(reEncoded.contains(#"clipboard_write_policy = "allow""#))
                    #expect(reEncoded.contains(#"copy_on_select = "on""#))
                    #expect(reEncoded.components(separatedBy: "clipboard_write_policy").count - 1 == 1)
                    #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
                    #expect(!reEncoded.contains(#""clipboard_write_policy" = "allow""#))
                    #expect(!reEncoded.contains(#""copy_on_select" = "on""#))
                    #expect(throws: Never.self) { try codec.decode(reEncoded) }
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    'clipboard_write_policy' = "allow"
                    'copy_on_select' = "on"
                    """
            )
            cases.append(
                RoundTripCase(name: "singleQuotedOwnedTerminalKeysReload", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.terminal.clipboardWritePolicy == .allow)
                    #expect(decoded.terminal.copyOnSelect == .on)
                    #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
                    #expect(reEncoded.components(separatedBy: "clipboard_write_policy").count - 1 == 1)
                    #expect(!reEncoded.contains("'copy_on_select'"))
                    #expect(reDecoded.terminal.copyOnSelect == .on)
                    #expect(reDecoded.terminal.clipboardWritePolicy == .allow)
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    "copy\\u005Fon_select" = "on"
                    clipboard_write_policy = "ask"
                    """
            )
            cases.append(
                RoundTripCase(name: "escapedBasicStringOwnedTerminalKeysReload", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.terminal.copyOnSelect == .on)
                    #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
                    #expect(throws: Never.self) { try codec.decode(reEncoded) }
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    clipboard_write_policy = "ask"
                    "emoji_\\U0001F600_key" = true
                    """
            )
            cases.append(
                RoundTripCase(name: "unicodeEscapedUnknownKeysRoundTrip", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.terminal.clipboardWritePolicy == .ask)
                    #expect(throws: Never.self) { try codec.decode(reEncoded) }
                })
        }
        do {
            let toml = defaultTOML.replacing(
                "[terminal]",
                with: #"["terminal"]"#
            )
            cases.append(
                RoundTripCase(name: "quotedTerminalHeaderReload", source: toml) { decoded, reEncoded, reDecoded in
                    #expect(decoded.terminal.clipboardWritePolicy == .ask)
                    #expect(reEncoded.components(separatedBy: "[terminal]").count - 1 == 1)
                    #expect(!reEncoded.contains(#"["terminal"]"#))
                    #expect(throws: Never.self) { try codec.decode(reEncoded) }
                })
        }
        do {
            let replacement = [
                "",
                "   ",
                "custom_note = \"\"\"",
                "first line",
                "\"\"\"",
                #"copy_on_select = "off""#,
                #"clipboard_write_policy = "ask""#,
                "confirm_clipboard_read = true",
            ].joined(separator: "\n")
            let toml = defaultTOML.replacing(
                """
                clipboard_write_policy = "ask"
                confirm_clipboard_read = true
                """,
                with: replacement
            )

            cases.append(
                RoundTripCase(name: "leading terminal lines", source: toml) { decoded, reEncoded, reDecoded in
                    let thirdEncoded = try codec.encodeString(reDecoded)
                    let thirdDecoded = try codec.decode(thirdEncoded)
                    let fourthEncoded = try codec.encodeString(thirdDecoded)

                    #expect(
                        reEncoded.contains(
                            """
                            custom_note = \"\"\"
                            first line
                            \"\"\"
                            copy_on_select = "off"
                            """))
                    #expect(reDecoded.terminal.copyOnSelect == .off)
                    #expect(thirdEncoded == reEncoded)
                    #expect(fourthEncoded == reEncoded)

                })
        }
        do {
            let appearanceReplacement = [
                "",
                "   ",
                "custom_note = '''",
                "first line",
                "'''",
                "glow_strength = 0.4",
            ].joined(separator: "\n")
            let appearanceTOML = defaultTOML.replacing(
                "glow_strength = 0.65",
                with: appearanceReplacement
            )
            cases.append(
                RoundTripCase(name: "leading appearance lines", source: appearanceTOML) { decoded, reEncoded, reDecoded in

                    #expect(
                        reEncoded.contains(
                            """
                            custom_note = '''
                            first line
                            '''
                            glow_strength = 0.4
                            """))
                    #expect(reDecoded.appearance.glowStrength == 0.4)
                })
        }
        do {
            let headers = [
                (header: #"[workspaces.managed_ssh_always_managed."foo]bar"]"#, key: "foo]bar"),
                (header: #"[workspaces.managed_ssh_always_managed.'foo]bar']"#, key: "foo]bar"),
                (header: #"[workspaces.managed_ssh_always_managed."foo\"]bar"]"#, key: #"foo"]bar"#),
            ]

            for entry in headers {
                cases.append(
                    RoundTripCase(
                        name: entry.header,
                        source: defaultTOML + "\n[external_tool]\nenabled = true\n\n" + entry.header
                            + "\nsession_name = \"remote-session\"\n"
                    ) { decoded, _, _ in
                        #expect(decoded.unknownTopLevelTables["external_tool"] == "enabled = true")
                        #expect(decoded.workspaces.managedSSHAlwaysManaged[entry.key]?.sessionName == "remote-session")
                    })
            }
        }
        return cases
    }

    @Test(arguments: roundTripCases)
    private func unknownContentRoundTrips(entry: RoundTripCase) throws {
        let decoded = try codec.decode(entry.source)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)
        try entry.verify(decoded, reEncoded, reDecoded)
        #expect(try codec.encodeString(reDecoded) == reEncoded)
    }

    private struct InvalidValueCase: Sendable {
        let source: String
        let verify: @Sendable (String, String) -> Void
    }

    private static var invalidValues: [InvalidValueCase] {
        var cases: [InvalidValueCase] = []
        do {
            let toml = defaultTOML.replacing(
                "confirm_clipboard_read = true",
                with: """
                    confirm_clipboard_read = true
                    copy_on_select = "sometimes"
                    """
            )
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("copy_on_select"))
                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"clipboard_write_policy = "ask""#,
                with: #"clipboard_write_policy = "sometimes""#
            )
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("terminal"))
                    #expect(path.contains("clipboard_write_policy"))

                })
        }
        do {
            let toml = defaultTOML.replacing(
                "confirm_close_with_running_agent = false",
                with: #"confirm_close_with_running_agent = "not a bool""#
            )
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("confirm_close_with_running_agent"))

                })
        }
        do {
            let toml = defaultTOML.replacing(
                "terminal_background_color = \"#1e1e2e\"",
                with: "terminal_background_color = \"blue\""
            )
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path == "appearance.terminal_background_color")
                    #expect(message.contains("#RRGGBB"))

                })
        }
        do {
            let toml = defaultTOML.replacing("font_size = 13.0", with: #"font_size = "large""#)
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("appearance"))
                    #expect(path.contains("font_size"))
                    #expect(message.contains("Double") || message.contains("float"))

                })
        }
        do {
            let toml = defaultTOML.replacing("restore_workspaces = true", with: #"restore_workspaces = "yes""#)
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("general"))
                    #expect(path.contains("restore_workspaces"))
                    #expect(message.contains("Bool") || message.contains("boolean"))

                })
        }
        do {
            let toml = defaultTOML.replacing("sound = true", with: #"sound = "loud""#)
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("notifications"))
                    #expect(path.contains("sound"))
                    #expect(message.contains("Bool") || message.contains("boolean"))

                })
        }
        do {
            let toml = defaultTOML.replacing("remember_tool_trust = true", with: #"remember_tool_trust = "yes""#)
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("agents"))
                    #expect(path.contains("remember_tool_trust"))
                    #expect(message.contains("Bool") || message.contains("boolean"))

                })
        }
        do {
            let toml = defaultTOML.replacing(#"theme = "system""#, with: #"theme = "sepia""#)
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("appearance"))
                    #expect(path.contains("theme"))
                    #expect(message.contains("sepia") || message.contains("Theme"))

                })
        }
        do {
            let toml = defaultTOML.replacing(
                #"terminal_background_mode = "ghostty""#,
                with: #"terminal_background_mode = "catppuccin""#
            )
            cases.append(
                InvalidValueCase(source: toml) { path, message in
                    #expect(path.contains("appearance"))
                    #expect(path.contains("terminal_background_mode"))

                })
        }
        cases.append(
            InvalidValueCase(source: "[workspaces]\ndefault_group = 123") { path, _ in
                #expect(path.contains("default_group"))
            })
        cases.append(
            InvalidValueCase(source: "[workspaces]\nconfirm_destructive_pane_action_with_running_agent = \"yes\"") { path, _ in
                #expect(path.contains("confirm_destructive_pane_action_with_running_agent"))
            })
        return cases
    }

    @Test(arguments: invalidValues)
    private func invalidValueReportsUsefulPath(entry: InvalidValueCase) throws {
        do {
            _ = try codec.decode(entry.source)
            Issue.record("expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            entry.verify(path, message)
        } catch {
            Issue.record("expected invalid value, got \(error)")
        }
    }

    @Test("invalid TOML syntax reports line and column")
    func invalidSyntaxReportsLineAndColumn() throws {
        do {
            _ = try codec.decode(
                """
                [appearance]
                theme =
                """)
            Issue.record("Expected invalid syntax, but decode succeeded")
        } catch ConfigLoadError.invalidSyntax(let line, let column, let message) {
            #expect(line > 0)
            #expect(column > 0)
            #expect(!message.isEmpty)
        } catch {
            Issue.record("Expected invalid syntax, got \(error)")
        }
    }

    @Test("workspace default group is normalized when decoding TOML")
    func workspaceDefaultGroupIsNormalizedWhenDecodingTOML() throws {
        let toml = Self.defaultTOML.replacing(
            #"default_group = "awesoMux""#,
            with: #"default_group = "  Field\u0007 Ops\u202E  ""#
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.workspaces.defaultGroup == "Field Ops")
    }

    @Test("oversized input is rejected by decode limits")
    func oversizedInputIsRejectedByDecodeLimits() throws {
        let oversizedData = Data(repeating: UInt8(ascii: "a"), count: 256 * 1024 + 1)

        do {
            _ = try codec.decode(oversizedData)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path == "$")
            #expect(message.contains("maximum size"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
        let oversized = AwesoMuxConfig(unknownTopLevelTables: ["huge": "data = \"" + String(repeating: "x", count: 270_000) + "\""])
        do {
            _ = try codec.encode(oversized)
            Issue.record("expected encoding to reject oversized config")
        } catch ConfigLoadError.invalidValue(_, let message) {
            #expect(message.contains("maximum size"))
        } catch {
            Issue.record("expected invalidValue, got \(error)")
        }
    }

    /// Exercises every raw-line scan in one load — unknown top-level table,
    /// preserved terminal + appearance lines, a multiline value containing a
    /// header-shaped line and an escaped-quote line, all under CRLF endings.
    /// The decode path now splits the source into lines exactly once and
    /// shares that array; feeding any scan un-normalized (CRLF-carrying) or
    /// mis-scanning the multiline delimiters shows up as `\r` leakage, a
    /// spurious `[not_a_table]` capture, or an unstable re-encode here.
    @Test("combined unknown content round-trips identically through the single-split decode")
    func combinedUnknownContentRoundTripsThroughSingleSplitDecode() throws {
        let appearanceExtras = [
            "glow_strength = 0.65",
            "font_ligatures = true",
            "custom_ml = \"\"\"",
            #"\""""#,
            "[not_a_table]",
            "still content",
            "\"\"\"",
        ].joined(separator: "\n")
        let base = Self.defaultTOML
            .replacing("glow_strength = 0.65", with: appearanceExtras)
            .replacing(
                #"clipboard_write_policy = "ask""#,
                with: """
                    clipboard_write_policy = "ask"
                    custom_shell_integration = true
                    """
            )
        let toml = (base + "\n[external_tool]\nenabled = true\nnote = \"kept\"\n")
            .replacing("\n", with: "\r\n")

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.appearance.glowStrength == 0.65)
        #expect(decoded.unknownAppearanceTableLines.contains("font_ligatures = true"))
        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(decoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))

        // CRLF was normalized exactly once for every scan — no scan saw the
        // raw \r\n bytes.
        #expect(!decoded.unknownTerminalTableLines.contains("\r"))
        #expect(!decoded.unknownAppearanceTableLines.contains("\r"))
        #expect(decoded.unknownTopLevelTables["external_tool"]?.contains("\r") != true)
        #expect(decoded.unknownTopLevelTables["external_tool"]?.contains("enabled = true") == true)

        // The escaped-quote line did not terminate the multiline string, so
        // `[not_a_table]` stayed value content instead of becoming a table.
        #expect(decoded.unknownTopLevelTables["not_a_table"] == nil)

        #expect(reEncoded.contains("[external_tool]"))
        #expect(reEncoded.contains("enabled = true"))
        #expect(reEncoded.contains("custom_shell_integration = true"))
        #expect(reEncoded.contains("still content"))
        #expect(reEncoded.components(separatedBy: "[not_a_table]").count - 1 == 1)

        #expect(reDecoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))
        #expect(reDecoded.unknownTopLevelTables["external_tool"]?.contains("enabled = true") == true)
        #expect(reDecoded.unknownTopLevelTables["not_a_table"] == nil)
        #expect(try codec.encodeString(reDecoded) == reEncoded)
    }

    private static let defaultTOML = """
        [general]
        restore_workspaces = true
        sidebar_compact_mode = false
        menu_bar_visibility = "never"

        [appearance]
        theme = "system"
        accent = "peach"
        ui_font = "system"
        mono_font = "system-monospace"
        font_size = 13.0
        glow_strength = 0.65
        crt_scanlines = false
        cursor_glow = false
        always_show_jump_numbers = true
        terminal_theme_id = "catppuccin-latte"
        terminal_background_mode = "ghostty"
        terminal_background_color = "#1e1e2e"

        [notifications]
        muted = false
        sound = true
        respect_do_not_disturb = true
        notify_on_needs_attention = true
        dock_bounce_on_needs_attention = false
        show_workspace_details = false

        [agents]
        permission_posture = "ask_every_time"
        remember_tool_trust = true

        [terminal]
        clipboard_write_policy = "ask"
        confirm_clipboard_read = true

        [workspaces]
        default_group = "awesoMux"
        output_marks_needs_attention = true
        confirm_close_with_running_agent = false
        confirm_destructive_pane_action_with_running_agent = false

        [advanced]
        config_schema_version = 2
        """
}
