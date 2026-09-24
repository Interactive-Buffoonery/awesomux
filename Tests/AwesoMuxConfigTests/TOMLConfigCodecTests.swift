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

    @Test("invalid sidebar position fails decoding")
    func invalidSidebarPositionFailsDecoding() throws {
        let toml = Self.defaultTOML.replacing(
            "always_show_jump_numbers = true",
            with: """
                always_show_jump_numbers = true
                sidebar_position = "middle"
                """
        )

        #expect(throws: (any Error).self) {
            _ = try codec.decode(toml)
        }
    }

    @Test("unknown top-level table survives load and save")
    func unknownTopLevelTableSurvivesLoadAndSave() throws {
        let toml =
            Self.defaultTOML + """

                [external_tool]
                enabled = true
                note = "kept outside awesoMux schema"
                """

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(reEncoded.contains("[external_tool]"))
        #expect(reEncoded.contains("enabled = true"))
        #expect(reEncoded.contains("kept outside awesoMux schema"))
        #expect(reDecoded.unknownTopLevelTables["external_tool"]?.contains("enabled = true") == true)
    }

    @Test("quoted unknown table headers remain valid and distinct")
    func quotedUnknownTableHeadersRemainValidAndDistinct() throws {
        let toml =
            Self.defaultTOML + """

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

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

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
        #expect(try codec.encodeString(reDecoded) == reEncoded)
    }

    @Test("quoted table keys containing brackets end the preceding unknown table")
    func quotedTableKeysContainingBracketsEndPrecedingUnknownTable() throws {
        let cases = [
            (header: #"[workspaces.managed_ssh_always_managed."foo]bar"]"#, key: "foo]bar"),
            (header: #"[workspaces.managed_ssh_always_managed.'foo]bar']"#, key: "foo]bar"),
            (header: #"[workspaces.managed_ssh_always_managed."foo\"]bar"]"#, key: #"foo"]bar"#),
        ]

        for testCase in cases {
            let toml =
                Self.defaultTOML + """

                    [external_tool]
                    enabled = true

                    \(testCase.header)
                    session_name = "remote-session"
                    """

            let decoded = try codec.decode(toml)

            #expect(decoded.unknownTopLevelTables["external_tool"] == "enabled = true")
            #expect(
                decoded.workspaces.managedSSHAlwaysManaged[testCase.key]?.sessionName
                    == "remote-session"
            )
        }
    }

    @Test("unknown terminal key survives load and save")
    func unknownTerminalKeySurvivesLoadAndSave() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                clipboard_write_policy = "ask"
                custom_shell_integration = true
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))
        #expect(reEncoded.contains("custom_shell_integration = true"))
        #expect(reDecoded.unknownTerminalTableLines.contains("custom_shell_integration = true"))
    }

    @Test("invalid copy_on_select string still fails decode")
    func invalidCopyOnSelectStringStillFailsDecode() throws {
        let toml = Self.defaultTOML.replacing(
            "confirm_clipboard_read = true",
            with: """
                confirm_clipboard_read = true
                copy_on_select = "sometimes"
                """
        )

        #expect(throws: (any Error).self) { try codec.decode(toml) }
    }

    @Test("escaped quote inside multiline string does not terminate it")
    func escapedQuoteInsideMultilineStringDoesNotTerminateIt() throws {
        let appearanceExtras = [
            "glow_strength = 0.65",
            "custom_ml = \"\"\"",
            #"\""""#,
            "[not_a_table]",
            "still content",
            "\"\"\"",
        ].joined(separator: "\n")
        let toml = Self.defaultTOML.replacing("glow_strength = 0.65", with: appearanceExtras)

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.unknownTopLevelTables["not_a_table"] == nil)
        #expect(reEncoded.contains("still content"))
        #expect(reEncoded.contains("[not_a_table]"))
        #expect(reEncoded.components(separatedBy: "[not_a_table]").count - 1 == 1)
        #expect(reDecoded.unknownAppearanceTableLines.contains("still content"))
    }

    @Test("multiline string opened inside array does not split the section")
    func multilineStringInsideArrayDoesNotSplitSection() throws {
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
        let toml = Self.defaultTOML.replacing("glow_strength = 0.65", with: appearanceExtras)

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.unknownTopLevelTables["not_a_table"] == nil)
        #expect(reEncoded.contains("custom_prompts = ["))
        #expect(reEncoded.contains("alpha"))
        #expect(reEncoded.contains(#""beta""#))
        #expect(reEncoded.components(separatedBy: "[not_a_table]").count - 1 == 1)
        #expect(reDecoded.unknownAppearanceTableLines.contains(#""beta""#))
    }

    @Test("header-shaped line inside a preserved multiline extra does not corrupt a later section splice")
    func headerShapedLineInsideMultilineExtraDoesNotCorruptLaterSectionSplice() throws {
        // Terminal's splice runs before appearance's (see encodeString), so a
        // header-shaped line embedded in a preserved terminal multiline value
        // ends up in the text the appearance splice scans next. Today's fixed
        // alphabetical section order ([appearance] is immediately followed by
        // [general], long before [terminal]) means this assertion does not
        // fail without the guard — verified by reverting it locally. It
        // documents the symmetry with decode's guard and pins correct
        // behavior if that ordering ever changes (INT-727).
        let toml = Self.defaultTOML
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

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

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
        // Exactly two occurrences: the real [appearance] header plus the
        // header-shaped content line inside terminal's multiline value.
        #expect(reEncoded.components(separatedBy: "[appearance]").count - 1 == 2)
        #expect(reDecoded.unknownTerminalTableLines.contains("[appearance]"))
        #expect(reDecoded.unknownAppearanceTableLines.contains(#"custom_note = "preserved appearance extra""#))
        // Second encode/decode cycle must be byte-stable — the boundary scan
        // is exercised again with terminal's spliced extras already present
        // from the first cycle.
        #expect(try codec.encodeString(reDecoded) == reEncoded)
    }

    @Test("CRLF input preserves unknown section keys")
    func crlfInputPreservesUnknownSectionKeys() throws {
        let toml = Self.defaultTOML
            .replacing(
                "glow_strength = 0.65",
                with: "glow_strength = 0.65\nfont_ligatures = true"
            )
            .replacing("\n", with: "\r\n")

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.unknownAppearanceTableLines.contains("font_ligatures = true"))
        #expect(!decoded.unknownAppearanceTableLines.contains("\r"))
        #expect(reEncoded.contains("font_ligatures = true"))
    }

    @Test("double-quoted owned terminal keys do not re-encode as unknown lines")
    func quotedOwnedTerminalKeysDoNotReEncodeAsUnknownLines() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                "clipboard_write_policy" = "allow"
                "copy_on_select" = "on"
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .allow)
        #expect(decoded.terminal.copyOnSelect == .on)
        #expect(reEncoded.contains(#"clipboard_write_policy = "allow""#))
        #expect(reEncoded.contains(#"copy_on_select = "on""#))
        #expect(reEncoded.components(separatedBy: "clipboard_write_policy").count - 1 == 1)
        #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
        #expect(!reEncoded.contains(#""clipboard_write_policy" = "allow""#))
        #expect(!reEncoded.contains(#""copy_on_select" = "on""#))
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("single-quoted owned terminal keys do not self-brick on reload")
    func singleQuotedOwnedTerminalKeysReload() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                'clipboard_write_policy' = "allow"
                'copy_on_select' = "on"
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .allow)
        #expect(decoded.terminal.copyOnSelect == .on)
        #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
        #expect(reEncoded.components(separatedBy: "clipboard_write_policy").count - 1 == 1)
        #expect(!reEncoded.contains("'copy_on_select'"))
        let reDecoded = try codec.decode(reEncoded)
        #expect(reDecoded.terminal.copyOnSelect == .on)
        #expect(reDecoded.terminal.clipboardWritePolicy == .allow)
    }

    @Test("escaped basic-string owned terminal keys do not self-brick on reload")
    func escapedBasicStringOwnedTerminalKeysReload() throws {
        // `_` is `_`; "copy_on_select" decodes to the owned key. The
        // normalizer must unescape it, not bail on the backslash and duplicate.
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                "copy\\u005Fon_select" = "on"
                clipboard_write_policy = "ask"
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.copyOnSelect == .on)
        #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("Unicode-escaped unknown terminal keys round-trip without bricking")
    func unicodeEscapedUnknownKeysRoundTrip() throws {
        // Exercises the \UXXXXXXXX unescape path on an UNKNOWN key: it unescapes
        // to a non-owned name, so it must be preserved verbatim (not folded onto
        // an owned key) and the rewritten file must still load. Guards the
        // 8-digit escape branch against a mis-fold or a crash.
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                clipboard_write_policy = "ask"
                "emoji_\\U0001F600_key" = true
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("quoted [terminal] table header does not self-brick on reload")
    func quotedTerminalHeaderReload() throws {
        // `["terminal"]` is the same logical table as `[terminal]`.
        let toml = Self.defaultTOML.replacing(
            "[terminal]",
            with: #"["terminal"]"#
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(reEncoded.components(separatedBy: "[terminal]").count - 1 == 1)
        #expect(!reEncoded.contains(#"["terminal"]"#))
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("leading preserved terminal lines do not shift multiline placement")
    func leadingPreservedTerminalLinesDoNotShiftMultilinePlacement() throws {
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
        let toml = Self.defaultTOML.replacing(
            """
            clipboard_write_policy = "ask"
            confirm_clipboard_read = true
            """,
            with: replacement
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)
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
        #expect(try codec.encodeString(reDecoded) == reEncoded)
        #expect(thirdEncoded == reEncoded)
        #expect(fourthEncoded == reEncoded)

        let appearanceReplacement = [
            "",
            "   ",
            "custom_note = '''",
            "first line",
            "'''",
            "glow_strength = 0.4",
        ].joined(separator: "\n")
        let appearanceTOML = Self.defaultTOML.replacing(
            "glow_strength = 0.65",
            with: appearanceReplacement
        )
        let appearanceDecoded = try codec.decode(appearanceTOML)
        let appearanceReEncoded = try codec.encodeString(appearanceDecoded)
        let appearanceReDecoded = try codec.decode(appearanceReEncoded)

        #expect(
            appearanceReEncoded.contains(
                """
                custom_note = '''
                first line
                '''
                glow_strength = 0.4
                """))
        #expect(appearanceReDecoded.appearance.glowStrength == 0.4)
        #expect(try codec.encodeString(appearanceReDecoded) == appearanceReEncoded)
    }

    @Test("clipboard_write_policy invalid value reports terminal path")
    func invalidClipboardWritePolicyReportsTerminalPath() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: #"clipboard_write_policy = "sometimes""#
        )

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, _) {
            #expect(path.contains("terminal"))
            #expect(path.contains("clipboard_write_policy"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("confirm_close_with_running_agent wrong type reports a useful path")
    func confirmCloseWrongTypeReportsUsefulPath() throws {
        // Present-but-wrong-type values must throw loudly rather than silently
        // defaulting to `true`. Mirrors the existing
        // `wrongTypeReportsUsefulPath` discipline for the rest of the config.
        let toml = Self.defaultTOML.replacing(
            "confirm_close_with_running_agent = false",
            with: #"confirm_close_with_running_agent = "not a bool""#
        )

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, _) {
            #expect(path.contains("confirm_close_with_running_agent"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("invalid terminal background hex reports appearance path")
    func invalidTerminalBackgroundHexReportsAppearancePath() throws {
        let toml = Self.defaultTOML.replacing(
            "terminal_background_color = \"#1e1e2e\"",
            with: "terminal_background_color = \"blue\""
        )

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path == "appearance.terminal_background_color")
            #expect(message.contains("#RRGGBB"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
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

    @Test("wrong TOML type reports a useful path")
    func wrongTypeReportsUsefulPath() throws {
        let toml = Self.defaultTOML.replacing("font_size = 13.0", with: #"font_size = "large""#)

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path.contains("appearance"))
            #expect(path.contains("font_size"))
            #expect(message.contains("Double") || message.contains("float"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("general wrong type reports a useful path")
    func generalWrongTypeReportsUsefulPath() throws {
        let toml = Self.defaultTOML.replacing("restore_workspaces = true", with: #"restore_workspaces = "yes""#)

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path.contains("general"))
            #expect(path.contains("restore_workspaces"))
            #expect(message.contains("Bool") || message.contains("boolean"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("notifications wrong type reports a useful path")
    func notificationsWrongTypeReportsUsefulPath() throws {
        let toml = Self.defaultTOML.replacing("sound = true", with: #"sound = "loud""#)

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path.contains("notifications"))
            #expect(path.contains("sound"))
            #expect(message.contains("Bool") || message.contains("boolean"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("agents wrong type reports a useful path")
    func agentsWrongTypeReportsUsefulPath() throws {
        let toml = Self.defaultTOML.replacing("remember_tool_trust = true", with: #"remember_tool_trust = "yes""#)

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path.contains("agents"))
            #expect(path.contains("remember_tool_trust"))
            #expect(message.contains("Bool") || message.contains("boolean"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("invalid enum value reports a validation error")
    func invalidEnumValueReportsValidationError() throws {
        let toml = Self.defaultTOML.replacing(#"theme = "system""#, with: #"theme = "sepia""#)

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path.contains("appearance"))
            #expect(path.contains("theme"))
            #expect(message.contains("sepia") || message.contains("Theme"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("invalid terminal_background_mode reports a validation error")
    func invalidTerminalBackgroundModeReportsValidationError() throws {
        let toml = Self.defaultTOML.replacing(
            #"terminal_background_mode = "ghostty""#,
            with: #"terminal_background_mode = "catppuccin""#
        )

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, _) {
            #expect(path.contains("appearance"))
            #expect(path.contains("terminal_background_mode"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
        }
    }

    @Test("unsupported future config_schema_version reports validation error")
    func unsupportedFutureSchemaVersionReportsValidationError() throws {
        let toml = Self.defaultTOML.replacing("config_schema_version = 2", with: "config_schema_version = 99")

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected unsupported schema version, but decode succeeded")
        } catch ConfigLoadError.unsupportedSchemaVersion(let version) {
            #expect(version == 99)
        } catch {
            Issue.record("Expected unsupported schema version, got \(error)")
        }
    }

    @Test("zero config_schema_version reports validation error")
    func zeroSchemaVersionReportsValidationError() throws {
        let toml = Self.defaultTOML.replacing("config_schema_version = 2", with: "config_schema_version = 0")

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path == "advanced.config_schema_version")
            #expect(message.contains("at least 1"))
        } catch {
            Issue.record("Expected invalid value, got \(error)")
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

    @Test("workspace default group strips INT-92 spoofing scalars")
    func workspaceDefaultGroupStripsINT92SpoofingScalars() throws {
        let toml = Self.defaultTOML.replacing(
            #"default_group = "awesoMux""#,
            with: #"default_group = "  Field\u00A0\u115F\uFE0FOps\U000E0100  ""#
        )

        let decoded = try codec.decode(toml)

        // Hangul filler + variation selectors stripped; the interior NBSP is
        // remapped to a plain space so the word boundary survives.
        #expect(decoded.workspaces.defaultGroup == "Field Ops")
    }

    @Test("workspace default group falls back when only invisible scalars remain")
    func workspaceDefaultGroupFallsBackWhenOnlyInvisibleScalarsRemain() throws {
        let toml = Self.defaultTOML.replacing(
            #"default_group = "awesoMux""#,
            with: #"default_group = "\u115F\uFE0F\U000E0100""#
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.workspaces.defaultGroup == AwesoMuxConfig.defaultValue.workspaces.defaultGroup)
    }

    @Test("workspace default group strips directional hints like other group names")
    func workspaceDefaultGroupStripsDirectionalHints() {
        // LRM / RLM / ALM stay in titles (INT-93), but `default_group` is a
        // routing key and must match the runtime group-name sanitization,
        // which strips them (INT-381 follow-up).
        let lrm = "src/main.rs\u{200E}(latin)"
        let rlm = "src/main.rs\u{200F}(عربي)"
        let alm = "src/main.rs\u{061C}(عربي)"
        #expect(WorkspaceConfig.normalizedDefaultGroup(lrm) == "src/main.rs(latin)")
        #expect(WorkspaceConfig.normalizedDefaultGroup(rlm) == "src/main.rs(عربي)")
        #expect(WorkspaceConfig.normalizedDefaultGroup(alm) == "src/main.rs(عربي)")
        // Hint-only input collapses to the canonical default.
        #expect(WorkspaceConfig.normalizedDefaultGroup("\u{200E}") == WorkspaceConfig.defaultValue.defaultGroup)
        #expect(WorkspaceConfig.normalizedDefaultGroup("\u{200F}") == WorkspaceConfig.defaultValue.defaultGroup)
        #expect(WorkspaceConfig.normalizedDefaultGroup("\u{061C}") == WorkspaceConfig.defaultValue.defaultGroup)
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
