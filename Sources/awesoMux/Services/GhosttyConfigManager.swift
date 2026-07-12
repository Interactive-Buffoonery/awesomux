import AppKit
import AwesoMuxConfig
import DesignSystem
import Foundation
import GhosttyKit
import os
import SwiftUI

/// Owns libghostty config generation: layering awesoMux's generated overlays
/// (defaults, terminal, appearance) onto a fresh `ghostty_config_t`, finalizing
/// it, and reading back the resolved background color. Extracted from
/// `GhosttyRuntime` (INT-559) so the coordinator stays thin and the
/// most self-contained, best-covered concern lives behind one seam.
///
/// The manager performs no side effects on the runtime: `build` returns a
/// `Result` the coordinator applies (free the config it owns, mark failed,
/// adopt the background color). Ownership of the returned `ghostty_config_t`
/// transfers to the caller.
///
/// Requires `ghostty_init` to have already run in the process — `ghostty_config_new`
/// segfaults otherwise. `GhosttyRuntime` guarantees this before constructing a
/// manager, matching the prior in-class behavior.
@MainActor
struct GhosttyConfigManager {
    /// Mirrors the prior in-runtime failure policy: a best-effort overlay
    /// tolerates rejection, a required overlay abandons (silently on re-apply,
    /// or with a runtime-failing message on init).
    enum ConfigLoadFailureMode {
        case failRuntime
        case logWarning
        case ignore
    }

    /// What to do when a generated config overlay fails to apply — either the temp
    /// file couldn't be written, or libghostty rejected one of our keys (which
    /// `ghostty_config_load_file` only signals via a diagnostic, never a return code).
    enum ConfigOverlayFailureResolution: Equatable {
        /// Best-effort overlay: keep building the config.
        case tolerate
        /// Required overlay on a live re-apply: drop this config, leave the running
        /// runtime untouched.
        case abandon
        /// Required overlay on init: drop this config and mark the runtime failed.
        case abandonAndFail
    }

    /// Outcome of a `build`. Preserves the three prior return states exactly:
    /// a finalized config (with the background color read back, `nil` when the
    /// key was absent so the caller keeps its prior value); a hard failure
    /// carrying the verbatim message the runtime should surface; or a silent
    /// abandonment (a required overlay failed on a non-init re-apply).
    enum BuildResult {
        case built(config: ghostty_config_t, backgroundColor: NSColor?)
        case failed(message: String)
        case abandonedSilently
    }

    /// Raw values are bit flags matching Ghostty's internal `u32`
    /// `shell-integration-features` value.
    enum ShellIntegrationFeature: UInt32, CaseIterable {
        case cursor = 1
        case sudo = 2
        case title = 4
        case sshEnv = 8
        case sshTerminfo = 16
        case path = 32

        var configName: String {
            switch self {
            case .cursor: return "cursor"
            case .sudo: return "sudo"
            case .title: return "title"
            case .sshEnv: return "ssh-env"
            case .sshTerminfo: return "ssh-terminfo"
            case .path: return "path"
            }
        }

        var isUnsupportedSSHHelper: Bool {
            switch self {
            case .sshEnv, .sshTerminfo: return true
            case .cursor, .sudo, .title, .path: return false
            }
        }

        func isEnabled(in rawFeatures: UInt32) -> Bool {
            rawFeatures & rawValue != 0
        }
    }

    nonisolated static func overlayFailureResolution(
        for failureMode: ConfigLoadFailureMode
    ) -> ConfigOverlayFailureResolution {
        switch failureMode {
        case .logWarning: return .tolerate
        case .ignore: return .abandon
        case .failRuntime: return .abandonAndFail
        }
    }

    nonisolated private static let configLoadLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "GhosttyConfigLoad"
    )

#if DEBUG
    // Category intentionally kept as the pre-extraction "GhosttyRuntimeMemory"
    // so finalized-config diagnostic lines stay on the same log stream they
    // shipped on; renaming it would silently split historical captures.
    nonisolated private static let diagnosticsLogger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "GhosttyRuntimeMemory"
    )
#endif

    let clipboardWritePolicy: TerminalConfig.ClipboardWritePolicy
    let confirmClipboardRead: Bool
    let copyOnSelect: TerminalConfig.CopyOnSelect
    let terminalAppearance: TerminalAppearancePreferences

    /// The `TerminalConfig` this manager builds its terminal overlay from.
    /// `internal` (not `private`) so a test can assert the constructor's
    /// clipboard/copy-on-select values actually reach the overlay text
    /// `build()` loads, rather than only re-testing `TerminalConfig` itself.
    var terminalConfig: TerminalConfig {
        TerminalConfig(
            clipboardWritePolicy: clipboardWritePolicy,
            confirmClipboardRead: confirmClipboardRead,
            copyOnSelect: copyOnSelect
        )
    }

    /// Builds the full layered config. `reportFailures` is `true` on init (a
    /// required-overlay rejection becomes a `.failed` runtime), `false` on a live
    /// re-apply (a rejection becomes `.abandonedSilently`, leaving the running
    /// runtime untouched).
    func build(reportFailures: Bool) -> BuildResult {
        guard let config = ghostty_config_new() else {
            return reportFailures
                ? .failed(message: "ghostty_config_new failed")
                : .abandonedSilently
        }

        loadConfigContents(
            GhosttyRuntimeDefaults.defaultConfigContents,
            into: config,
            filePrefix: "awesomux-ghostty-defaults",
            failureMode: .logWarning
        )

        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)

        let requiredFailureMode: ConfigLoadFailureMode = reportFailures ? .failRuntime : .ignore
        var overlays: [(contents: String, prefix: String)] = []
        if let contents = Self.shellIntegrationConfigContentsDisablingUnsupportedSSHHelpers(from: config) {
            overlays.append((
                contents: contents,
                prefix: "awesomux-ghostty-shell-integration"
            ))
        }
        overlays.append(contentsOf: [
            (
                contents: terminalConfig.ghosttyOverrideConfigContents,
                prefix: "awesomux-ghostty-terminal"
            ),
            (
                contents: terminalAppearance.ghosttyOverrideConfigContents,
                prefix: "awesomux-ghostty-appearance"
            ),
            (
                contents: Self.searchHighlightConfigContents(for: terminalAppearance.effectiveTheme),
                prefix: "awesomux-ghostty-search"
            )
        ])
        for overlay in overlays {
            switch loadOverlay(
                overlay.contents,
                into: config,
                filePrefix: overlay.prefix,
                failureMode: requiredFailureMode
            ) {
            case .applied:
                continue
            case .failed(let message):
                ghostty_config_free(config)
                return .failed(message: message)
            case .abandoned:
                ghostty_config_free(config)
                return .abandonedSilently
            }
        }

        ghostty_config_finalize(config)
        logConfigDiagnostics(config)
        return .built(config: config, backgroundColor: resolvedBackgroundColor(from: config))
    }

    nonisolated static func shellIntegrationConfigContentsDisablingUnsupportedSSHHelpers(
        from config: ghostty_config_t
    ) -> String? {
        guard let rawFeatures = rawShellIntegrationFeatures(from: config) else { return nil }
        return shellIntegrationConfigContents(
            disablingUnsupportedSSHHelpersFrom: rawFeatures
        )
    }

    nonisolated static func rawShellIntegrationFeatures(from config: ghostty_config_t) -> UInt32? {
        var rawFeatures: CUnsignedInt = 0
        let key = "shell-integration-features"
        let found = key.withCString { keyPointer in
            ghostty_config_get(config, &rawFeatures, keyPointer, UInt(key.utf8.count))
        }
        return found ? UInt32(rawFeatures) : nil
    }

    nonisolated static func shellIntegrationConfigContents(
        disablingUnsupportedSSHHelpersFrom rawFeatures: UInt32
    ) -> String {
        let values = ShellIntegrationFeature.allCases.map { feature in
            let enabled = feature.isUnsupportedSSHHelper
                ? false
                : feature.isEnabled(in: rawFeatures)
            return enabled ? feature.configName : "no-\(feature.configName)"
        }
        return "shell-integration-features = \(values.joined(separator: ","))\n"
    }

    nonisolated static func searchHighlightConfigContents(
        for theme: TerminalAppearancePreferences.EffectiveTheme
    ) -> String {
        let colorScheme: AwColors.SearchHighlightColorScheme
        let candidateForeground: String
        switch theme {
        case .dark:
            colorScheme = .dark
            candidateForeground = "#12121c"
        case .light:
            colorScheme = .light
            candidateForeground = "#ffffff"
        }
        let hex = Color.aw.searchHighlightHex(theme: colorScheme)

        return """
        search-foreground = \(candidateForeground)
        search-background = \(hex.background)
        search-selected-foreground = #12121c
        search-selected-background = \(hex.selectedBackground)

        """
    }

    /// Read the resolved `background` color out of the finalized config so the
    /// over-terminal focus stripe can contrast against the real surface color,
    /// not the app chrome (INT-285). libghostty has already merged themes,
    /// includes, and palette references by `ghostty_config_finalize`, so this is
    /// the true painted background. Returns `nil` when the key is absent so the
    /// caller keeps its prior value.
    private func resolvedBackgroundColor(from config: ghostty_config_t) -> NSColor? {
        var color = ghostty_config_color_s()
        let key = "background"
        // `withCString` keeps the C key buffer alive only for the closure;
        // `ghostty_config_get` is synchronous and does not retain it (the length
        // arg is the key length, not a value-buffer size — libghostty writes the
        // fixed 3-byte color struct), so the pointer can't dangle.
        let found = key.withCString { keyPointer in
            ghostty_config_get(config, &color, keyPointer, UInt(key.utf8.count))
        }
        guard found else { return nil }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }

#if DEBUG
    private func logConfigDiagnostics(_ config: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return }
        for index in 0..<count {
            let diag = ghostty_config_get_diagnostic(config, index)
            if let message = diag.message.map({ String(cString: $0) }) {
                Self.diagnosticsLogger.debug("ghostty config diagnostic: \(message, privacy: .public)")
            }
        }
    }
#else
    private func logConfigDiagnostics(_ config: ghostty_config_t) {}
#endif

    /// Outcome of loading one overlay: it applied, it was abandoned silently
    /// (required overlay on a re-apply), or it failed with the verbatim message
    /// the runtime surfaces (required overlay on init).
    enum OverlayLoadOutcome: Equatable {
        case applied
        case abandoned
        case failed(message: String)
    }

    /// `internal` so the fail-closed-on-rejected-overlay behavior can be unit
    /// tested directly with an injected bad key — the one config failure path
    /// reachable in a test. The Bool reports whether the overlay applied, which
    /// is all the best-effort defaults overlay needs.
    @discardableResult
    func loadConfigContents(
        _ contents: String,
        into config: ghostty_config_t,
        filePrefix: String,
        failureMode: ConfigLoadFailureMode
    ) -> Bool {
        loadOverlay(contents, into: config, filePrefix: filePrefix, failureMode: failureMode) == .applied
    }

    // TODO(INT-389): replace with a direct `ghostty_config_load_string`
    // call once libghostty upstream exposes one. The temp-file dance is
    // CWE-377-adjacent and adds two synchronous main-actor disk writes
    // per config build.
    private func loadOverlay(
        _ contents: String,
        into config: ghostty_config_t,
        filePrefix: String,
        failureMode: ConfigLoadFailureMode
    ) -> OverlayLoadOutcome {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)-\(UUID().uuidString).conf")

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            let firstNewDiagnosticIndex = ghostty_config_diagnostics_count(config)
            url.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
            // `ghostty_config_load_file` returns void; a key it rejects surfaces only
            // as a diagnostic. These overlays are awesoMux-generated (never user
            // config), so any new diagnostic means our own overlay was rejected — fail
            // closed for required overlays so a renamed/removed key (e.g.
            // `clipboard-write`) can't silently fall back to libghostty's default.
            let overlayRejected = logNewConfigDiagnostics(
                config,
                startingAt: firstNewDiagnosticIndex,
                source: filePrefix
            )
            guard overlayRejected else { return .applied }
            return resolveOverlayFailure(
                failureMode,
                source: filePrefix,
                reason: "rejected by libghostty"
            )
        } catch {
            if case .logWarning = failureMode {
                Self.configLoadLogger.warning(
                    "awesoMux Ghostty config load failed source=\(filePrefix, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
            return resolveOverlayFailure(
                failureMode,
                source: filePrefix,
                reason: error.localizedDescription
            )
        }
    }

    private func resolveOverlayFailure(
        _ failureMode: ConfigLoadFailureMode,
        source: String,
        reason: String
    ) -> OverlayLoadOutcome {
        switch Self.overlayFailureResolution(for: failureMode) {
        case .tolerate:
            return .applied
        case .abandon:
            return .abandoned
        case .abandonAndFail:
            return .failed(message: "awesoMux Ghostty config load failed source=\(source): \(reason)")
        }
    }

    /// Logs every diagnostic libghostty appended since `firstNewDiagnosticIndex` and
    /// returns whether any were appended (i.e. whether this overlay was rejected).
    @discardableResult
    private func logNewConfigDiagnostics(
        _ config: ghostty_config_t,
        startingAt firstNewDiagnosticIndex: UInt32,
        source: String
    ) -> Bool {
        let count = ghostty_config_diagnostics_count(config)
        guard count > firstNewDiagnosticIndex else { return false }

        for index in firstNewDiagnosticIndex..<count {
            let diag = ghostty_config_get_diagnostic(config, index)
            // Log a sentinel for a null/empty message so the diagnostic count and the
            // logged lines stay reconcilable.
            let message = diag.message.map { String(cString: $0) } ?? "<no message>"
            Self.configLoadLogger.warning(
                "ghostty config diagnostic source=\(source, privacy: .public) message=\(message, privacy: .public)"
            )
        }
        return true
    }
}
