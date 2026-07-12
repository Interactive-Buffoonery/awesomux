public struct TerminalConfig: Codable, Equatable, Sendable {
    public enum ClipboardWritePolicy: String, Codable, CaseIterable, Sendable {
        case ask
        case allow
        case deny
    }

    /// Tri-state because Ghostty ships `copy-on-select` enabled by default on
    /// macOS. A plain on/off `Bool` would force awesoMux to always emit an
    /// override (`false` when off), silently clobbering Ghostty's native default
    /// AND any value a power user set in their own `~/.config/ghostty/config`.
    /// `.inherit` lets us emit nothing and defer to that native behavior.
    public enum CopyOnSelect: String, Codable, CaseIterable, Sendable {
        /// Defer to Ghostty's native behavior — its built-in default (on, for
        /// macOS) or whatever the user configured in their own ghostty config.
        /// awesoMux emits no `copy-on-select` line in this mode.
        case inherit
        case off
        case on

        /// Pre-INT-era configs (before #144's tri-state) stored this key as a
        /// TOML boolean. A strict enum decode would fail the whole config file
        /// and silently drop the user's settings, so accept the legacy bool;
        /// the next save rewrites the file in string form.
        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let legacy = try? container.decode(Bool.self) {
                self = legacy ? .on : .off
                return
            }
            let raw = try container.decode(String.self)
            guard let value = CopyOnSelect(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid copy_on_select value: \(raw)"
                )
            }
            self = value
        }
    }

    @TOMLDefault<DefaultClipboardWritePolicy> public var clipboardWritePolicy: ClipboardWritePolicy
    @TOMLDefault<DefaultConfirmClipboardRead> public var confirmClipboardRead: Bool
    @TOMLDefault<DefaultCopyOnSelect> public var copyOnSelect: CopyOnSelect
    @TOMLDefault<DefaultCommandBridgeEnabled> public var commandBridgeEnabled: Bool
    @TOMLDefault<DefaultDaemonIdleCapEnabled> public var daemonIdleCapEnabled: Bool
    @TOMLDefault<DefaultDaemonIdleCapMinutes> public var daemonIdleCapMinutes: Int

    public static let defaultValue = TerminalConfig()

    public init(
        clipboardWritePolicy: ClipboardWritePolicy = DefaultClipboardWritePolicy.defaultValue,
        // This default exists for TOML-decode fallback (`defaultValue` above), not as
        // a safe default for a live config-override call site — the omission it once
        // silently absorbed is INT-586's root cause. The one caller building a live
        // override (`GhosttyConfigManager.terminalConfig`) must always pass this
        // explicitly; don't add a second live-override call site that relies on it.
        confirmClipboardRead: Bool = DefaultConfirmClipboardRead.defaultValue,
        copyOnSelect: CopyOnSelect = DefaultCopyOnSelect.defaultValue,
        commandBridgeEnabled: Bool = DefaultCommandBridgeEnabled.defaultValue,
        daemonIdleCapEnabled: Bool = DefaultDaemonIdleCapEnabled.defaultValue,
        daemonIdleCapMinutes: Int = DefaultDaemonIdleCapMinutes.defaultValue
    ) {
        self.clipboardWritePolicy = clipboardWritePolicy
        self.confirmClipboardRead = confirmClipboardRead
        self.copyOnSelect = copyOnSelect
        self.commandBridgeEnabled = commandBridgeEnabled
        self.daemonIdleCapEnabled = daemonIdleCapEnabled
        self.daemonIdleCapMinutes = daemonIdleCapMinutes
    }

    enum CodingKeys: String, CodingKey {
        case clipboardWritePolicy = "clipboard_write_policy"
        case confirmClipboardRead = "confirm_clipboard_read"
        case copyOnSelect = "copy_on_select"
        case commandBridgeEnabled = "command_bridge_enabled"
        case daemonIdleCapEnabled = "daemon_idle_cap_enabled"
        case daemonIdleCapMinutes = "daemon_idle_cap_minutes"
    }
}

public struct DefaultClipboardWritePolicy: DefaultProvider {
    public static let defaultValue: TerminalConfig.ClipboardWritePolicy = .ask
}

public struct DefaultConfirmClipboardRead: DefaultProvider {
    public static let defaultValue = true
}

public struct DefaultCopyOnSelect: DefaultProvider {
    public static let defaultValue: TerminalConfig.CopyOnSelect = .inherit
}

public struct DefaultCommandBridgeEnabled: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultDaemonIdleCapEnabled: DefaultProvider {
    public static let defaultValue = false
}

public struct DefaultDaemonIdleCapMinutes: DefaultProvider {
    // 7 days. The cap is opt-in (disabled by default); this is the threshold used
    // only once the user turns it on. Minutes keep the TOML human-readable.
    public static let defaultValue = 10_080
}

public extension TerminalConfig {
    var ghosttyOverrideConfigContents: String {
        var lines = [
            "clipboard-write = \(clipboardWritePolicy.rawValue)",
            // Force-override (not the soft pre-user default in
            // GhosttyRuntimeDefaults) so the user's own ghostty config can't
            // silently re-enable OSC 52 reads behind awesoMux's confirmation
            // toggles. Mirrors clipboard-write above.
            "clipboard-read = \(confirmClipboardRead ? "ask" : "deny")",
            // Master switch for Ghostty's unsafe-paste detection (vendor/ghostty
            // Surface.zig). No app-level toggle exists for this — always-on
            // hardening. clipboard-paste-bracketed-safe is deliberately NOT
            // overridden: Ghostty's default (true) treats pastes into
            // bracketed-paste-aware programs (shells, TUIs) as safe, so the
            // confirm dialog only fires where a newline could actually execute
            // mid-paste. Forcing it false prompted on every multiline paste.
            "clipboard-paste-protection = true"
        ]
        switch copyOnSelect {
        case .inherit:
            // Emit nothing: let Ghostty's own default / the user's ghostty
            // config decide. Emitting `copy-on-select = false` here would
            // override both, which is the regression `.inherit` exists to avoid.
            break
        case .off:
            lines.append("copy-on-select = false")
        case .on:
            // macOS has no selection clipboard, so `clipboard` (system + any
            // selection clipboard) is what actually lands selections on ⌘V.
            lines.append("copy-on-select = clipboard")
        }
        // Trailing newline is load-bearing: each directive must be newline-
        // terminated so a subsequently appended override block can't glue onto
        // the last line.
        return lines.joined(separator: "\n") + "\n"
    }
}
