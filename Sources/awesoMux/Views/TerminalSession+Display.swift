import AwesoMuxCore
import DesignSystem
import Foundation

struct SidebarSessionLocation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case local
        case remote
    }

    let kind: Kind
    let displayText: String
    let searchText: String
    let identityText: String
    let accessibilityLabel: String

    static func local(_ path: String) -> SidebarSessionLocation {
        let displayText = TerminalSession.abbreviatedWorkingDirectory(path)
        return SidebarSessionLocation(
            kind: .local,
            displayText: displayText,
            searchText: displayText,
            identityText: "local:\(displayText)",
            accessibilityLabel: displayText
        )
    }

    static func remote(host: String) -> SidebarSessionLocation {
        SidebarSessionLocation(
            kind: .remote,
            displayText: host,
            searchText: host,
            identityText: "remote:\(host)",
            accessibilityLabel: "Remote session on \(host)"
        )
    }
}

extension TerminalSession {
    /// Resolved once per process because home is constant for the process lifetime.
    /// Local sidebar rendering abbreviates paths per session, per render, so repeated
    /// `FileManager` reads would be pure waste. Canonical so the prefix strip matches
    /// the canonicalized-at-ingest working directory under a symlinked home (INT-498).
    private static let homePath = WorkingDirectoryValidator.canonicalHomeDirectory

    var sidebarLocation: SidebarSessionLocation {
        let pane = activePane
        if let remoteHost = pane?.remoteHost?.nilIfBlank {
            return .remote(host: remoteHost)
        }

        return .local(pane?.workingDirectory ?? workingDirectory)
    }

    static func abbreviatedWorkingDirectory(_ workingDirectory: String) -> String {
        let homePath = Self.homePath
        guard workingDirectory == homePath || workingDirectory.hasPrefix(homePath + "/") else {
            return workingDirectory
        }

        let suffix = String(workingDirectory.dropFirst(homePath.count))
        return suffix.isEmpty ? "~" : "~" + suffix
    }

    var chromeAwState: AwState {
        effectiveChromeState.awState
    }

    /// The attention state the pane focus accent (stripe + needs-halo) and the
    /// horizontal-split divider absorb should paint. Folds the INT-650 acknowledge
    /// ledger into `.needs` so the focus rail stays peach for exactly as long as
    /// the `NeedsInputBar` (gated on `needsAcknowledgement`) is up — even after the
    /// execution rollup leaves `.needs` (a dead pane keeping a low-priority
    /// `attentionReason` reads as its recovery hint, not `.needsAttention`, per
    /// INT-506). Keeps the stripe and the banner in visual agreement (INT-721).
    /// Deliberately NOT `chromeAwState`'s replacement: group-by-state counts and
    /// per-pane execution display must keep reading the raw rollup, not this fold.
    var focusAccentAwState: AwState {
        needsAcknowledgement ? .needs : chromeAwState
    }

    /// Everything the sidebar peek card renders, as an `Equatable` key for
    /// `onChange`. `TerminalSession`/`TerminalPane` `==` deliberately exclude the
    /// runtime-only `shellActivity`, so an idle↔busy shell flip is invisible to
    /// `onChange(of: session)` and would strand an open peek with a stale state.
    /// This key folds the rollup (which collapses `shellActivity` into the chrome
    /// state) so the live peek refreshes when any displayed field changes (S4).
    var peekRefreshKey: SidebarSessionPeekRefreshKey {
        // The multi-pane card renders one row per pane, so the key must fold
        // EACH pane's render state — not just the session aggregate. Two needy
        // panes can hold the aggregate at `.needs` while one of them goes idle;
        // keying on the aggregate alone would strand that pane's row stale
        // (538). `paneItems` already captures per-pane state/unread/active/icon,
        // and the aggregate header is derived from the same panes, so this key
        // fully determines the rendered card. Title + location stay explicit
        // (session title and the active pane's cwd/host aren't in the rows).
        SidebarSessionPeekRefreshKey(
            title: title,
            locationText: sidebarLocation.displayText,
            paneItems: PanePeekItem.items(for: self)
        )
    }
}

/// The peek card's render-relevant projection. Distinct from `TerminalSession`
/// equality because it folds each pane's `shellActivity`-derived chrome state
/// (S4) via `paneItems`, so a per-pane flip invisible to `==` still refreshes
/// an open card.
struct SidebarSessionPeekRefreshKey: Equatable {
    let title: String
    let locationText: String
    let paneItems: [PanePeekItem]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
