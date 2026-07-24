import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Carbon.HIToolbox
import Darwin
import DesignSystem
import Foundation
import GhosttyKit
import Observation
import SwiftUI
import os

extension GhosttyRuntime {
    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else {
            return
        }

        let runtime = Unmanaged<GhosttyRuntime>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        runtime.wakeupCoalescer.schedule {
            Task { @MainActor in
                runtime.wakeupCoalescer.clearPending()
                runtime.tick()
            }
        }
    }

    nonisolated static func action(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SECURE_INPUT:
            guard let view = surfaceView(from: target),
                let mode = secureInputMode(action.action.secure_input)
            else {
                return false
            }

            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_SECURE_INPUT fired off-main — the " + "secure_input callback assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.runtime.applySecureInput(mode, for: view.paneID)
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let view = surfaceView(from: target),
                let titlePointer = action.action.set_title.title
            else {
                return false
            }

            let title = String(cString: titlePointer)
            // A `Task` here leaves a gap for `update(session:pane:)` to repoint
            // this view at a different pane before the write lands — same race
            // INT-587 fixed for GHOSTTY_ACTION_PROGRESS_REPORT below (INT-608).
            // OSC 0/2 (title) is parsed from PTY output like OSC 9;4 (progress),
            // so it shares that case's ghostty_app_tick-only assumption too.
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_SET_TITLE fired off-main — the ghostty_app_tick-only assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateTerminalTitle(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target),
                let pwdPointer = action.action.pwd.pwd
            else {
                return false
            }

            let workingDirectory = String(cString: pwdPointer)
            // Same pane-recycle race as GHOSTTY_ACTION_SET_TITLE above (INT-608).
            // OSC 7 (pwd) is parsed from PTY output like OSC 9;4 (progress), so
            // it shares that case's ghostty_app_tick-only assumption too.
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_PWD fired off-main — the ghostty_app_tick-only assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateWorkingDirectory(workingDirectory)
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            guard let view = surfaceView(from: target) else {
                return false
            }

            // `markNeedsAttention` shares INT-608's live-identity read, but
            // stays on `Task` (not `onMainThreadSynchronously`) because it
            // writes the same `unreadNotificationCount`/attention fields as
            // GHOSTTY_ACTION_COMMAND_FINISHED's `applyDetectedAgentState`
            // path, which is ALSO still `Task`-dispatched (see that case
            // below for why). Converting only THIS case to a synchronous
            // bridge would deterministically jump it ahead of an
            // earlier-fired, still-queued COMMAND_FINISHED, letting a stale
            // command-finished clear a just-applied notification. Matching
            // dispatch styles removes that new, deterministic inversion, but
            // does NOT itself guarantee FIFO order between separate `Task`s
            // on the same actor — that ordering hazard predates this PR and
            // isn't fixed here. A real fix needs explicit
            // sequencing/serialization for these three cases together, not
            // just matching Task-vs-sync — tracked as a follow-up.
            Task { @MainActor in
                // `workspaces.output_marks_needs_attention = false` means
                // "don't mark sessions as needing attention from output."
                // Honor the setting at the bell entry point so the
                // sidebar indicator + Dock badge stay quiet too —
                // previously only the macOS banner was gated.
                guard view.runtime.shouldOutputMarkAttention else { return }
                view.markNeedsAttention()
            }
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let notification = action.action.desktop_notification
            let title = notification.title.map(String.init(cString:)) ?? ""
            let body = notification.body.map(String.init(cString:)) ?? ""

            // Same COMMAND_FINISHED ordering constraint as GHOSTTY_ACTION_RING_BELL
            // above — stays on `Task` (see that case's comment).
            Task { @MainActor in
                switch Self.desktopNotificationEffect(
                    title: title,
                    body: body,
                    outputMarksAttention: view.runtime.shouldOutputMarkAttention
                ) {
                case .ignore:
                    break
                case .markNeedsAttention:
                    view.markNeedsAttention()
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let link = string(
                pointer: action.action.mouse_over_link.url,
                length: action.action.mouse_over_link.len
            )
            Task { @MainActor in
                view.updateMouseOverLink(link)
                if let link, !link.isEmpty {
                    view.sessionStore.recordRecentTerminalLink(
                        sessionID: view.sessionID,
                        paneID: view.paneID,
                        value: link
                    )
                }
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let shape = action.action.mouse_shape
            Task { @MainActor in
                view.setCursorShape(shape)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let visibility = action.action.mouse_visibility
            Task { @MainActor in
                switch visibility {
                case GHOSTTY_MOUSE_VISIBLE:
                    view.setCursorVisibility(true)
                case GHOSTTY_MOUSE_HIDDEN:
                    view.setCursorVisibility(false)
                default:
                    break
                }
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let urlAction = OpenURLAction(action.action.open_url)
            if let view = surfaceView(from: target) {
                Task { @MainActor in
                    await openURLAction(urlAction, from: view)
                }
                return true
            }

            // Phase 1 — unchanged fast path: schemed URLs and absolute
            // schemeless paths resolve synchronously, and rejected payloads
            // (disallowed schemes, non-markdown files) stay as cheap as ever.
            if let url = urlAction.url {
                Task { @MainActor in
                    openURL(url)
                }
                return true
            }

            // Phase 2 — relative markdown candidates (INT-740): bridge panes
            // never emit OSC 7, so libghostty's own pwd resolution
            // (`Surface.resolvePathForOpening`) can't run and it hands us the
            // raw relative string. Resolve against the pane's cwd — queried
            // fresh from the amx daemon for bridge panes, since the stored
            // value is only polled while the pane is selected.
            //
            // Claim the action (return true) even when the payload is dropped.
            // Returning false makes libghostty run its own fallback opener
            // (`Surface.openUrl` → `internal_os.open` → `open <payload>`),
            // which bypasses this allowlist entirely — a rejected scheme or
            // non-markdown path would still launch its handler app.
            return true

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let exitCode = action.action.command_finished.exit_code
            // KNOWN remaining gap (INT-608 follow-up, not an oversight):
            // `handleCommandFinished` reads live `sessionID`/`paneID` and can
            // write the same attention fields GHOSTTY_ACTION_RING_BELL /
            // GHOSTTY_ACTION_DESKTOP_NOTIFICATION do, so it shares this
            // codebase's pane-recycle race in principle. Left on `Task`
            // rather than `onMainThreadSynchronously` because its synchronous
            // call graph (`refreshShellActivity` → `shellActivitySnapshot()`)
            // reaches native libghostty calls on OTHER surfaces
            // (`ghostty_surface_needs_confirm_quit`), which is unproven safe
            // to invoke from inside this surface's own `action_cb` — that
            // needs its own investigation. The bell/notification cases above
            // stay Task-dispatched to match this one and avoid a NEW,
            // deterministic ordering inversion — but matching dispatch
            // styles alone doesn't guarantee FIFO order between separate
            // `Task`s on the same actor, so the pre-existing race between
            // all three isn't fixed either. A real fix needs explicit
            // sequencing/serialization across all three together.
            Task { @MainActor in
                view.handleCommandFinished(exitCode: exitCode)
            }
            return true

        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let progressReport = SurfaceProgressReport(
                action.action.progress_report
            ).terminalProgressReport
            // Dispatch SYNCHRONOUSLY via `onMainThreadSynchronously`, not `Task { @MainActor }`.
            // `Task` queues and returns immediately, leaving a gap where
            // `update(session:pane:...)` can re-point this same, still-alive
            // view at a DIFFERENT pane before the queued work runs — `[weak
            // view]` only guards deallocation, not that in-place repoint, so
            // the write would land on the wrong pane's store entry. A
            // synchronous call has no such gap: this dispatch either runs to
            // completion before `action()` returns, or (off-main) blocks the
            // caller until it does — either way nothing else can run on the
            // main actor in between to reassign `view.paneID`.
            //
            // This is provably safe from both deadlock and the "read
            // MainActor state from a nonisolated context" compile error that
            // sank the prior attempt at this — SCOPED to progress-report
            // specifically, not every `GHOSTTY_ACTION_*` tag: `action_cb`
            // also fires synchronously from `ghostty_app_update_config` /
            // `ghostty_app_set_color_scheme` / `ghostty_surface_binding_action`,
            // none of which funnel through `ghostty_app_tick`. But OSC 9;4
            // progress reports are parsed from PTY output and only ever reach
            // `action_cb` via the surface-message mailbox that `ghostty_app_tick`
            // drains — and this codebase calls `ghostty_app_tick` ONLY from
            // inside `Task { @MainActor in }` in `wakeup(_:)` (see
            // `GhosttyWakeupCoalescer`'s doc comment above `tick()`). So
            // *this* case is always already running on the main thread —
            // `onMainThreadSynchronously`'s `Thread.isMainThread` fast path handles it
            // inline via `MainActor.assumeIsolated`, and the
            // `DispatchQueue.main.sync` fallback (the one flagged as
            // deadlock-prone in `GhosttyRuntime.deinit`'s comment, for an
            // unrelated off-main retain path) should never actually execute
            // in this codebase's current call graph. If it ever does — a
            // future libghostty change routes progress reports through one
            // of the other, non-tick `action_cb` entry points above — the
            // assertion below fails loudly in DEBUG rather than letting a
            // wrong-thread assumption degrade silently into an occasional
            // `.sync` hop (or, worse, a deadlock if that path ever holds a
            // lock this hop would contend with).
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_PROGRESS_REPORT fired off-main — the " + "ghostty_app_tick-only assumption above no longer holds"
            )
            onMainThreadSynchronously {
                view.updateProgressReport(progressReport)
            }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let cellSize = action.action.cell_size
            Task { @MainActor in
                view.updateCellSize(
                    backingWidth: Double(cellSize.width),
                    backingHeight: Double(cellSize.height)
                )
            }
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let scrollbar = action.action.scrollbar
            Task { @MainActor in
                view.updateScrollbar(
                    total: scrollbar.total,
                    offset: scrollbar.offset,
                    length: scrollbar.len
                )
            }
            return true

        case GHOSTTY_ACTION_SELECTION_CHANGED:
            guard let view = surfaceView(from: target) else {
                return false
            }

            Task { @MainActor in
                view.scheduleAccessibilitySelectionChangeAnnouncement()
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let needle = action.action.start_search.needle.map(String.init(cString:))
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_START_SEARCH fired off-main — the " + "start_search binding-action callback assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateSearchStarted(needle: needle)
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = surfaceView(from: target) else {
                return false
            }

            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_END_SEARCH fired off-main — the " + "end_search binding-action callback assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateSearchEnded()
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let total = Int(action.action.search_total.total)
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_SEARCH_TOTAL fired off-main — the " + "ghostty_app_tick-only assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateSearchTotal(total)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = surfaceView(from: target) else {
                return false
            }

            let selected = Int(action.action.search_selected.selected)
            assert(
                Thread.isMainThread,
                "GHOSTTY_ACTION_SEARCH_SELECTED fired off-main — the " + "ghostty_app_tick-only assumption no longer holds"
            )
            onMainThreadSynchronously {
                view.updateSearchSelected(selected)
            }
            return true

        case GHOSTTY_ACTION_RENDERER_HEALTH,
            GHOSTTY_ACTION_SIZE_LIMIT,
            GHOSTTY_ACTION_QUIT_TIMER:
            return true

        default:
            return Self.shouldClaimIgnoredGhosttyApplicationAction(action.tag)
        }
    }

    nonisolated static func string(
        pointer: UnsafePointer<CChar>?,
        length: Int
    ) -> String? {
        guard let pointer, length > 0 else {
            return nil
        }

        let data = Data(bytes: pointer, count: length)
        return String(data: data, encoding: .utf8)
    }

    /// Closure wired by `AppDelegate.bind` to route `file://*.md` clicks into
    /// the active session's document pane. Kept as a `static` because `openURL`
    /// is a `static @MainActor func` with no access to an instance. `@MainActor`
    /// isolation matches `openURL` and `AppDelegate.bind`, so no additional
    /// synchronisation is needed.
    @MainActor
    private static var openDocumentHandler: ((URL) -> Void)?

    @MainActor
    static func setOpenDocumentHandler(_ handler: ((URL) -> Void)?) {
        openDocumentHandler = handler
    }

    @MainActor
    static func routeDocumentURL(_ url: URL) {
        openDocumentHandler?(url)
    }

    /// Maximum URL string length displayed in the modal body. Pasted
    /// or attacker-crafted multi-kilobyte URLs would otherwise blow out
    /// the dialog layout.
    private static let urlBodyDisplayCap = 200

    /// Maximum length for any user-controllable substring interpolated
    /// into the alert body (workspace title, mailto recipient,
    /// userinfo, etc.). Prevents a single field from dominating the
    /// dialog or pushing other lines off-screen.
    private static let bodyFieldDisplayCap = 120

    /// Sanitizes a user-controllable substring before interpolation
    /// into `NSAlert.informativeText`. Replaces every codepoint that
    /// could forge a line-break, line-direction flip, or invisible
    /// gap in the dialog body with a single space — Foundation's
    /// percent-decoding of URL components turns `%0A` (LF),
    /// `%E2%80%A8` (LINE SEPARATOR `U+2028`), `%E2%80%A9` (PARAGRAPH
    /// SEPARATOR `U+2029`), `%E2%80%AE` (RTL OVERRIDE), etc. into
    /// their literal codepoints, any of which would render as a fake
    /// line break or directional flip in the dialog and let an
    /// attacker forge a "Full URL: https://safe.example" line that
    /// hides the real resolved host. Truncates to
    /// `bodyFieldDisplayCap` at the end.
    private static func sanitizedForAlertBody(_ value: String) -> String {
        let scrubbed = value.unicodeScalars.map { scalar -> Character in
            if isUnsafeAlertBodyScalar(scalar) {
                return " "
            }
            return Character(scalar)
        }
        let oneLine = String(scrubbed)
        return oneLine.count > bodyFieldDisplayCap
            ? String(oneLine.prefix(bodyFieldDisplayCap)) + "…"
            : oneLine
    }

    @MainActor
    static func confirmBlockedURL(
        _ url: URL,
        reason: URLClassifier.BlockReason,
        displayHost: String?,
        punycodeHost: String?
    ) async -> Bool {
        // When the Unicode and punycode forms of an IDN host differ, the
        // pair moves out of the body into a dedicated comparison view so
        // the spoofable form and the resolved form sit side by side.
        let hostComparison: (display: String, punycode: String)? = {
            guard reason == .nonAsciiHost,
                let display = displayHost,
                let puny = punycodeHost,
                display != puny
            else { return nil }
            return (sanitizedForAlertBody(display), sanitizedForAlertBody(puny))
        }()

        // The comparison rides as the alert's accessory view so it spans the
        // dialog's content width below the body copy. NSAlert sizes itself
        // to the accessory frame; the width cap keeps a 120-char sanitized
        // host wrapping instead of stretching the alert across the screen.
        let accessoryView: NSView? = hostComparison.map { pair in
            let hosting = NSHostingView(
                rootView: BlockedURLHostComparisonView(
                    displayHost: pair.display,
                    punycodeHost: pair.punycode
                )
                .frame(maxWidth: 400)
                .awUIFont(AwUIFontRuntime.current)
            )
            hosting.setFrameSize(hosting.fittingSize)
            return hosting
        }

        // Presented through NSAlert.confirmDestructive — the same dialog as
        // every other destructive confirm in the app (live-smoke direction:
        // no bespoke chrome for this surface). That path already wires
        // Cancel as the default button (Return and Esc both cancel), marks
        // Open destructive, and installs the scoped ⌘Return accept monitor
        // (NSAlert.layout() strips Return-family keyEquivalents from
        // destructive buttons, so the monitor stays load-bearing). Title
        // keeps the "Security warning:" prefix so VoiceOver gets an audible
        // cue this is a security gate even when the punycode hostname is
        // pronounced fluently by TTS.
        return NSAlert.confirmDestructive(
            title: String(
                localized: "Security warning: \(blockConfirmTitle(for: reason))",
                comment: "Outer wrapper for the OSC 8 confirmation dialog title. Inner argument is the reason-specific question."
            ),
            body: blockConfirmBody(
                for: url,
                reason: reason,
                displayHost: displayHost,
                punycodeHost: punycodeHost,
                includeHostLines: hostComparison == nil
            ),
            keyboardHint: String(
                localized: "Press ⌘Return to open. Return or Esc cancels.",
                comment: "Keyboard hint line on the OSC 8 hyperlink confirmation dialog."
            ),
            destructiveTitle: String(
                localized: "Open",
                comment: "Destructive button on the OSC 8 hyperlink confirmation dialog. Opens the URL in the default handler."
            ),
            cancelTitle: String(
                localized: "Cancel",
                comment: "Default button on the OSC 8 hyperlink confirmation dialog. Cancels the open."
            ),
            destructiveAccessibilityLabel: String(
                localized: "Open URL anyway",
                comment:
                    "VoiceOver label for the destructive Open button on the OSC 8 hyperlink confirmation dialog. More descriptive than the visual 'Open' so a user who tabs to the button still has context."
            ),
            cancelAccessibilityLabel: String(
                localized: "Cancel and do not open URL",
                comment:
                    "VoiceOver label for the Cancel button on the OSC 8 hyperlink confirmation dialog. More descriptive than the visual 'Cancel' so a user who tabs to the button still has context."
            ),
            accessoryView: accessoryView
        )
    }

    private static func blockConfirmTitle(for reason: URLClassifier.BlockReason) -> String {
        switch reason {
        case .nonAsciiHost:
            String(
                localized: "Open URL with an unverified host?",
                comment:
                    "OSC 8 dialog title segment when the URL's host mixes confusable scripts, is a whole-script confusable, or has undecodable punycode."
            )
        case .embeddedUserInfo:
            String(
                localized: "Open URL with embedded login info?",
                comment: "OSC 8 confirmation dialog title segment when the URL has a `user@host` prefix that may disguise the real host."
            )
        case .missingHost:
            String(
                localized: "Open malformed URL?",
                comment: "OSC 8 confirmation dialog title segment when the URL parsed but has no host component."
            )
        case .pathHasUnsafeCodepoints:
            String(
                localized: "Open URL with hidden characters?",
                comment:
                    "OSC 8 confirmation dialog title segment when the URL path contains bidi-override / zero-width / control codepoints."
            )
        case .mailtoWithParameters:
            String(
                localized: "Open prefilled email?",
                comment: "OSC 8 confirmation dialog title segment when a mailto URL has prefill parameters."
            )
        case .disallowedScheme:
            String(
                localized: "Open URL with non-standard scheme?",
                comment: "OSC 8 confirmation dialog title segment when the URL's scheme is outside http/https/mailto."
            )
        }
    }

    static func blockConfirmBody(
        for url: URL,
        reason: URLClassifier.BlockReason,
        displayHost: String?,
        punycodeHost: String?,
        includeHostLines: Bool = true
    ) -> String {
        var lines: [String] = []
        switch reason {
        case .nonAsciiHost:
            if let display = displayHost,
                let puny = punycodeHost,
                display != puny
            {
                // Skipped when the modal shows the dedicated host
                // comparison view instead of these text lines.
                if includeHostLines {
                    lines.append(
                        String(
                            localized: "Display: \u{2068}\(Self.sanitizedForAlertBody(display))\u{2069}",
                            comment:
                                "Line of the OSC 8 confirmation dialog body showing the Unicode form of an IDN host. Argument is bidi-isolated."
                        ))
                    lines.append(
                        String(
                            localized: "Resolves to: \(Self.sanitizedForAlertBody(puny))",
                            comment:
                                "Line of the OSC 8 confirmation dialog body showing the punycode form an IDN host actually resolves to."
                        ))
                }
            } else if let display = displayHost ?? punycodeHost {
                lines.append("\u{2068}\(Self.sanitizedForAlertBody(display))\u{2069}")
            } else {
                // Unreachable from URLClassifier (both-nil hosts return
                // .missingHost before .nonAsciiHost) — defensive copy for
                // direct callers only.
                lines.append(
                    String(
                        localized: "This URL's host could not be verified.",
                        comment: "Fallback body line when host accessors are unavailable but the URL's host was flagged as suspicious."
                    ))
            }
        case .embeddedUserInfo:
            // Surface BOTH the deceptive prefix (userinfo) AND the
            // actual host. `URLComponents.user` / `.password` are
            // percent-decoded, so `%0A` becomes a literal newline that
            // would otherwise inject forged lines into this dialog —
            // `sanitizedForAlertBody` strips controls before
            // interpolation. Bidi isolates wrap the result so a
            // non-ASCII userinfo can't reorder the surrounding template.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let user = components?.user ?? ""
            let password = components?.password ?? ""
            let visiblePrefix: String
            if !password.isEmpty {
                visiblePrefix = user.isEmpty ? ":\(password)" : "\(user):\(password)"
            } else {
                visiblePrefix = user
            }
            lines.append(
                String(
                    localized: "Visible prefix: \u{2068}\(Self.sanitizedForAlertBody(visiblePrefix))\u{2069}",
                    comment:
                        "Line of the OSC 8 confirmation dialog body showing the bidi-isolated `user@` prefix that disguises the real host."
                ))
            if let host = displayHost {
                lines.append(
                    String(
                        localized: "Actual host: \u{2068}\(Self.sanitizedForAlertBody(host))\u{2069}",
                        comment:
                            "Line of the OSC 8 confirmation dialog body showing the bidi-isolated real host that NSWorkspace would open."
                    ))
            }
        case .missingHost:
            lines.append(
                String(
                    localized: "This URL parses but has no host. Likely malformed.",
                    comment: "Body of the OSC 8 confirmation dialog for an http(s) URL with no host component."
                ))
        case .pathHasUnsafeCodepoints:
            lines.append(
                String(
                    localized:
                        "This URL's path contains invisible or direction-flipping characters that may disguise the file extension or target.",
                    comment:
                        "Body of the OSC 8 confirmation dialog for a URL whose path contains bidi-override, zero-width, or control codepoints."
                ))
            if let host = displayHost {
                lines.append(
                    String(
                        localized: "Host: \u{2068}\(Self.sanitizedForAlertBody(host))\u{2069}",
                        comment:
                            "Line of the OSC 8 confirmation dialog body showing the bidi-isolated host of a URL flagged for path-content issues."
                    ))
            }
        case .mailtoWithParameters:
            // Surface the recipient (in URL path OR `to` query param
            // per RFC 6068) and any prefilled subject explicitly —
            // buried in the absoluteString below they're easy to miss.
            // Both `path` and the decoded query values are percent-
            // decoded by Foundation, so `%0A` becomes a literal newline
            // that would otherwise inject forged "Full URL:" / "Host:"
            // lines into this dialog. Sanitize before interpolation.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let toParams =
                components?
                .queryItems?
                .filter { $0.name.lowercased() == "to" }
                .compactMap(\.value)
                .filter { !$0.isEmpty } ?? []
            let recipients = ([url.path].filter { !$0.isEmpty } + toParams)
                .joined(separator: ", ")
            let subject = components?
                .queryItems?
                .first(where: { $0.name.lowercased() == "subject" })?
                .value
            if !recipients.isEmpty {
                lines.append(
                    String(
                        localized: "To: \u{2068}\(Self.sanitizedForAlertBody(recipients))\u{2069}",
                        comment: "Line of the OSC 8 confirmation dialog body showing the bidi-isolated mailto recipients."
                    ))
            }
            if let subject, !subject.isEmpty {
                lines.append(
                    String(
                        localized: "Subject: \u{2068}\(Self.sanitizedForAlertBody(subject))\u{2069}",
                        comment: "Line of the OSC 8 confirmation dialog body showing the bidi-isolated mailto subject prefill."
                    ))
            }
            lines.append(
                String(
                    localized: "This link prefills the recipient, body, or subject. Verify before opening.",
                    comment: "Body summary of the OSC 8 confirmation dialog for a mailto with attacker-controlled prefill parameters."
                ))
        case .disallowedScheme:
            lines.append(
                String(
                    localized: "Scheme: \(url.scheme ?? "unknown")",
                    comment: "Line of the OSC 8 confirmation dialog body explicitly calling out the non-standard scheme name."
                ))
            lines.append(
                String(
                    localized: "This URL uses a scheme outside the standard web/mail allowlist.",
                    comment: "Body summary of the OSC 8 confirmation dialog for a non-standard scheme."
                ))
        }
        lines.append("")
        lines.append(
            String(
                localized: "Full URL: \(truncatedURLString(for: url))",
                comment: "Line of the OSC 8 confirmation dialog body showing the full (possibly truncated) URL. Argument is the URL string."
            ))
        return lines.joined(separator: "\n")
    }

    private static func truncatedURLString(for url: URL) -> String {
        let raw = url.absoluteString.unicodeScalars.map { scalar -> Character in
            isUnsafeAlertBodyScalar(scalar) ? " " : Character(scalar)
        }
        let rawString = String(raw)
        guard rawString.count > urlBodyDisplayCap else { return rawString }
        return String(rawString.prefix(urlBodyDisplayCap)) + "…"
    }

    nonisolated static func closeSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else {
            return
        }

        let view = Unmanaged<GhosttySurfaceNSView>
            .fromOpaque(userdata)
            .takeUnretainedValue()

        Task { @MainActor in
            view.closeAfterProcessExit(processAlive: processAlive)
        }
    }

    nonisolated static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceNSView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface,
            let userdata = ghostty_surface_userdata(surface)
        else {
            return nil
        }

        return Unmanaged<GhosttySurfaceNSView>
            .fromOpaque(userdata)
            .takeUnretainedValue()
    }
}

/// Latch-style coalescer for libghostty wakeup callbacks. The first wakeup
/// after a quiet period flips `isPending` and runs `operation`; subsequent
/// wakeups are dropped until `clearPending()` is called.
///
/// Correctness depends on a libghostty contract: one `ghostty_app_tick(app)`
/// call drains every event represented by wakeups that arrived since the
/// previous tick. Upstream's macOS reference integration relies on the same
/// drain-on-tick behavior, so this is sound as long as we keep using
/// `ghostty_app_tick` as the work-doing call inside the operation. If a
/// future libghostty release changes that contract, dropped wakeups become
/// dropped work and this coalescer needs revisiting.
///
/// The caller is responsible for invoking `clearPending()` from inside the
/// operation (or its continuation) — preferably *before* doing the work, so a
/// wakeup arriving during the work re-arms the latch and schedules another
/// pass instead of being silently absorbed.
final class GhosttyWakeupCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false
    private var pendingSinceUptime: DispatchTime?

    /// Age of the oldest wakeup not yet serviced by a tick, or nil when
    /// none is outstanding. This is the watchdog's staleness signal: an
    /// idle app has no pending wakeup and can never look stale, while a
    /// stuck latch leaves this set and aging. Wakeups dropped by the
    /// latch don't refresh it — staleness must measure the oldest
    /// unserviced wakeup, not the newest. Measured on the suspending
    /// monotonic clock (`DispatchTime`): a wall-clock step can neither
    /// fake staleness nor hide it, and time asleep doesn't count.
    var pendingWakeupAge: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingSinceUptime else { return nil }
        let elapsed =
            DispatchTime.now().uptimeNanoseconds
            - pendingSinceUptime.uptimeNanoseconds
        return TimeInterval(elapsed) / 1_000_000_000
    }

    func schedule(_ operation: () -> Void) {
        lock.lock()
        guard !isPending else {
            lock.unlock()
            return
        }
        isPending = true
        pendingSinceUptime = .now()
        lock.unlock()

        operation()
    }

    func clearPending() {
        lock.lock()
        isPending = false
        pendingSinceUptime = nil
        lock.unlock()
    }
}

func awesoMuxGhosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    GhosttyRuntime.wakeup(userdata)
}

func awesoMuxGhosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    GhosttyRuntime.action(app, target: target, action: action)
}

func awesoMuxGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.readClipboard(userdata, location: location, state: state)
}

func awesoMuxGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    GhosttyRuntime.confirmReadClipboard(
        userdata,
        string: string,
        state: state,
        request: request
    )
}

func awesoMuxGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    GhosttyRuntime.writeClipboard(
        userdata,
        location: location,
        content: content,
        len: len,
        confirm: confirm
    )
}

func awesoMuxGhosttyCloseSurface(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
}

// No existing EventModifiers → NSEvent.ModifierFlags helper was found
// (checked via `grep -rn "EventModifiers" Sources/awesoMux/`); the closest
// precedent is a test-only `private extension` in
// KeyboardShortcutCatalogTests.swift, not reusable from production code.
// Only the four modifiers KeyBinding actually uses need mapping.
extension SwiftUI.EventModifiers {
    func toNSEventModifierFlags() -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }
}

// Duplicated (under a distinct name — `onMainThread` collides at module
// scope with `GhosttyClipboardBridge`'s identical `private` declaration once
// this copy is `internal`) from `GhosttyClipboardBridge`'s file-private
// helper of the same shape: both bridge libghostty C callbacks into
// synchronous MainActor work without reopening a pane-repoint gap.
//
// Internal (not `private`) so `ProgressReportPaneRecycleAtomicityTests` can
// exercise the `DispatchQueue.main.sync` fallback branch directly — the
// off-main path this codebase's call-graph analysis says should never fire
// in production, but which still needs to be *known correct* rather than
// merely assumed dead code.
func onMainThreadSynchronously<T: Sendable>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(work)
    }

    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(work)
    }
}
