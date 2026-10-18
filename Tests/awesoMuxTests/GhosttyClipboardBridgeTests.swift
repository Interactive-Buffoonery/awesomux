import AppKit
import AwesoMuxConfig
import AwesoMuxTestSupport
import GhosttyKit
import Testing
@testable import awesoMux

/// Stand-in for the write-confirmation dialog: records every prompt and holds
/// each open until the test closes it by text, so burst tests can control
/// interleaving.
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
    @Test(arguments: [
        (TerminalConfig.ClipboardWritePolicy.allow, true, false, true, false),
        (.deny, true, true, false, false),
        (.ask, false, false, true, false),
        (.deny, false, false, true, false),
        (.ask, true, true, true, true),
        (.ask, true, false, false, true),
    ])
    func writePolicy(policy: TerminalConfig.ClipboardWritePolicy, confirm: Bool, approval: Bool, expected: Bool, prompts: Bool) async {
        GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting()
        defer { GhosttyRuntime.resetClipboardWriteConfirmationProviderForTesting() }
        var prompted = false
        GhosttyRuntime.clipboardWriteConfirmationProvider = { text, _, _ in
            #expect(text == "payload")
            prompted = true
            return approval
        }
        #expect(await GhosttyRuntime.shouldWriteClipboard("payload", policy: policy, confirm: confirm) == expected)
        #expect(prompted == prompts)
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

    @Test(arguments: [
        (false, "git clone https://good.example\nrm -rf ~\u{202E}txt", nil, "Preview: git clone https://good.example rm -rf ~ txt", false),
        (false, "good\u{200D}\u{200C}.example\u{FE0F}", nil, nil, false),
        (false, "payload", "workspace release\npane \u{202E}123", "Source: workspace release pane 123", false),
        (false, String(repeating: "a", count: 10_000), nil, "Preview: \(String(repeating: "a", count: 160))…", false),
        (true, "git clone https://good.example\nrm -rf ~\u{202E}txt", nil, "Preview: git clone https://good.example rm -rf ~ txt", false),
        (true, String(repeating: "a", count: 10_000), nil, "Preview: \(String(repeating: "a", count: 160))…", true),
    ])
    func dialogSanitizesAndBounds(paste: Bool, payload: String, source: String?, preview: String?, exact: Bool) {
        let body =
            paste
            ? GhosttyRuntime.unsafePasteConfirmationBody(for: payload)
            : GhosttyRuntime.clipboardWriteConfirmationBody(for: payload, sourceDescription: source)
        if let preview { #expect(exact ? body == preview : body.contains(preview)) }
        #expect(!body.contains("\nrm -rf"))
        #expect(!body.contains("\npane"))
        #expect(!body.unicodeScalars.contains { [0x202E, 0x200D, 0x200C, 0xFE0F].contains($0.value) })
        if payload.count == 10_000 { #expect(body.count < 400) }
    }

    @Test(arguments: [("", "This terminal"), ("   ", "This terminal"), ("deploy pane", "deploy pane")])
    func alertTitle(raw: String, expected: String) {
        #expect(GhosttyRuntime.sanitizedAlertTitle(raw) == "\u{2068}\(expected)\u{2069}")
    }

    @Test(arguments: [("clipboard payload", "deploy pane", true), ("", "empty pane", true), ("clipboard payload", "deploy pane", false)])
    func osc52Read(data: String, title: String, enabled: Bool) async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }
        var titles: [String] = []
        GhosttyRuntime.clipboardReadConfirmationProvider = { title, window in
            #expect(window == nil)
            titles.append(title)
            return .confirmed
        }
        var completions: [(String, Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: data, requestKind: .osc52Read, paneTitle: title,
            parentWindow: nil, confirmClipboardRead: enabled
        ) {
            completions.append(($0, $1)); return true
        }
        #expect(titles == (enabled ? [title] : []))
        #expect(completions.count == 1)
        #expect(completions.first?.0 == (enabled ? data : ""))
        #expect(completions.first?.1 == enabled)
    }

    @Test(arguments: [(GhosttyRuntime.ClipboardRequestKind.paste, true), (.paste, false), (.osc52Write, true)])
    func pasteConfirmation(kind: GhosttyRuntime.ClipboardRequestKind, approved: Bool) async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }
        var prompts: [String] = []
        GhosttyRuntime.unsafePasteConfirmationProvider = { data, window in
            #expect(window == nil)
            prompts.append(data)
            return approved ? .confirmed : .cancelled
        }
        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in
            Issue.record("Read confirmation should not be part of this paste branch")
            return .cancelled
        }
        let data = kind == .paste ? "echo hi\n" : "ignored"
        var completions: [(String, Bool)] = []
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: data, requestKind: kind, paneTitle: kind == .paste ? "paste pane" : "write pane",
            parentWindow: nil, confirmClipboardRead: true
        ) {
            completions.append(($0, $1)); return true
        }
        #expect(prompts == (kind == .paste ? [data] : []))
        #expect(completions.count == 1)
        #expect(completions.first?.0 == (kind == .paste && approved ? data : ""))
        #expect(completions.first?.1 == (kind == .paste && approved))
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

    @Test(arguments: [GhosttyRuntime.ClipboardRequestKind.osc52Read, .paste])
    func completionWithoutSurfaceClearsGate(kind: GhosttyRuntime.ClipboardRequestKind) async {
        GhosttyRuntime.resetClipboardConfirmationProvidersForTesting()
        defer { GhosttyRuntime.resetClipboardConfirmationProvidersForTesting() }
        GhosttyRuntime.clipboardReadConfirmationProvider = { _, _ in .confirmed }
        GhosttyRuntime.unsafePasteConfirmationProvider = { _, _ in .confirmed }
        var count = 0
        await GhosttyRuntime.resolveClipboardConfirmationRequest(
            data: kind == .paste ? "echo hi\n" : "clipboard payload", requestKind: kind,
            paneTitle: "torn down pane", parentWindow: nil, confirmClipboardRead: true
        ) { _, _ in
            count += 1; return false
        }
        #expect(count == 1)
        #expect(!GhosttyRuntime.isClipboardReadAlertPresented)
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

    struct PayloadCase: Sendable {
        let representations: [(mime: String, bytes: [UInt8]?, len: Int?)]
        let preview: String
        let deliverable: String?
    }
    @Test(arguments: [
        PayloadCase(representations: [("text/plain", Array("rm -rf /".utf8), nil)], preview: "rm -rf /", deliverable: "rm -rf /"),
        PayloadCase(
            representations: [("image/png", [0x89, 0x50], nil), ("text/plain", Array("hello".utf8), nil)], preview: "hello",
            deliverable: "hello"),
        PayloadCase(
            representations: [("image/png", [0x89, 0x50, 0x4E], nil), ("application/octet-stream", Array(repeating: 0, count: 12), nil)],
            preview: "image/png (3 bytes)\napplication/octet-stream (12 bytes)", deliverable: nil),
        PayloadCase(representations: [("text/plain", [0xFF, 0xFE], nil)], preview: "text/plain (2 bytes)", deliverable: nil),
        PayloadCase(representations: [("text/plain", nil, 7)], preview: "", deliverable: ""),
        PayloadCase(representations: [], preview: "", deliverable: nil),
    ])
    func payloadDecoding(testCase: PayloadCase) {
        withConfirm(testCase.representations) { confirm in
            let decoded = GhosttyRuntime.decodeClipboardConfirmPayload(from: confirm)
            #expect(decoded.preview == testCase.preview)
            #expect(decoded.deliverableText == testCase.deliverable)
        }
    }

}

/// The pure mime/list routing matrix for clipboard reads. If upstream ever
/// changes the mime strings it requests, these pin which shapes awesoMux
/// serves, lists, or refuses — a silent all-reads failure shows up here.
@Suite("Ghostty clipboard read routing")
struct GhosttyClipboardReadRoutingTests {
    @Test(arguments: [
        (["text/plain"], false, "served payload", true, true, false),
        (["text/plain"], true, "served payload", true, true, true),
        (["image/png"], false, "served payload", false, false, false),
        (["image/png"], true, "served payload", true, false, true),
        ([], true, "served payload", true, false, true),
        ([], true, nil, true, false, false),
        (["text/plain"], false, nil, false, false, false),
        (["image/png", "text/plain", "application/x-zsh"], false, "served payload", true, true, false),
    ])
    func readRouting(mimes: [String], list: Bool, text: String?, deliverable: Bool, servesText: Bool, listsText: Bool) {
        let delivery = GhosttyRuntime.planClipboardRead(requestedMimes: mimes, list: list, servableText: text)
        #expect(delivery.deliverable == deliverable)
        #expect(delivery.contents.map(\.mime) == (servesText ? ["text/plain"] : []))
        #expect(delivery.contents.first?.data == (servesText ? text.map { Data($0.utf8) } : nil))
        #expect(delivery.available == (listsText ? ["text/plain"] : []))
    }

}

/// `declaresSupportedContent` gates the context menu's Paste item without
/// reading the pasteboard, so its type list must stay in step with the
/// `content(from:)` ladder it stands in for.
@MainActor
@Suite("Terminal pasteboard supported-content metadata")
struct TerminalPasteboardSupportedContentTests {
    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        pasteboard.clearContents()
        return pasteboard
    }

    @Test(arguments: ["text", "file", "url", "png", "tiff", "empty", "unsupported"])
    func pasteboardTypes(kind: String) throws {
        let directory = try TemporaryDirectory(prefix: "supported-content")
        let file = directory.url.appendingPathComponent("notes.md")
        try Data("x".utf8).write(to: file)
        let pasteboard = scratchPasteboard()
        switch kind {
        case "text": pasteboard.setString("hello", forType: .string)
        case "file": pasteboard.writeObjects([file as NSURL])
        case "url": pasteboard.writeObjects([NSURL(string: "https://example.com")!])
        case "png": pasteboard.setData(Data([1, 2, 3]), forType: .png)
        case "tiff": pasteboard.setData(Data([1, 2, 3]), forType: .tiff)
        case "unsupported": pasteboard.setData(Data([1, 2, 3]), forType: .init("com.example.private-blob"))
        default: break
        }
        #expect(TerminalPasteboardString.declaresSupportedContent(pasteboard) == !["empty", "unsupported"].contains(kind))
    }

}
