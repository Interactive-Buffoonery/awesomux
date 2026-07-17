import AppKit
import AwesoMuxConfig
import Darwin
import DesignSystem
import GhosttyKit
import os

extension GhosttyRuntime {
    // Hostile-input backstop, not a UX cap: legitimate oversize writes (multi-
    // MB remote yanks) prompt like any other (INT-482), but ghostty's OSC
    // parser accepts arbitrarily large OSC 52 payloads, and everything past
    // this point is synchronous MainActor work on the decoded bytes. Applies
    // to confirmed writes only — the Allow path arrives confirm=false,
    // indistinguishable from a local copy.
    private static let maximumConfirmedClipboardWriteBytes = 32 * 1024 * 1024
    private static let clipboardPreviewScalarLimit = 512
    private static let clipboardPreviewDisplayLimit = 160

    // Diagnostics only. Every message here is payload-free (counts/policy, never
    // clipboard text) so it is safe to leave at a level Console captures —
    // these breadcrumbs are the only way a user debugging "my remote copy
    // silently does nothing" can tell awesoMux dropped the write on purpose.
    private static let clipboardWriteLog = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "clipboard-write"
    )

    // Sibling to clipboardWriteLog above — same pattern, read-path category
    // so Console filtering doesn't conflate read and write clipboard events.
    // `nonisolated` because it's read from `confirmReadClipboard`'s
    // nil-userdata branch, which runs before any hop onto the main actor.
    private nonisolated static let clipboardReadLog = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "clipboard-read"
    )

    enum ClipboardRequestKind: Equatable {
        case paste
        case osc52Read
        case osc52Write
        case unknown

        init(_ request: ghostty_clipboard_request_e) {
            switch request {
            case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
                self = .paste
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
                self = .osc52Read
            case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
                self = .osc52Write
            default:
                self = .unknown
            }
        }
    }

    enum ClipboardConfirmationDecision: Equatable {
        case confirmed
        case cancelled
        case dismissed
    }

    /// Pure message for the nil-userdata anomaly, extracted so it's
    /// unit-testable without triggering the DEBUG assertion.
    nonisolated static func describeNilUserdataReadConfirm() -> String {
        "confirmReadClipboard called with nil userdata — pending libghostty read request cannot be completed (no surface handle available)"
    }

    /// Pure message for the read-start nil-userdata anomaly, extracted so it's
    /// unit-testable without triggering the DEBUG assertion.
    nonisolated static func describeNilUserdataReadClipboard() -> String {
        "readClipboard called with nil userdata — libghostty invoked the callback without a registered surface view (request cannot start)"
    }

    nonisolated static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard location == GHOSTTY_CLIPBOARD_STANDARD else {
            return false
        }
        guard let userdata else {
            // Nil userdata means libghostty invoked this callback without a
            // registered surface view. Returning false makes libghostty
            // destroy the request state it allocated for this read (see
            // Surface.clipboardRequest in vendor/ghostty's embedded.zig), so
            // nothing is left pending — this traps
            // the lifetime bug in DEBUG and logs it in RELEASE instead of a
            // silent drop.
            assertionFailure(describeNilUserdataReadClipboard())
            clipboardReadLog.error("\(describeNilUserdataReadClipboard(), privacy: .public)")
            return false
        }

        let userdataAddress = UInt(bitPattern: userdata)
        let stateAddress = state.map(UInt.init(bitPattern:))

        return onMainThread {
            guard let userdata = UnsafeMutableRawPointer(bitPattern: userdataAddress) else {
                return false
            }

            let view = Unmanaged<GhosttySurfaceNSView>
                .fromOpaque(userdata)
                .takeUnretainedValue()

            guard let content = TerminalPasteboardString.content(from: NSPasteboard.general) else {
                return false
            }
            if view.pane.executionPlan.remoteTarget != nil,
                let candidate = TerminalPasteboardString.remoteHandoffCandidate(from: content)
            {
                view.beginRemoteHandoff(candidate)
                return false
            }
            guard let pasteString = TerminalPasteboardString.string(from: content) else {
                return false
            }

            // Propagate completion failure (surface already torn down):
            // libghostty frees the request state it allocated only when this
            // callback returns false or the completion call actually lands,
            // so an unconditional `true` here would strand the native request.
            return view.completeClipboardRequest(
                data: pasteString,
                state: stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            )
        }
    }

    nonisolated static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let requestKind = ClipboardRequestKind(request)

        guard let userdata else {
            // Nil userdata means libghostty invoked this callback without a
            // registered surface view. There is no completion API that
            // doesn't require a `ghostty_surface_t` (verified against
            // vendor/ghostty's embedded.zig/Surface.zig), so the pending
            // request cannot be resolved here — this traps the lifetime
            // bug in DEBUG and logs it in RELEASE instead of a silent drop.
            assertionFailure(describeNilUserdataReadConfirm())
            clipboardReadLog.error("\(describeNilUserdataReadConfirm(), privacy: .public)")
            return
        }

        let userdataAddress = UInt(bitPattern: userdata)
        let stateAddress = state.map(UInt.init(bitPattern:))
        let stringAddress = string.map(UInt.init(bitPattern:))

        onMainThread {
            guard let userdata = UnsafeMutableRawPointer(bitPattern: userdataAddress) else {
                return
            }

            let view = Unmanaged<GhosttySurfaceNSView>
                .fromOpaque(userdata)
                .takeUnretainedValue()

            let confirmClipboardRead = view.runtime.shouldConfirmClipboardRead

            // Peek at whether a dialog will actually be presented so the C
            // string decode below can be skipped on the discard paths
            // (unknown/write kind, the toggle-disabled early-out, the
            // nested-request dedup guard). `resolveClipboardConfirmationRequest`
            // remains the single source of truth for whether to actually
            // present a dialog — if this peek ever drifts from its guards the
            // worst case is one wasted decode, never a missed confirmation.
            let willPresentDialog: Bool
            switch requestKind {
            case .paste:
                willPresentDialog = !isUnsafePasteAlertPresented
            case .osc52Read:
                willPresentDialog = confirmClipboardRead && !isClipboardReadAlertPresented
            case .osc52Write, .unknown:
                willPresentDialog = false
            }

            // LOAD-BEARING INVARIANT: `string` is owned by libghostty and only
            // valid for the synchronous duration of this callback — same
            // ownership shape as `writeClipboard`'s `content` pointer below.
            // The `Task { @MainActor in }` this feeds does NOT run
            // synchronously with this call (Task{} schedules, it doesn't
            // block), so the C string must be copied to a Swift `String`
            // before entering the Task, never inside it.
            let requestData: String
            if willPresentDialog,
               let stringAddress,
               let string = UnsafePointer<CChar>(bitPattern: stringAddress) {
                requestData = String(cString: string)
            } else {
                requestData = ""
            }

            Task { @MainActor in
                await resolveClipboardConfirmationRequest(
                    data: requestData,
                    requestKind: requestKind,
                    paneTitle: view.pane.title,
                    parentWindow: view.window,
                    confirmClipboardRead: confirmClipboardRead
                ) { data, confirmed in
                    view.completeClipboardRequest(
                        data: data,
                        state: stateAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:)),
                        confirmed: confirmed
                    )
                }
            }
        }
    }

    @MainActor
    static var clipboardReadConfirmationProvider: @MainActor (
        _ paneTitle: String,
        _ parentWindow: NSWindow?
    ) async -> ClipboardConfirmationDecision = {
        await presentClipboardReadConfirmation(paneTitle: $0, parentWindow: $1)
    }

    @MainActor
    static var unsafePasteConfirmationProvider: @MainActor (
        _ data: String,
        _ parentWindow: NSWindow?
    ) async -> ClipboardConfirmationDecision = {
        await presentUnsafePasteConfirmation(data: $0, parentWindow: $1)
    }

    // Both flags below are intentionally global (app-wide), not per-pane:
    // awesoMux allows only one clipboard confirmation dialog on screen at a
    // time across the whole app. A second, unrelated request from a
    // different pane that arrives while one is showing is denied outright
    // rather than queued — existing, tested behavior (see
    // "read confirmation drops nested requests while alert is presented").
    @MainActor
    private(set) static var isClipboardReadAlertPresented = false

    @MainActor
    private(set) static var isUnsafePasteAlertPresented = false

    @MainActor
    static func resolveClipboardConfirmationRequest(
        data: String,
        requestKind: ClipboardRequestKind,
        paneTitle: String,
        parentWindow: NSWindow?,
        confirmClipboardRead: Bool,
        complete: @escaping @MainActor (_ data: String, _ confirmed: Bool) -> Bool
    ) async {
        let completion = ClipboardRequestCompletion(complete)

        switch requestKind {
        case .paste:
            guard !isUnsafePasteAlertPresented else {
                clipboardReadLog.debug("Unsafe paste request dropped: a confirmation dialog is already open")
                completion.finish(data: "", confirmed: false)
                return
            }

            isUnsafePasteAlertPresented = true
            defer { isUnsafePasteAlertPresented = false }

            let decision = await unsafePasteConfirmationProvider(data, parentWindow)
            completeUnsafePasteDecision(decision, data: data, completion: completion)

        case .osc52Read:
            // Deny is also enforced upstream: when the ghostty `clipboard-read`
            // override (set from this same toggle) is `deny`, libghostty drops
            // the OSC 52 read and never invokes this callback (see
            // `writeClipboard`'s matching backstop comment above for the write
            // side). This branch is the app-side backstop for the window where
            // the override and the live provider could disagree (e.g. mid
            // `applyTerminalSettings`) — logged for the same reason the write
            // side logs its policy-deny drop, so a user debugging "my agent's
            // clipboard read does nothing" has the same trail for reads as
            // for writes.
            guard confirmClipboardRead else {
                clipboardReadLog.debug("OSC 52 clipboard read dropped: confirm-clipboard-read is disabled")
                completion.finish(data: "", confirmed: false)
                return
            }
            guard !isClipboardReadAlertPresented else {
                clipboardReadLog.debug("OSC 52 clipboard read request dropped: a confirmation dialog is already open")
                completion.finish(data: "", confirmed: false)
                return
            }

            isClipboardReadAlertPresented = true
            defer { isClipboardReadAlertPresented = false }

            let decision = await clipboardReadConfirmationProvider(paneTitle, parentWindow)
            completeClipboardReadDecision(
                decision,
                data: data,
                paneTitle: paneTitle,
                completion: completion
            )

        case .osc52Write, .unknown:
            // No debug log here either: these request kinds are never routed
            // to a confirmation dialog in the first place (see `willPresentDialog`
            // in `confirmReadClipboard` above), so reaching this branch is the
            // expected no-op, not a lost request.
            completion.finish(data: "", confirmed: false)
        }
    }

    @MainActor
    static func resetClipboardConfirmationProvidersForTesting() {
        clipboardReadConfirmationProvider = {
            await presentClipboardReadConfirmation(paneTitle: $0, parentWindow: $1)
        }
        unsafePasteConfirmationProvider = {
            await presentUnsafePasteConfirmation(data: $0, parentWindow: $1)
        }
        isClipboardReadAlertPresented = false
        isUnsafePasteAlertPresented = false
    }

    @MainActor
    private static func completeClipboardReadDecision(
        _ decision: ClipboardConfirmationDecision,
        data: String,
        paneTitle: String,
        completion: ClipboardRequestCompletion
    ) {
        // Announce success/cancellation only when `completion` confirms the
        // decision actually reached libghostty (`ghostty_surface_complete_
        // clipboard_request`). If the pane was torn down while the dialog was
        // up, `completion.finish` returns false and VoiceOver stays silent
        // rather than announcing an outcome that never happened.
        switch decision {
        case .confirmed:
            if completion.finish(data: data, confirmed: true) {
                announceClipboardReadAllowed(paneTitle: paneTitle)
            }
        case .cancelled:
            if completion.finish(data: "", confirmed: false) {
                announceClipboardReadCancelled(paneTitle: paneTitle)
            }
        case .dismissed:
            completion.finish(data: "", confirmed: false)
        }
    }

    @MainActor
    private static func completeUnsafePasteDecision(
        _ decision: ClipboardConfirmationDecision,
        data: String,
        completion: ClipboardRequestCompletion
    ) {
        // See completeClipboardReadDecision above: only announce when the
        // completion reached libghostty.
        switch decision {
        case .confirmed:
            if completion.finish(data: data, confirmed: true) {
                announceUnsafePasteAllowed()
            }
        case .cancelled:
            if completion.finish(data: "", confirmed: false) {
                announceUnsafePasteCancelled()
            }
        case .dismissed:
            completion.finish(data: "", confirmed: false)
        }
    }

    @MainActor
    private static func presentClipboardReadConfirmation(
        paneTitle: String,
        parentWindow: NSWindow?
    ) async -> ClipboardConfirmationDecision {
        // `paneTitle` is sourced from OSC 0/2 escape sequences — the same
        // channel a hostile program controls, so it can spoof its own title
        // (e.g. to "Finder") right before requesting a clipboard read. Treat
        // this as a best-effort hint for "who's asking," never as a verified
        // identity claim or a trust boundary.
        let displayTitle = sanitizedAlertTitle(paneTitle)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "\(displayTitle) wants to read your clipboard. Allow?",
            comment: "Title of the OSC 52 clipboard-read confirmation dialog. Argument is the bidi-isolated pane title."
        )

        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Default button on the OSC 52 clipboard-read confirmation dialog. Cancels the read."
        ))
        let allowButton = alert.addButton(withTitle: String(
            localized: "Allow",
            comment: "Button on the OSC 52 clipboard-read confirmation dialog. Allows the terminal program to read the clipboard."
        ))
        allowButton.hasDestructiveAction = true
        allowButton.setAccessibilityLabel(String(
            localized: "Allow terminal program to read the clipboard",
            comment: "VoiceOver label for approving an OSC 52 clipboard read."
        ))
        alert.informativeText = String(
            localized: "Press ⌘Return to allow. Esc cancels.",
            comment: "Keyboard hint line on the OSC 52 clipboard-read confirmation dialog."
        )

        return await presentClipboardAlert(
            alert,
            parentWindow: parentWindow,
            keyboardAccept: allowButton
        )
    }

    @MainActor
    private static func presentUnsafePasteConfirmation(
        data: String,
        parentWindow: NSWindow?
    ) async -> ClipboardConfirmationDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "This paste could run a command before you finish pasting. Paste anyway?",
            comment: "Title of the unsafe-paste confirmation dialog."
        )
        alert.informativeText = unsafePasteConfirmationBody(for: data)

        alert.addButton(withTitle: String(
            localized: "Cancel",
            comment: "Default button on the unsafe-paste confirmation dialog. Cancels the paste."
        ))
        let pasteButton = alert.addButton(withTitle: String(
            localized: "Paste Anyway",
            comment: "Button on the unsafe-paste confirmation dialog. Allows the paste."
        ))
        pasteButton.hasDestructiveAction = true
        pasteButton.setAccessibilityLabel(String(
            localized: "Paste anyway",
            comment: "VoiceOver label for approving an unsafe paste."
        ))
        alert.informativeText += "\n\n" + String(
            localized: "Press ⌘Return to paste anyway. Esc cancels.",
            comment: "Keyboard hint line on the unsafe-paste confirmation dialog."
        )

        return await presentClipboardAlert(
            alert,
            parentWindow: parentWindow,
            keyboardAccept: pasteButton
        )
    }

    // Mirrors the OSC 52 write-confirm dialog's preview line exactly (same
    // sanitizer, same truncation limits — see clipboardWriteConfirmationBody)
    // so the user can see what they're about to paste instead of approving
    // blind. Not private so tests can exercise it without an NSAlert.
    @MainActor
    static func unsafePasteConfirmationBody(for text: String) -> String {
        String(
            localized: "Preview: \(sanitizedClipboardPreview(text))",
            comment: "Preview line in the unsafe-paste confirmation dialog. Argument is a sanitized single-line preview of the pending paste content."
        )
    }

    @MainActor
    private static func presentClipboardAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow?,
        keyboardAccept acceptButton: NSButton? = nil
    ) async -> ClipboardConfirmationDecision {
        // No cancellation handler: unreachable today because nothing cancels
        // the owning Task, but if pane-teardown ever gets wired into
        // structured concurrency cancellation, this continuation would wedge
        // permanently instead of resuming.
        return await withCheckedContinuation { continuation in
            let complete: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: clipboardDecision(for: response))
            }

            if let parentWindow {
                alert.beginSheetModal(
                    for: parentWindow,
                    keyboardAccept: acceptButton,
                    completionHandler: complete
                )
            } else {
                complete(alert.runModal(keyboardAccept: acceptButton))
            }
        }
    }

    private static func clipboardDecision(
        for response: NSApplication.ModalResponse
    ) -> ClipboardConfirmationDecision {
        switch response {
        case .alertSecondButtonReturn:
            return .confirmed
        case .alertFirstButtonReturn:
            return .cancelled
        default:
            return .dismissed
        }
    }

    private static func compactTitle(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 60
            ? String(oneLine.prefix(60)) + "…"
            : oneLine
    }

    // Not private so tests can exercise the empty-title fallback and bidi
    // isolation without building an NSAlert.
    static func sanitizedAlertTitle(_ raw: String) -> String {
        let compact = compactTitle(raw)
        guard !compact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // `pane.title` has no hard non-empty guarantee (see
            // TerminalPane). Without this fallback an empty title collapses
            // the dialog's subject to nothing readable ("⁨⁩ wants to read
            // your clipboard. Allow?").
            let fallback = String(
                localized: "This terminal",
                comment: "Fallback subject in clipboard confirmation dialogs when the pane has no title."
            )
            return "\u{2068}\(fallback)\u{2069}"
        }
        return "\u{2068}\(compact)\u{2069}"
    }

    @MainActor
    private static func announceClipboardReadAllowed(paneTitle: String) {
        TerminalAccessibilityAnnouncer.announce(String(
            localized: "Allowed clipboard read for \(sanitizedAlertTitle(paneTitle))",
            comment: "VoiceOver announcement after the user allows a terminal program to read the clipboard. Argument is the bidi-isolated pane title."
        ))
    }

    @MainActor
    private static func announceClipboardReadCancelled(paneTitle: String) {
        TerminalAccessibilityAnnouncer.announce(String(
            localized: "Clipboard read cancelled for \(sanitizedAlertTitle(paneTitle))",
            comment: "VoiceOver announcement after the user cancels a terminal clipboard read. Argument is the bidi-isolated pane title."
        ))
    }

    @MainActor
    private static func announceUnsafePasteAllowed() {
        TerminalAccessibilityAnnouncer.announce(String(
            localized: "Paste allowed.",
            comment: "VoiceOver announcement after the user allows an unsafe paste."
        ))
    }

    @MainActor
    private static func announceUnsafePasteCancelled() {
        TerminalAccessibilityAnnouncer.announce(String(
            localized: "Paste cancelled.",
            comment: "VoiceOver announcement after the user cancels an unsafe paste."
        ))
    }

    nonisolated static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard location == GHOSTTY_CLIPBOARD_STANDARD,
              let userdata,
              let content,
              len > 0 else {
            return
        }

        let userdataAddress = UInt(bitPattern: userdata)
        let contentAddress = UInt(bitPattern: content)
        // LOAD-BEARING INVARIANT: `content` (and the `mime`/`data` it points to)
        // is owned by libghostty and freed the instant this callback returns —
        // see the stack-scoped `defer alloc.free(...)` in setClipboard /
        // Surface.clipboardWrite in vendor/ghostty. `onMainThread` runs the
        // closure SYNCHRONOUSLY (inline `assumeIsolated` on the main thread, or
        // `DispatchQueue.main.sync` otherwise), so every dereference below — up
        // to and including the `String(cString:)` copy in `textPlainContent` —
        // completes before we return into Zig and the buffer is freed. If
        // `onMainThread` is ever made async, or an `await`/`Task {}` is inserted
        // between here and the read, this becomes a use-after-free that copies
        // freed (potentially attacker-influenced) heap bytes onto the clipboard.
        // Copy `text` out before any suspension if that ever changes.
        onMainThread {
            guard let userdata = UnsafeMutableRawPointer(bitPattern: userdataAddress) else {
                return
            }
            guard let content = UnsafePointer<ghostty_clipboard_content_s>(bitPattern: contentAddress) else {
                return
            }

            let view = Unmanaged<GhosttySurfaceNSView>
                .fromOpaque(userdata)
                .takeUnretainedValue()
            let policy = view.runtime.clipboardWritePolicy

            // Deny is also enforced upstream: when the ghostty `clipboard-write`
            // override (set from this same policy) is `deny`, libghostty drops
            // the OSC 52 write and never invokes this callback. This branch is
            // the app-side backstop for the window where the override and the
            // live provider could disagree (e.g. mid `applyTerminalSettings`).
            if confirm, policy == .deny {
                clipboardWriteLog.debug("OSC 52 clipboard write dropped: policy is deny")
                return
            }

            let text = textPlainContent(
                from: content,
                count: len,
                maximumBytes: confirm ? maximumConfirmedClipboardWriteBytes : nil
            )
            guard let text else {
                // No text/plain item, or a confirmed write past the hostile-
                // input backstop. Either way nothing reaches the clipboard and
                // no dialog shows; log so the silent drop is diagnosable.
                clipboardWriteLog.debug("OSC 52 clipboard write dropped: no usable text/plain payload or exceeded \(maximumConfirmedClipboardWriteBytes) bytes")
                return
            }

            // `text` is a copied String, so hopping into a Task here does not
            // violate the buffer-lifetime invariant above — nothing after this
            // point touches libghostty-owned memory. The confirmation sheet is
            // async, so the pasteboard write lands a turn later; the old
            // runModal path already deferred it behind a nested run loop.
            let sourceDescription = view.clipboardWriteSourceDescription
            let parentWindow = view.window
            Task { @MainActor in
                guard await shouldWriteClipboard(
                    text,
                    policy: policy,
                    confirm: confirm,
                    sourceDescription: sourceDescription,
                    parentWindow: parentWindow
                ) else {
                    return
                }

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }

    @MainActor
    static var clipboardWriteConfirmationProvider: @MainActor (String, String?, NSWindow?) async -> Bool = {
        await confirmClipboardWrite(text: $0, sourceDescription: $1, anchorWindow: $2)
    }

    @MainActor
    private(set) static var isClipboardWriteAlertPresented = false

    /// Text of the write currently showing its confirmation dialog, kept so
    /// redraw-spam duplicates of it can be dropped without queueing.
    @MainActor
    private static var activeClipboardWritePromptText: String?

    /// The single waiting slot behind the open confirmation dialog. Depth is
    /// deliberately one: a newer distinct write supersedes an older waiting
    /// one (which resolves false), so a hostile or chatty program can never
    /// stack dialogs or grow an unbounded queue.
    @MainActor
    private static var pendingClipboardWrite: PendingClipboardWrite?

    private struct PendingClipboardWrite {
        let text: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Bumped by the test reset. A `shouldWriteClipboard` call that was
    /// suspended across a reset would otherwise run its deferred cleanup
    /// against state the reset already rebuilt (clearing a flag a newer call
    /// now owns); the stale generation makes that cleanup a no-op instead.
    @MainActor
    private static var clipboardWriteGateGeneration = 0

    @MainActor
    static func shouldWriteClipboard(
        _ text: String,
        policy: TerminalConfig.ClipboardWritePolicy,
        confirm: Bool,
        sourceDescription: String? = nil,
        parentWindow: NSWindow? = nil
    ) async -> Bool {
        // libghostty marks OSC 52 writes as `confirm` when clipboard-write is
        // configured to ask. Local copy actions also reach this callback, but
        // they use confirm=false and should preserve normal user copy behavior.
        guard confirm else { return true }

        switch policy {
        case .allow:
            return true
        case .deny:
            return false
        case .ask:
            if isClipboardWriteAlertPresented {
                // A TUI re-emitting OSC 52 on every redraw sends the same
                // payload each time; dropping duplicates keeps redraw spam
                // from re-prompting after the user answers once.
                guard text != activeClipboardWritePromptText,
                      text != pendingClipboardWrite?.text else {
                    clipboardWriteLog.debug("OSC 52 clipboard write dropped: duplicate of a write already awaiting confirmation")
                    return false
                }
                if let superseded = pendingClipboardWrite {
                    pendingClipboardWrite = nil
                    clipboardWriteLog.debug("OSC 52 clipboard write dropped: superseded by a newer write while a confirmation dialog is open")
                    superseded.continuation.resume(returning: false)
                }
                let mayPresent = await withCheckedContinuation { continuation in
                    pendingClipboardWrite = PendingClipboardWrite(text: text, continuation: continuation)
                }
                guard mayPresent else { return false }
                // Resumed true: the closing dialog handed
                // `isClipboardWriteAlertPresented` ownership to this write
                // without ever clearing the flag, so no third write can slip
                // past during the handoff.
            } else {
                isClipboardWriteAlertPresented = true
            }

            activeClipboardWritePromptText = text
            let generation = clipboardWriteGateGeneration
            defer {
                if generation != clipboardWriteGateGeneration {
                    // A reset ran while this dialog was up; it already
                    // resumed any pending write and rebuilt the gate state.
                } else if let next = pendingClipboardWrite {
                    pendingClipboardWrite = nil
                    activeClipboardWritePromptText = next.text
                    next.continuation.resume(returning: true)
                } else {
                    isClipboardWriteAlertPresented = false
                    activeClipboardWritePromptText = nil
                }
            }
            return await clipboardWriteConfirmationProvider(text, sourceDescription, parentWindow)
        }
    }

    /// Observability for tests that need to know a burst write has parked in
    /// the waiting slot before firing the next one.
    @MainActor
    static var pendingClipboardWriteTextForTesting: String? {
        pendingClipboardWrite?.text
    }

    @MainActor
    static func resetClipboardWriteConfirmationProviderForTesting() {
        clipboardWriteConfirmationProvider = {
            await confirmClipboardWrite(text: $0, sourceDescription: $1, anchorWindow: $2)
        }
        clipboardWriteGateGeneration += 1
        isClipboardWriteAlertPresented = false
        activeClipboardWritePromptText = nil
        if let pending = pendingClipboardWrite {
            pendingClipboardWrite = nil
            pending.continuation.resume(returning: false)
        }
    }

    @MainActor
    private static func confirmClipboardWrite(
        text: String,
        sourceDescription: String?,
        anchorWindow: NSWindow?
    ) async -> Bool {
        // Cancel stays the default (Return) so a reflexive Return keeps the
        // current clipboard rather than approving the terminal-origin write;
        // AwModal wires Return and Esc to Cancel. Same button-order convention
        // as the OSC 8 confirmation (see INT-22's confirmCloseIfNeeded).
        let configuration = AwModalConfiguration(
            title: String(
                localized: "Update clipboard from terminal escape sequence?",
                comment: "Title of the confirmation dialog for OSC 52 clipboard writes."
            ),
            body: clipboardWriteConfirmationBody(
                for: text,
                sourceDescription: sourceDescription
            ),
            confirmTitle: String(
                localized: "Update Clipboard",
                comment: "Destructive button on the terminal-origin clipboard write confirmation dialog."
            ),
            cancelTitle: String(
                localized: "Cancel",
                comment: "Default button on the OSC 52 clipboard write confirmation dialog."
            ),
            confirmAccessibilityLabel: String(
                localized: "Update clipboard from terminal escape sequence",
                comment: "VoiceOver label for approving an OSC 52 clipboard write."
            ),
            cancelAccessibilityLabel: String(
                localized: "Cancel and keep the current clipboard",
                comment: "VoiceOver label for cancelling an OSC 52 clipboard write."
            ),
            keyboardHint: String(
                localized: "Press ⌘Return to update clipboard. Return or Esc cancels.",
                comment: "Keyboard hint line on the OSC 52 clipboard-write confirmation dialog."
            )
        )
        return await AwModal(configuration: configuration, anchorWindow: anchorWindow).run() == .confirm
    }

    @MainActor
    static func clipboardWriteConfirmationBody(
        for text: String,
        sourceDescription: String? = nil
    ) -> String {
        let byteCount = text.utf8.count
        let characterCount = text.count
        var body = String(
            localized: """
            Terminal output wants to replace the macOS clipboard with \
            \(characterCount) characters (\(byteCount) bytes).
            """,
            comment: "Body of the OSC 52 clipboard write confirmation dialog. Arguments are character count and byte count."
        )
        if let sourceDescription, !sourceDescription.isEmpty {
            body += "\n\n" + String(
                localized: "Source: \(sanitizedClipboardPreview(sourceDescription))",
                comment: "Source line in the OSC 52 clipboard write confirmation dialog. Argument is a sanitized workspace or pane description."
            )
        }
        body += "\n\n" + String(
            localized: "Preview: \(sanitizedClipboardPreview(text))",
            comment: "Preview line in the OSC 52 clipboard write confirmation dialog. Argument is a sanitized single-line preview."
        )
        return body
    }

    private static func sanitizedClipboardPreview(_ text: String) -> String {
        var oneLine = ""
        var previousWasSpace = false
        var wasTruncated = false

        for (index, scalar) in text.unicodeScalars.enumerated() {
            if index >= clipboardPreviewScalarLimit {
                wasTruncated = true
                break
            }

            let replacement = sanitizedClipboardPreviewScalar(scalar)
            if replacement == " " {
                guard !oneLine.isEmpty, !previousWasSpace else { continue }
                previousWasSpace = true
            } else {
                previousWasSpace = false
            }

            oneLine.append(replacement)
            if oneLine.count >= clipboardPreviewDisplayLimit {
                wasTruncated = true
                break
            }
        }

        oneLine = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else {
            return String(
                localized: "(empty after sanitizing control characters)",
                comment: "Clipboard preview fallback when terminal-origin clipboard text contains only unsafe/control characters."
            )
        }
        // The scan loop above already caps `oneLine` at clipboardPreviewDisplayLimit
        // graphemes and sets `wasTruncated` when it does; trimming only shrinks it,
        // so no second prefix is needed here.
        return wasTruncated ? oneLine + "…" : oneLine
    }

    // Shares the OSC 8 alert-body unsafe-scalar predicate so the two dialogs
    // can't drift apart on what they strip (control chars, bidi overrides,
    // zero-width / invisible formatting). See `isUnsafeAlertBodyScalar`.
    private static func sanitizedClipboardPreviewScalar(_ scalar: Unicode.Scalar) -> Character {
        isUnsafeAlertBodyScalar(scalar) ? " " : Character(scalar)
    }

    private nonisolated static func textPlainContent(
        from content: UnsafePointer<ghostty_clipboard_content_s>,
        count: Int,
        maximumBytes: Int? = nil
    ) -> String? {
        for index in 0..<count {
            let item = content[index]
            guard let mime = item.mime,
                  String(cString: mime) == "text/plain",
                  let data = item.data else {
                continue
            }

            if let maximumBytes,
               cStringByteCount(data, maximumBytes: maximumBytes) == nil {
                return nil
            }

            return String(cString: data)
        }

        return nil
    }

    private nonisolated static func cStringByteCount(
        _ data: UnsafePointer<CChar>,
        maximumBytes: Int
    ) -> Int? {
        var count = 0
        while count <= maximumBytes {
            if data[count] == 0 {
                return count
            }
            count += 1
        }
        return nil
    }
}
// Long enough that paths handed to a long-running agent thread (Claude Code,
// etc.) are still readable when the user comes back to the same session.
private let imagePasteMaxAge: TimeInterval = 24 * 60 * 60

@MainActor
enum TerminalPasteboardString {
    private static let log = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "clipboard-paste"
    )

    // File-URL gesture wins (explicit "copy file in Finder"). After that prefer
    // plain text — a "rich link" pasteboard carries both .string and .png, and
    // the user almost always meant the text. Image-materialization fires only
    // when there is no usable text, which is the screenshot / image-only case.
    // Non-file URLs are the final fallback.
    enum Content {
        case fileURLs([URL])
        case text(String)
        case png(Data)
        case tiff(Data)
        case urls([URL])
    }

    static func content(from pasteboard: NSPasteboard) -> Content? {
        let allURLs = urls(from: pasteboard)
        let fileURLs = allURLs.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return .text(text)
        }

        if let data = pasteboard.data(forType: .png) {
            return .png(data)
        }
        if let data = pasteboard.data(forType: .tiff) {
            return .tiff(data)
        }

        if !allURLs.isEmpty {
            return .urls(allURLs)
        }

        return nil
    }

    static func string(from content: Content) -> String? {
        switch content {
        case .fileURLs(let urls):
            urls.map { TerminalInsertionEscaping.escape($0.path) }.joined(separator: " ")
        case .text(let text):
            text
        case .png(let data):
            materializedImagePath(fromPNGData: data).map(TerminalInsertionEscaping.escape)
        case .tiff(let data):
            pngData(fromTIFFData: data)
                .flatMap(materializedImagePath(fromPNGData:))
                .map(TerminalInsertionEscaping.escape)
        case .urls(let urls):
            urls.map { TerminalInsertionEscaping.escape($0.absoluteString) }.joined(separator: " ")
        }
    }

    static func remoteHandoffCandidate(from content: Content) -> RemoteHandoff.Candidate? {
        switch content {
        case .fileURLs(let urls):
            guard urls.count == 1,
                ["md", "markdown"].contains(urls[0].pathExtension.lowercased()),
                !isDirectory(urls[0])
            else {
                return nil
            }
            return .markdown(urls[0])
        case .png(let data):
            return .png(data)
        case .tiff(let data):
            return .tiff(data)
        case .text, .urls:
            return nil
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
    }

    private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    }

    private static func materializedImagePath(fromPNGData pngData: Data) -> String? {
        do {
            return try PastedImageFile.materialize(pngData).path
        } catch {
            log.error(
                "paste: failed to materialize clipboard image at \(PastedImageFile.directoryURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func pngData(fromTIFFData data: Data) -> Data? {
        NSBitmapImageRep(data: data)?.representation(
            using: .png,
            properties: [:]
        )
    }

    nonisolated static func cleanupOldImages() {
        let cutoff = Date().addingTimeInterval(-imagePasteMaxAge)
        PastedImageFile.cleanup(olderThan: cutoff)
    }
}

@MainActor
private final class ClipboardRequestCompletion {
    private var didComplete = false
    private let complete: @MainActor (_ data: String, _ confirmed: Bool) -> Bool

    init(_ complete: @escaping @MainActor (_ data: String, _ confirmed: Bool) -> Bool) {
        self.complete = complete
    }

    /// Returns whether the underlying completion actually reached
    /// libghostty. Idempotent: a second call (e.g. from an already-consumed
    /// dedup guard) is a no-op and returns `false`.
    @discardableResult
    func finish(data: String, confirmed: Bool) -> Bool {
        guard !didComplete else { return false }
        didComplete = true
        return complete(data, confirmed)
    }
}

enum ClipboardPasteImageStore {
    // Run once at app launch on a background queue. Replaces the previous
    // per-paste cleanup walk that scanned the directory on the main thread on
    // every image paste.
    static func scheduleCleanup() {
        Task.detached(priority: .background) {
            TerminalPasteboardString.cleanupOldImages()
        }
    }
}

private func onMainThread<T: Sendable>(_ work: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(work)
    }

    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(work)
    }
}
