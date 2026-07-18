import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import Carbon.HIToolbox
import Darwin
import DesignSystem
import Foundation
import GhosttyKit
import Observation
import os
import SwiftUI

struct OpenURLAction {
    let value: String

    init(_ action: ghostty_action_open_url_s) {
        guard let url = action.url, action.len > 0 else {
            value = ""
            return
        }

        let data = Data(bytes: url, count: Int(action.len))
        value = String(data: data, encoding: .utf8) ?? ""
    }

    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "file"]

    var url: URL? {
        Self.resolve(value)
    }

    /// Pure resolution logic, split out from `url` so the scheme-allowlist +
    /// markdown gate + schemeless-path branch can be unit tested directly
    /// against plain strings — no `ghostty_action_open_url_s` C struct needed.
    static func resolve(_ value: String) -> URL? {
        guard !value.isEmpty else {
            return nil
        }

        // `candidate` only supplies the scheme check below; the schemeless
        // branch re-derives everything from raw `value`, never from
        // `candidate`. This guard still gates entry into that branch, so a
        // syntactically-invalid `URL(string:)` parse (not expected in
        // practice — Foundation's parser is very lenient) would reject an
        // otherwise-valid absolute path before it's ever considered.
        guard let candidate = URL(string: value) else {
            return nil
        }

        guard let scheme = candidate.scheme?.lowercased() else {
            // Schemeless payload: libghostty's default link regex matches bare
            // filesystem paths (not just OSC 8 file:// URIs) and hands them to
            // us with no scheme prefix at all (INT-622). Route through the
            // same markdown-only, unsafe-codepoint-gated check as the file://
            // branch below — no new capability, just a second entry point
            // into the identical gate.
            return MarkdownLinkIntercept.documentURL(forSchemelessPath: value)
        }

        // Allowlist safe schemes only. Intentionally narrower than upstream
        // Ghostty (which falls back to expanding schemeless payloads as file
        // paths and opens any schemed URL via NSWorkspace). Even with a
        // scheme, file:// can read arbitrary local files; javascript:/data:
        // execute script in the default browser; custom handlers like
        // vscode://, slack://, obsidian:// take side-effecting actions on
        // attacker-controlled payloads.
        // TODO: route disallowed schemes through a user-confirm panel that
        // shows the resolved URL and target app.
        guard Self.allowedSchemes.contains(scheme) else {
            return nil
        }

        // Scope file:// to markdown-only at the source. Non-markdown file
        // URLs (scripts, apps, binaries) are silently dropped here so they
        // never reach openURL — previously they fell through to an
        // NSWorkspace.open with no confirmation, letting an attacker-
        // controlled OSC 8 link launch arbitrary local executables on click.
        if scheme == "file" {
            return MarkdownLinkIntercept.documentURL(forFileURL: candidate)
        }

        return candidate
    }
}

extension GhosttyRuntime {
    /// Opens an externally-sourced URL through `URLClassifier` — used by OSC 8
    /// hyperlink click-through and by chrome (the Path Bar PR chip). Direct open
    /// for plain ASCII http/https, pure-single-script IDN hosts, and bare
    /// `mailto:`; block-confirm modal for mixed-script hosts (TR39 homograph
    /// risk) or undecodable punycode, embedded userinfo (the classic
    /// `user@host` phishing trick), `mailto:` with attacker-controllable
    /// prefill parameters
    /// (`to`/`body`/`cc`/`bcc`/`subject` per RFC 6068), malformed http(s) URLs
    /// missing a host, URL paths containing invisible/bidi/RTL-override
    /// codepoints, and any scheme outside the allowlist (defense-in-depth;
    /// `OpenURLAction.url` should drop most of these earlier).
    ///
    /// Modal follows INT-22's button-order + reentry-guard conventions:
    /// Cancel is the default (Return) and Esc also cancels — both wired
    /// by `AwModal`; the destructive "Open" is styled red and has no
    /// keyboard shortcut; concurrent requests are dropped while a
    /// confirm is already on screen.
    @MainActor
    static func openURL(_ url: URL) {
        // Intercept local Markdown links before URLClassifier (which would
        // pass them straight to NSWorkspace). An injected handler routes the
        // URL into the active session's document pane; if none is configured
        // (tests, early startup) fall through to the OS path.
        // Non-markdown file:// URLs never reach here — OpenURLAction.url
        // drops them at the source, so this check is both sufficient and
        // complete for all file URLs that openURL will ever receive.
        if let documentURL = MarkdownLinkIntercept.documentURL(forFileURL: url) {
            // Fail closed: if no handler is configured (startup window, teardown),
            // do nothing. The NSWorkspace fallback was removed to prevent the
            // file:// regression it re-introduced — a .md link that arrives before
            // the store binds is silently dropped, not handed to the OS.
            routeDocumentURL(documentURL)
            return
        }

        switch URLClassifier.classify(url) {
        case .openDirect:
            NSWorkspace.shared.open(url)
        case let .blockConfirm(reason, displayHost, punycodeHost):
            guard !isURLConfirmAlertPresented else { return }
            // Flip the guard before the async hop so a burst of OSC 8 opens
            // arriving while the sheet is up is dropped, not queued; it only
            // resets once the confirmation resolves.
            isURLConfirmAlertPresented = true
            Task { @MainActor in
                defer { isURLConfirmAlertPresented = false }
                if await urlOpenConfirmationProvider(url, reason, displayHost, punycodeHost) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Codepoints that have no business appearing in user-facing
    /// alert body text — ASCII C0 controls (newline, CR, NUL, tab),
    /// DEL, C1 controls (`0x80…0x9F`), Unicode line/paragraph
    /// separators, bidi formatting and isolate controls, zero-width
    /// joiners / BOM / word joiner, implicit-direction marks, and the
    /// invisible-but-non-breaking formatting codepoints (ZWNJ/ZWJ,
    /// invisible math operators, variation selectors, Hangul fillers)
    /// that can hide or homoglyph-spoof text in a confirmation preview.
    /// Each either renders as a literal line break in
    /// `NSAlert.informativeText`, reorders surrounding text in a way
    /// that defeats the bidi-isolate wrap, or vanishes entirely so the
    /// rendered string differs from what will actually be acted on.
    ///
    /// Shared by the OSC 8 hyperlink confirmation and the OSC 52
    /// clipboard-write preview (`sanitizedClipboardPreviewScalar`) — keep
    /// it the single source of truth so a future hardening can't patch
    /// one dialog and miss the other. Lives in a non-`fileprivate`
    /// extension so the bridge extension (a separate file) can reach it.
    static func isUnsafeAlertBodyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F, 0x0080...0x009F:
            return true  // C0, DEL, C1 controls
        case 0x2028, 0x2029:
            return true  // LINE SEPARATOR / PARAGRAPH SEPARATOR
        case 0x202A...0x202E:
            return true  // Bidi formatting controls (LRE/RLE/PDF/LRO/RLO)
        case 0x2066...0x2069:
            return true  // Bidi isolates (LRI/RLI/FSI/PDI)
        case 0x200E, 0x200F, 0x061C:
            return true  // LRM / RLM / Arabic letter mark
        case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x2060:
            return true  // Zero-width space / ZWNJ / ZWJ / BOM / word joiner
        case 0x2061...0x2064:
            return true  // Invisible math operators (function application, etc.)
        case 0x180E:
            return true  // Mongolian vowel separator (zero-width in modern Unicode)
        case 0xFE00...0xFE0F:
            return true  // Variation selectors (homoglyph / emoji-style spoofing)
        case 0x115F, 0x1160, 0x3164, 0xFFA0:
            return true  // Hangul / halfwidth fillers (render blank)
        default:
            return false
        }
    }

    @MainActor
    static func openURLAction(_ action: OpenURLAction, from view: GhosttySurfaceNSView) async {
        let workspaceID = view.sessionID
        let paneID = view.paneID
        guard let pane = view.sessionStore.session(id: workspaceID)?.layout.pane(id: paneID) else {
            if let url = action.url {
                openURL(url)
            }
            return
        }

        if case .ssh = pane.executionPlan, RemoteMarkdownReference.isPotentialPayload(action.value) {
            guard let reference = RemoteMarkdownReference.make(payload: action.value, pane: pane) else {
                presentRemoteMarkdownRoutingFailure(from: view)
                return
            }
            if let snapshot = await RemoteMarkdownSnapshotFetcher().fetch(reference) {
                view.sessionStore.openDocumentPane(
                    fileURL: snapshot.fileURL,
                    in: workspaceID,
                    associatedWith: paneID,
                    remoteResourceIdentity: snapshot.identity
                )
            }
            return
        }

        if let url = action.url {
            openURL(url)
            return
        }

        guard MarkdownLinkIntercept.isRelativeDocumentCandidate(action.value) else {
            return
        }

        var workingDirectory = pane.workingDirectory
        if pane.terminalBackendMetadata == AmxBackend.establishedSessionMetadata,
            let fresh = await AmxBackend.queryCwd(pane.terminalSessionID)
        {
            workingDirectory = fresh
        }
        guard
            let url = MarkdownLinkIntercept.documentURL(
                forSchemelessPath: action.value,
                relativeTo: workingDirectory
            )
        else {
            return
        }
        view.sessionStore.openDocumentPane(
            fileURL: url,
            in: workspaceID,
            associatedWith: paneID
        )
    }

    @MainActor
    private static func presentRemoteMarkdownRoutingFailure(from view: NSView) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Cannot Open Remote Markdown",
            comment: "Title for a remote Markdown path that cannot be resolved safely"
        )
        alert.informativeText = String(
            localized: "awesoMux could not establish a trusted remote path for this link.",
            comment: "Explanation for rejecting an unsafe or unresolved remote Markdown path"
        )
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

extension GhosttyRuntime {
    /// Reentry guard for the OSC 8 block-confirm. OSC 8 actions arrive via
    /// `Task { @MainActor in openURL(url) }` from a nonisolated C
    /// callback; without this flag, a terminal program emitting
    /// hyperlinks in a tight loop (or a hostile remote spraying OSC 8)
    /// can stack multiple confirmation sheets. Mirrors INT-22's
    /// `isCloseConfirmAlertPresented` pattern in
    /// `AwesoMuxApp.confirmCloseIfNeeded`.
    @MainActor
    private(set) static var isURLConfirmAlertPresented = false

    /// Injectable confirmation seam mirroring
    /// `clipboardWriteConfirmationProvider` so tests can drive the
    /// block-confirm flow without presenting UI.
    @MainActor
    static var urlOpenConfirmationProvider: @MainActor (URL, URLClassifier.BlockReason, String?, String?) async -> Bool = {
        await confirmBlockedURL($0, reason: $1, displayHost: $2, punycodeHost: $3)
    }

    @MainActor
    static func resetURLOpenConfirmationProviderForTesting() {
        urlOpenConfirmationProvider = {
            await confirmBlockedURL($0, reason: $1, displayHost: $2, punycodeHost: $3)
        }
        isURLConfirmAlertPresented = false
    }

    @MainActor
    static func alertBodyForBlockedURL(
        _ url: URL,
        reason: URLClassifier.BlockReason,
        displayHost: String?,
        punycodeHost: String?
    ) -> String {
        blockConfirmBody(
            for: url,
            reason: reason,
            displayHost: displayHost,
            punycodeHost: punycodeHost
        )
    }
}
