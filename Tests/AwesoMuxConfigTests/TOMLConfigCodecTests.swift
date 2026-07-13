import Foundation
import Testing
@testable import AwesoMuxConfig

@Suite("TOMLConfigCodec")
struct TOMLConfigCodecTests {
    private let codec = TOMLConfigCodec()

    @Test("default config encodes successfully")
    func defaultConfigEncodesSuccessfully() throws {
        let data = try codec.encode(.defaultValue)

        #expect(!data.isEmpty)
        #expect(String(data: data, encoding: .utf8) != nil)
        #expect(AppearanceConfig.defaultValue.uiFont == "Geist")
    }

    @Test("encoded default decodes back to the same value")
    func encodedDefaultDecodesBackToSameValue() throws {
        let data = try codec.encode(.defaultValue)
        let decoded = try codec.decode(data)

        #expect(decoded == .defaultValue)
    }

    @Test("nested snake_case keys decode through explicit CodingKeys")
    func nestedSnakeCaseKeysDecodeThroughExplicitCodingKeys() throws {
        let decoded = try codec.decode(Self.defaultTOML)

        #expect(decoded.appearance.uiFont == "system")
        #expect(decoded.appearance.monoFont == "system-monospace")
        #expect(decoded.appearance.fontSize == 13.0)
        #expect(decoded.appearance.glowStrength == 0.65)
        #expect(!decoded.general.showMenuBarMiniStatus)
        #expect(decoded.notifications.respectDoNotDisturb)
        #expect(decoded.agents.permissionPosture == .askEveryTime)
        #expect(decoded.agents.rememberToolTrust)
        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(decoded.terminal.confirmClipboardRead)
        #expect(decoded.terminal.copyOnSelect == .inherit)
        #expect(!decoded.terminal.commandBridgeEnabled)
        #expect(decoded.workspaces.defaultGroup == "awesoMux")
        #expect(decoded.workspaces.outputMarksNeedsAttention)
        #expect(decoded.advanced.configSchemaVersion == 2)
    }

    @Test("v1 TOML without general/crt/cursor/notify keys decodes with defaults")
    func v1TOMLWithoutNewKeysDecodesWithDefaults() throws {
        let decoded = try codec.decode(Self.v1DefaultTOML)

        #expect(decoded.general == GeneralConfig.defaultValue)
        #expect(decoded.appearance.crtScanlines == AppearanceConfig.defaultValue.crtScanlines)
        #expect(decoded.appearance.cursorGlow == AppearanceConfig.defaultValue.cursorGlow)
        #expect(decoded.appearance.terminalThemeID == nil)
        #expect(decoded.appearance.terminalBackgroundMode == .ghostty)
        #expect(decoded.appearance.terminalBackgroundColor == "#1e1e2e")
        #expect(decoded.appearance.sidebarPosition == .left)
        #expect(
            decoded.notifications.notifyOnNeedsAttention
                == NotificationConfig.defaultValue.notifyOnNeedsAttention)
        #expect(
            decoded.notifications.dockBounceOnNeedsAttention
                == NotificationConfig.defaultValue.dockBounceOnNeedsAttention)
        #expect(
            decoded.notifications.showWorkspaceDetails
                == NotificationConfig.defaultValue.showWorkspaceDetails)
        #expect(decoded.terminal == TerminalConfig.defaultValue)
        #expect(decoded.advanced.configSchemaVersion == 1)
    }

    @Test("v1 TOML re-encodes as a v2 file with new defaults filled in")
    func v1TOMLReEncodesAsV2WithNewDefaultsFilledIn() throws {
        let decoded = try codec.decode(Self.v1DefaultTOML)
        var migrated = decoded
        migrated.advanced.configSchemaVersion = AdvancedConfig.supportedConfigSchemaVersion

        let reEncoded = try codec.encodeString(migrated)

        #expect(reEncoded.contains("config_schema_version = 2"))
        #expect(reEncoded.contains("[general]"))
        #expect(reEncoded.contains("show_menu_bar_mini_status = false"))
        #expect(reEncoded.contains("crt_scanlines = false"))
        #expect(reEncoded.contains("cursor_glow = false"))
        #expect(!reEncoded.contains("terminal_theme_id"))
        #expect(reEncoded.contains(#"terminal_background_mode = "ghostty""#))
        #expect(reEncoded.contains("terminal_background_color = \"#1e1e2e\""))
        #expect(reEncoded.contains("notify_on_needs_attention = true"))
        #expect(reEncoded.contains("dock_bounce_on_needs_attention = false"))
        #expect(reEncoded.contains("show_workspace_details = false"))
        #expect(reEncoded.contains(#"clipboard_write_policy = "ask""#))
        #expect(reEncoded.contains("confirm_clipboard_read = true"))
        #expect(reEncoded.contains(#"copy_on_select = "inherit""#))
        #expect(reEncoded.contains("command_bridge_enabled = false"))
    }

    @Test("v2 round-trip preserves new appearance + notification fields")
    func v2RoundTripPreservesNewFields() throws {
        let config = AwesoMuxConfig(
            general: GeneralConfig(
                restoreWorkspaces: false,
                sidebarCompactMode: true,
                showMenuBarMiniStatus: true
            ),
            appearance: AppearanceConfig(
                theme: .dark,
                accent: .sapphire,
                crtScanlines: true,
                cursorGlow: true,
                terminalThemeID: TerminalThemeCatalog.catppuccinID,
                terminalBackgroundMode: .custom,
                terminalBackgroundColor: "#313244"
            ),
            notifications: NotificationConfig(
                muted: false,
                sound: true,
                respectDoNotDisturb: false,
                notifyOnNeedsAttention: false,
                dockBounceOnNeedsAttention: true,
                notifyOnTurnDone: true,
                turnDoneAlertsWhenFocused: true,
                showWorkspaceDetails: true
            ),
            terminal: TerminalConfig(clipboardWritePolicy: .deny)
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(decoded == config)
        #expect(encoded.contains("show_menu_bar_mini_status = true"))
    }

    @Test("terminal_theme_id round-trips through appearance table")
    func terminalThemeIDRoundTripsThroughAppearanceTable() throws {
        var config = AwesoMuxConfig.defaultValue
        config.appearance.terminalThemeID = TerminalThemeCatalog.catppuccinID

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains(#"terminal_theme_id = "catppuccin""#))
        #expect(decoded.appearance.terminalThemeID == TerminalThemeCatalog.catppuccinID)
    }

    @Test("TOML without confirm fields decodes to default true")
    func missingConfirmFieldsDecodeToDefaultTrue() throws {
        // v1 fixture omits these fields (they didn't exist yet). Additive-decode
        // contract: existing user configs keep working, new confirm fields default
        // to true (the conservative-by-default policy from INT-22 / INT-451).
        let decoded = try codec.decode(Self.v1DefaultTOML)

        #expect(decoded.workspaces.confirmCloseWithRunningAgent)
        #expect(decoded.workspaces.confirmDestructivePaneActionWithRunningAgent)
    }

    @Test("confirm_close_with_running_agent = false round-trips")
    func confirmCloseFalseRoundTrips() throws {
        let config = AwesoMuxConfig(
            workspaces: WorkspaceConfig(
                defaultGroup: "awesoMux",
                outputMarksNeedsAttention: true,
                confirmCloseWithRunningAgent: false
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("confirm_close_with_running_agent = false"))
        #expect(!decoded.workspaces.confirmCloseWithRunningAgent)
    }

    @Test("confirm_destructive_pane_action_with_running_agent = false round-trips")
    func confirmDestructivePaneActionFalseRoundTrips() throws {
        let config = AwesoMuxConfig(
            workspaces: WorkspaceConfig(
                defaultGroup: "awesoMux",
                outputMarksNeedsAttention: true,
                confirmDestructivePaneActionWithRunningAgent: false
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("confirm_destructive_pane_action_with_running_agent = false"))
        #expect(!decoded.workspaces.confirmDestructivePaneActionWithRunningAgent)
    }

    @Test("missing terminal table decodes clipboard writes to ask")
    func missingTerminalTableDecodesClipboardWritesToAsk() throws {
        let decoded = try codec.decode(Self.v1DefaultTOML)

        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(decoded.terminal.confirmClipboardRead)
    }

    @Test("clipboard_write_policy values round-trip")
    func clipboardWritePolicyValuesRoundTrip() throws {
        for policy in TerminalConfig.ClipboardWritePolicy.allCases {
            let config = AwesoMuxConfig(
                terminal: TerminalConfig(clipboardWritePolicy: policy)
            )

            let encoded = try codec.encodeString(config)
            let decoded = try codec.decode(encoded)

            #expect(encoded.contains(#"clipboard_write_policy = "\#(policy.rawValue)""#))
            #expect(decoded.terminal.clipboardWritePolicy == policy)
        }
    }

    @Test("copy_on_select values round-trip")
    func copyOnSelectValuesRoundTrip() throws {
        for copyOnSelect in TerminalConfig.CopyOnSelect.allCases {
            let config = AwesoMuxConfig(
                terminal: TerminalConfig(copyOnSelect: copyOnSelect)
            )

            let encoded = try codec.encodeString(config)
            let decoded = try codec.decode(encoded)

            #expect(encoded.contains(#"copy_on_select = "\#(copyOnSelect.rawValue)""#))
            #expect(decoded.terminal.copyOnSelect == copyOnSelect)
        }
    }

    @Test("confirm_clipboard_read values round-trip")
    func confirmClipboardReadValuesRoundTrip() throws {
        for enabled in [false, true] {
            let config = AwesoMuxConfig(
                terminal: TerminalConfig(confirmClipboardRead: enabled)
            )

            let encoded = try codec.encodeString(config)
            let decoded = try codec.decode(encoded)

            #expect(encoded.contains("confirm_clipboard_read = \(enabled)"))
            #expect(decoded.terminal.confirmClipboardRead == enabled)
        }
    }

    @Test("command_bridge_enabled values round-trip")
    func commandBridgeEnabledValuesRoundTrip() throws {
        for enabled in [false, true] {
            let config = AwesoMuxConfig(
                terminal: TerminalConfig(commandBridgeEnabled: enabled)
            )

            let encoded = try codec.encodeString(config)
            let decoded = try codec.decode(encoded)

            #expect(encoded.contains("command_bridge_enabled = \(enabled)"))
            #expect(decoded.terminal.commandBridgeEnabled == enabled)
        }
    }

    @Test("terminal daemon idle-cap fields round-trip through TOML")
    func daemonIdleCapRoundTrip() throws {
        var config = AwesoMuxConfig.defaultValue
        config.terminal.daemonIdleCapEnabled = true
        config.terminal.daemonIdleCapMinutes = 4320  // 3 days
        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)
        #expect(decoded.terminal.daemonIdleCapEnabled == true)
        #expect(decoded.terminal.daemonIdleCapMinutes == 4320)
        #expect(encoded.contains("daemon_idle_cap_enabled = true"))
        #expect(encoded.contains("daemon_idle_cap_minutes = 4320"))
        // default stays off
        #expect(AwesoMuxConfig.defaultValue.terminal.daemonIdleCapEnabled == false)
        #expect(AwesoMuxConfig.defaultValue.terminal.daemonIdleCapMinutes == 10_080)
        // not emitted into ghostty override
        #expect(!decoded.terminal.ghosttyOverrideConfigContents.contains("daemon_idle_cap"))
    }

    @Test("terminal table without copy_on_select decodes as inherit")
    func terminalTableWithoutCopyOnSelectDecodesAsInherit() throws {
        let decoded = try codec.decode(Self.defaultTOML)

        #expect(decoded.terminal.copyOnSelect == .inherit)
    }

    @Test("terminal table missing every owned key decodes to all defaults")
    func terminalTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        // Guardrail for the @TOMLDefault wiring: a [terminal] table present but
        // empty must default EVERY owned key, not throw keyNotFound. If a future
        // field is added without an @TOMLDefault wrapper, this fails loudly
        // instead of shipping a config that can't decode when the key is absent.
        let toml = Self.defaultTOML.replacing(
            """
            clipboard_write_policy = "ask"
            confirm_clipboard_read = true
            """,
            with: "# intentionally empty terminal table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.terminal == TerminalConfig.defaultValue)
    }

    @Test("general table missing every owned key decodes to all defaults")
    func generalTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            """
            restore_workspaces = true
            sidebar_compact_mode = false
            show_menu_bar_mini_status = false
            """,
            with: "# intentionally empty general table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.general == GeneralConfig.defaultValue)
    }

    @Test("appearance table missing every owned key decodes to all defaults")
    func appearanceTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            """
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
            """,
            with: "# intentionally empty appearance table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.appearance == AppearanceConfig.defaultValue)
        #expect(decoded.appearance.sidebarPosition == .left)
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

    @Test("notifications table missing every owned key decodes to all defaults")
    func notificationsTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            """
            muted = false
            sound = true
            respect_do_not_disturb = true
            notify_on_needs_attention = true
            dock_bounce_on_needs_attention = false
            show_workspace_details = false
            """,
            with: "# intentionally empty notifications table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.notifications == NotificationConfig.defaultValue)
    }

    @Test("workspaces table missing every owned key decodes to all defaults")
    func workspacesTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            """
            default_group = "awesoMux"
            output_marks_needs_attention = true
            confirm_close_with_running_agent = false
            confirm_destructive_pane_action_with_running_agent = false
            """,
            with: "# intentionally empty workspaces table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.workspaces == WorkspaceConfig.defaultValue)
    }

    @Test("agents table missing every owned key decodes to all defaults")
    func agentsTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            """
            permission_posture = "ask_every_time"
            remember_tool_trust = true
            """,
            with: "# intentionally empty agents table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.agents == AgentConfig.defaultValue)
    }

    @Test("advanced table missing every owned key decodes to all defaults")
    func advancedTableMissingEveryOwnedKeyDecodesToDefaults() throws {
        let toml = Self.defaultTOML.replacing(
            "config_schema_version = 2",
            with: "# intentionally empty advanced table"
        )

        let decoded = try codec.decode(toml)

        #expect(decoded.advanced == AdvancedConfig.defaultValue)
    }

    @Test("missing agent integrations table decodes to defaults")
    func missingAgentIntegrationsTableDecodesToDefaults() throws {
        let decoded = try codec.decode(Self.defaultTOML)

        #expect(decoded.agentIntegrations == .defaultValue)
    }

    @Test("missing keyboard table decodes to defaults")
    func missingKeyboardTableDecodesToDefaults() throws {
        let decoded = try codec.decode(Self.defaultTOML)

        #expect(decoded.keyboard == .defaultValue)
    }

    @Test("custom keyboard shortcuts round-trip")
    func customKeyboardShortcutsRoundTrip() throws {
        let config = AwesoMuxConfig(
            keyboard: KeyboardConfig(
                shortcuts: [
                    "toggleFloatingPanel": ShortcutBindingConfig(
                        key: ";",
                        modifiers: [.command, .option]
                    )
                ]
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("[keyboard.shortcuts.toggleFloatingPanel]"))
        #expect(encoded.contains(#"key = ";""#))
        #expect(encoded.contains(#"modifiers = ["command", "option"]"#))
        #expect(decoded.keyboard == config.keyboard)
    }

    @Test("configured file-drop integration setup paths round-trip")
    func configuredAgentIntegrationSetupPathsRoundTrip() throws {
        let config = AwesoMuxConfig(
            agentIntegrations: AgentIntegrationsConfig(
                openCode: AgentIntegrationSetup(
                    binaryPath: "/opt/homebrew/bin/opencode",
                    configHome: "/Users/example/.config/opencode"
                ),
                pi: AgentIntegrationSetup(
                    binaryPath: "/opt/homebrew/bin/pi",
                    configHome: "/Users/example/.pi/agent"
                ),
                grok: AgentIntegrationSetup(
                    binaryPath: "/Users/example/.grok/bin/grok",
                    configHome: "/Users/example/.grok"
                )
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("[agent_integrations.open_code]"))
        #expect(encoded.contains("enabled = false"))
        #expect(encoded.contains(#"binary_path = "/opt/homebrew/bin/opencode""#))
        #expect(encoded.contains(#"config_home = "/Users/example/.config/opencode""#))
        #expect(encoded.contains("[agent_integrations.pi]"))
        #expect(encoded.contains(#"binary_path = "/opt/homebrew/bin/pi""#))
        #expect(encoded.contains(#"config_home = "/Users/example/.pi/agent""#))
        #expect(encoded.contains("[agent_integrations.grok]"))
        #expect(encoded.contains(#"binary_path = "/Users/example/.grok/bin/grok""#))
        #expect(encoded.contains(#"config_home = "/Users/example/.grok""#))
        #expect(decoded.agentIntegrations == config.agentIntegrations)
        #expect(!decoded.agentIntegrations.openCode.enabled)
        #expect(!decoded.agentIntegrations.pi.enabled)
        #expect(!decoded.agentIntegrations.grok.enabled)
    }

    @Test("configured Claude Code and Codex integration setup paths round-trip")
    func configuredClaudeCodeAndCodexSetupPathsRoundTrip() throws {
        let config = AwesoMuxConfig(
            agentIntegrations: AgentIntegrationsConfig(
                claudeCode: AgentIntegrationSetup(
                    binaryPath: "/opt/homebrew/bin/claude",
                    configHome: "/Users/example/.claude"
                ),
                codex: AgentIntegrationSetup(
                    binaryPath: "/opt/homebrew/bin/codex",
                    configHome: "/Users/example/.codex"
                )
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("[agent_integrations.claude_code]"))
        #expect(encoded.contains(#"binary_path = "/opt/homebrew/bin/claude""#))
        #expect(encoded.contains(#"config_home = "/Users/example/.claude""#))
        #expect(encoded.contains("[agent_integrations.codex]"))
        #expect(encoded.contains(#"binary_path = "/opt/homebrew/bin/codex""#))
        #expect(encoded.contains(#"config_home = "/Users/example/.codex""#))
        #expect(decoded.agentIntegrations == config.agentIntegrations)
        #expect(!decoded.agentIntegrations.claudeCode.enabled)
        #expect(!decoded.agentIntegrations.codex.enabled)
    }

    @Test("missing Claude Code and Codex providers decode to defaults")
    func missingClaudeCodeAndCodexProvidersDecodeToDefaults() throws {
        let toml =
            Self.defaultTOML + """

                [agent_integrations.open_code]
                binary_path = "/opt/homebrew/bin/opencode"
                """

        let decoded = try codec.decode(toml)

        #expect(decoded.agentIntegrations.claudeCode == .defaultValue)
        #expect(decoded.agentIntegrations.codex == .defaultValue)
        #expect(!decoded.agentIntegrations.claudeCode.enabled)
        #expect(decoded.agentIntegrations.claudeCode.binaryPath == nil)
        #expect(decoded.agentIntegrations.codex.configHome == nil)
    }

    @Test("Claude Code and Codex enabled flags round-trip")
    func claudeCodeAndCodexEnabledFlagsRoundTrip() throws {
        let config = AwesoMuxConfig(
            agentIntegrations: AgentIntegrationsConfig(
                claudeCode: AgentIntegrationSetup(enabled: true),
                codex: AgentIntegrationSetup(enabled: true)
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("enabled = true"))
        #expect(decoded.agentIntegrations.claudeCode.enabled)
        #expect(decoded.agentIntegrations.codex.enabled)
    }

    @Test("agent integration setup enabled flag round-trips")
    func agentIntegrationSetupEnabledFlagRoundTrips() throws {
        let config = AwesoMuxConfig(
            agentIntegrations: AgentIntegrationsConfig(
                openCode: AgentIntegrationSetup(enabled: true),
                pi: AgentIntegrationSetup(enabled: true),
                grok: AgentIntegrationSetup(enabled: true)
            )
        )

        let encoded = try codec.encodeString(config)
        let decoded = try codec.decode(encoded)

        #expect(encoded.contains("enabled = true"))
        #expect(decoded.agentIntegrations.openCode.enabled)
        #expect(decoded.agentIntegrations.pi.enabled)
        #expect(decoded.agentIntegrations.grok.enabled)
    }

    @Test("agent integration paths without enabled remain disabled")
    func agentIntegrationPathsWithoutEnabledRemainDisabled() throws {
        let toml =
            Self.defaultTOML + """

                [agent_integrations.open_code]
                binary_path = "/opt/homebrew/bin/opencode"
                config_home = "/Users/example/.config/opencode"

                [agent_integrations.pi]
                binary_path = "/opt/homebrew/bin/pi"
                config_home = "/Users/example/.pi/agent"

                [agent_integrations.grok]
                binary_path = "/Users/example/.grok/bin/grok"
                config_home = "/Users/example/.grok"
                """

        let decoded = try codec.decode(toml)

        #expect(!decoded.agentIntegrations.openCode.enabled)
        #expect(!decoded.agentIntegrations.pi.enabled)
        #expect(!decoded.agentIntegrations.grok.enabled)
        #expect(decoded.agentIntegrations.openCode.binaryPath == "/opt/homebrew/bin/opencode")
        #expect(decoded.agentIntegrations.pi.configHome == "/Users/example/.pi/agent")
        #expect(decoded.agentIntegrations.grok.configHome == "/Users/example/.grok")
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

    @Test("known terminal keys are replaced by structured values")
    func knownTerminalKeysAreReplacedByStructuredValues() throws {
        let toml = Self.defaultTOML.replacing(
            """
            clipboard_write_policy = "ask"
            confirm_clipboard_read = true
            """,
            with: """
                clipboard_write_policy = "deny"
                confirm_clipboard_read = false
                copy_on_select = "off"
                custom_shell_integration = true
                """
        )

        var decoded = try codec.decode(toml)
        decoded.terminal = TerminalConfig(
            clipboardWritePolicy: .allow,
            confirmClipboardRead: true,
            copyOnSelect: .on
        )
        let reEncoded = try codec.encodeString(decoded)

        #expect(reEncoded.contains(#"clipboard_write_policy = "allow""#))
        #expect(reEncoded.contains("confirm_clipboard_read = true"))
        #expect(reEncoded.contains(#"copy_on_select = "on""#))
        #expect(reEncoded.contains("custom_shell_integration = true"))
        #expect(!reEncoded.contains(#"clipboard_write_policy = "deny""#))
        #expect(!reEncoded.contains("confirm_clipboard_read = false"))
        #expect(!reEncoded.contains(#"copy_on_select = "off""#))
        #expect(reEncoded.components(separatedBy: "clipboard_write_policy").count - 1 == 1)
        #expect(reEncoded.components(separatedBy: "confirm_clipboard_read").count - 1 == 1)
        #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("legacy boolean copy_on_select decodes instead of invalidating the config")
    func legacyBooleanCopyOnSelectDecodes() throws {
        for (legacy, expected) in [("true", TerminalConfig.CopyOnSelect.on), ("false", .off)] {
            let toml = Self.defaultTOML.replacing(
                "confirm_clipboard_read = true",
                with: """
                    confirm_clipboard_read = true
                    copy_on_select = \(legacy)
                    """
            )

            let decoded = try codec.decode(toml)

            #expect(decoded.terminal.copyOnSelect == expected)
            #expect(decoded.appearance.accent == AwesoMuxConfig.defaultValue.appearance.accent)
        }
    }

    @Test("legacy boolean copy_on_select re-encodes in string form")
    func legacyBooleanCopyOnSelectReEncodesAsString() throws {
        let toml = Self.defaultTOML.replacing(
            "confirm_clipboard_read = true",
            with: """
                confirm_clipboard_read = true
                copy_on_select = true
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(reEncoded.contains(#"copy_on_select = "on""#))
        #expect(!reEncoded.contains("copy_on_select = true"))
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

    @Test("unknown key in appearance section survives load and save")
    func unknownKeyInAppearanceSectionSurvivesLoadAndSave() throws {
        let appearanceExtras = [
            "glow_strength = 0.65",
            "font_ligatures = true",
            #"custom_note = "value # not a comment""#,
            "custom_multiline = \"\"\"",
            "first line",
            "[not_a_table]",
            "second line",
            "\"\"\"",
            "custom_map = { a = 1, b = 2 }",
        ].joined(separator: "\n")
        let toml = Self.defaultTOML.replacing(
            "glow_strength = 0.65",
            with: appearanceExtras
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.appearance.glowStrength == 0.65)
        #expect(decoded.unknownAppearanceTableLines.contains("font_ligatures = true"))
        #expect(reEncoded.contains("font_ligatures = true"))
        #expect(reEncoded.contains(#"custom_note = "value # not a comment""#))
        #expect(
            reEncoded.contains(
                """
                custom_multiline = \"\"\"
                first line
                [not_a_table]
                second line
                \"\"\"
                """))
        #expect(reEncoded.contains("custom_map = { a = 1, b = 2 }"))
        #expect(reEncoded.contains("glow_strength = 0.65"))
        #expect(reDecoded.unknownAppearanceTableLines.contains("font_ligatures = true"))
        #expect(reDecoded.unknownAppearanceTableLines.contains(#"custom_note = "value # not a comment""#))
        #expect(reDecoded.unknownAppearanceTableLines.contains("custom_map = { a = 1, b = 2 }"))
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

    @Test("unknown appearance sub-table round-trips")
    func unknownAppearanceSubTableRoundTrips() throws {
        let toml = Self.defaultTOML + "\n[appearance.custom]\nweight = 3\n"

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        let reDecoded = try codec.decode(reEncoded)

        #expect(decoded.unknownTopLevelTables["appearance.custom"] == "weight = 3")
        #expect(reEncoded.contains("[appearance.custom]"))
        #expect(reEncoded.contains("weight = 3"))
        #expect(reDecoded.unknownTopLevelTables["appearance.custom"] == "weight = 3")
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

    @Test("unknown terminal table keys round-trip")
    func unknownTerminalTableKeysRoundTrip() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                clipboard_write_policy = "ask"
                copy_on_select = "on"
                custom_shell_integration = true
                # keep this terminal note
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(decoded.terminal.copyOnSelect == .on)
        #expect(reEncoded.contains("custom_shell_integration = true"))
        #expect(reEncoded.contains("# keep this terminal note"))
        #expect(reEncoded.contains(#"clipboard_write_policy = "ask""#))
        #expect(reEncoded.contains(#"copy_on_select = "on""#))
        #expect(reEncoded.components(separatedBy: "copy_on_select").count - 1 == 1)
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

    @Test("quoted unknown terminal keys round-trip")
    func quotedUnknownTerminalKeysRoundTrip() throws {
        let toml = Self.defaultTOML.replacing(
            #"clipboard_write_policy = "ask""#,
            with: """
                clipboard_write_policy = "ask"
                "custom_shell_integration" = true
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)

        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(reEncoded.contains(#""custom_shell_integration" = true"#))
    }

    @Test("unknown terminal sub-table round-trips")
    func unknownTerminalSubtableRoundTrips() throws {
        // A hand-written `[terminal.cursor]` has no owner in TerminalConfig and
        // would be dropped on rewrite unless preserved. Verify it survives, and
        // survives a SECOND round-trip (it is re-emitted at end-of-file, so the
        // appended placement must itself re-parse cleanly).
        let toml = Self.defaultTOML.replacing(
            "[workspaces]",
            with: """
                [terminal.cursor]
                style = "block"
                blink = false

                [workspaces]
                """
        )

        let decoded = try codec.decode(toml)
        let reEncoded = try codec.encodeString(decoded)
        #expect(decoded.terminal.clipboardWritePolicy == .ask)
        #expect(reEncoded.contains("[terminal.cursor]"))
        #expect(reEncoded.contains(#"style = "block""#))
        #expect(reEncoded.contains("blink = false"))

        let reDecoded = try codec.decode(reEncoded)
        let reReEncoded = try codec.encodeString(reDecoded)
        #expect(reDecoded.terminal.clipboardWritePolicy == .ask)
        #expect(reReEncoded.contains("[terminal.cursor]"))
        #expect(reReEncoded.contains(#"style = "block""#))
    }

    @Test("partially quoted terminal sub-table headers normalize per segment")
    func partiallyQuotedTerminalSubtableHeadersNormalizePerSegment() throws {
        for header in [#"["terminal".cursor]"#, #"[terminal."cursor"]"#] {
            let toml = Self.defaultTOML.replacing(
                "[workspaces]",
                with: """
                    \(header)
                    style = "block"

                    [workspaces]
                    """
            )

            let decoded = try codec.decode(toml)
            let reEncoded = try codec.encodeString(decoded)

            #expect(decoded.unknownTopLevelTables["terminal.cursor"]?.contains(#"style = "block""#) == true)
            #expect(reEncoded.contains("[terminal.cursor]"))
            #expect(!reEncoded.contains(header))
            #expect(throws: Never.self) { try codec.decode(reEncoded) }
        }
    }

    @Test("unknown terminal lines preserve original placement around owned keys")
    func unknownTerminalLinesPreserveOriginalPlacementAroundOwnedKeys() throws {
        let toml = Self.defaultTOML.replacing(
            """
            clipboard_write_policy = "ask"
            confirm_clipboard_read = true
            """,
            with: """
                # custom clipboard policy note
                clipboard_write_policy = "deny"
                custom_shell_integration = true
                confirm_clipboard_read = false
                """
        )

        var decoded = try codec.decode(toml)
        decoded.terminal = TerminalConfig(
            clipboardWritePolicy: .allow,
            confirmClipboardRead: true
        )

        let reEncoded = try codec.encodeString(decoded)
        let noteRange = try #require(reEncoded.range(of: "# custom clipboard policy note"))
        let clipboardRange = try #require(reEncoded.range(of: #"clipboard_write_policy = "allow""#))
        let customRange = try #require(reEncoded.range(of: "custom_shell_integration = true"))
        let confirmRange = try #require(reEncoded.range(of: "confirm_clipboard_read = true"))

        #expect(noteRange.lowerBound < clipboardRange.lowerBound)
        #expect(clipboardRange.lowerBound < customRange.lowerBound)
        #expect(customRange.lowerBound < confirmRange.lowerBound)
        #expect(throws: Never.self) { try codec.decode(reEncoded) }
    }

    @Test("terminal config inherit emits no copy-on-select override")
    func terminalConfigInheritEmitsNoCopyOnSelectOverride() {
        // Default is .inherit: we must NOT emit a copy-on-select line, so
        // Ghostty's native default (on, for macOS) and the user's own ghostty
        // config are left intact rather than clobbered.
        for policy in TerminalConfig.ClipboardWritePolicy.allCases {
            for confirmClipboardRead in [true, false] {
                let config = TerminalConfig(
                    clipboardWritePolicy: policy,
                    confirmClipboardRead: confirmClipboardRead,
                    copyOnSelect: .inherit
                )

                #expect(
                    config.ghosttyOverrideConfigContents == """
                        clipboard-write = \(policy.rawValue)
                        clipboard-read = \(confirmClipboardRead ? "ask" : "deny")
                        clipboard-paste-protection = true

                        """)
            }
        }
    }

    @Test("terminal config maps copy-on-select tri-state to Ghostty values")
    func terminalConfigMapsCopyOnSelectToGhosttyValues() {
        #expect(
            TerminalConfig(copyOnSelect: .off).ghosttyOverrideConfigContents
                .contains("copy-on-select = false"))
        // macOS has no selection clipboard, so `clipboard` is what actually
        // lands selections on the system pasteboard — `true` would be a no-op.
        #expect(
            TerminalConfig(copyOnSelect: .on).ghosttyOverrideConfigContents
                .contains("copy-on-select = clipboard"))
        #expect(
            !TerminalConfig(copyOnSelect: .inherit).ghosttyOverrideConfigContents
                .contains("copy-on-select"))
    }

    @Test("terminal config force-overrides clipboard-read from confirmClipboardRead")
    func terminalConfigForceOverridesClipboardRead() {
        #expect(
            TerminalConfig(confirmClipboardRead: true).ghosttyOverrideConfigContents
                .contains("clipboard-read = ask"))
        #expect(
            TerminalConfig(confirmClipboardRead: false).ghosttyOverrideConfigContents
                .contains("clipboard-read = deny"))
    }

    @Test("terminal config does not override clipboard-paste-bracketed-safe")
    func terminalConfigDoesNotOverrideClipboardPasteBracketedSafe() {
        // Ghostty's default (true) treats bracketed-paste-aware programs as
        // safe paste targets, so leave the key to Ghostty / the user's own config.
        #expect(
            !TerminalConfig.defaultValue.ghosttyOverrideConfigContents
                .contains("clipboard-paste-bracketed-safe"))
    }

    @Test("terminal config force-overrides clipboard-paste-protection")
    func terminalConfigForceOverridesClipboardPasteProtection() {
        // clipboard-paste-protection is the master switch libghostty checks
        // for unsafe-paste detection (vendor/ghostty Surface.zig short-circuits
        // the whole check when it's off). No app-level toggle exists for it —
        // force it on unconditionally so a user's own ghostty config can't
        // silently disable the confirm dialog.
        #expect(
            TerminalConfig.defaultValue.ghosttyOverrideConfigContents
                .contains("clipboard-paste-protection = true"))
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

    @Test("appearance numeric ranges are validated")
    func appearanceNumericRangesAreValidated() throws {
        let toml = Self.defaultTOML.replacing("glow_strength = 0.65", with: "glow_strength = 1.5")

        do {
            _ = try codec.decode(toml)
            Issue.record("Expected invalid value, but decode succeeded")
        } catch ConfigLoadError.invalidValue(let path, let message) {
            #expect(path == "appearance.glow_strength")
            #expect(message.contains("between 0.0 and 1.0"))
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

    @Test("empty workspace default group falls back to canonical default")
    func emptyWorkspaceDefaultGroupFallsBackToCanonicalDefault() throws {
        let toml = Self.defaultTOML.replacing(#"default_group = "awesoMux""#, with: #"default_group = "   ""#)

        let decoded = try codec.decode(toml)

        #expect(decoded.workspaces.defaultGroup == AwesoMuxConfig.defaultValue.workspaces.defaultGroup)
    }

    @Test("workspace default group stays normalized after mutation")
    func workspaceDefaultGroupStaysNormalizedAfterMutation() {
        var config = WorkspaceConfig(defaultGroup: "Support")
        config.defaultGroup = ""

        #expect(config.defaultGroup == WorkspaceConfig.defaultValue.defaultGroup)
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

    private static let v1DefaultTOML = """
        [appearance]
        theme = "system"
        accent = "peach"
        ui_font = "system"
        mono_font = "system-monospace"
        font_size = 13.0
        glow_strength = 0.65

        [notifications]
        muted = false
        sound = true
        respect_do_not_disturb = true

        [agents]
        permission_posture = "ask_every_time"
        remember_tool_trust = true

        [workspaces]
        default_group = "awesoMux"
        output_marks_needs_attention = true

        [advanced]
        config_schema_version = 1
        """

    private static let defaultTOML = """
        [general]
        restore_workspaces = true
        sidebar_compact_mode = false
        show_menu_bar_mini_status = false

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
