import AppKit
import AwesoMuxCore
import SwiftUI

struct WorkspaceEmojiField: NSViewRepresentable {
    @Binding var text: String
    let pickerRequestID: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> WorkspaceEmojiTextView {
        let field = WorkspaceEmojiTextView(frame: .zero)
        update(field)
        return field
    }

    func updateNSView(_ field: WorkspaceEmojiTextView, context: Context) {
        update(field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkspaceEmojiTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 64, height: proposal.height ?? 36)
    }

    private func update(_ field: WorkspaceEmojiTextView) {
        field.onChange = { text = $0 }
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        field.onFocusChange = { isFocused = $0 }
        if field.string != text { field.string = text }
        field.requestPicker(pickerRequestID)
    }
}

final class WorkspaceEmojiTextView: NSTextView, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var openCharacterPalette: (NSTextView) -> Void = { NSApp.orderFrontCharacterPalette($0) }
    private var requestedPickerID = 0
    private var fulfilledPickerID: Int?

    override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
        let storage = textContainer == nil ? NSTextStorage() : nil
        let container: NSTextContainer
        if let textContainer {
            container = textContainer
        } else {
            let layout = NSLayoutManager()
            container = NSTextContainer(size: frame.size)
            storage?.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        withExtendedLifetime(storage) {}
        delegate = self
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        font = .systemFont(ofSize: 18)
        textColor = .labelColor
        insertionPointColor = .labelColor
        drawsBackground = false
        alignment = .center
        textContainerInset = NSSize(width: 4, height: 7)
        isHorizontallyResizable = false
        isVerticallyResizable = false
        self.textContainer?.widthTracksTextView = true
        self.textContainer?.heightTracksTextView = true
        setAccessibilityLabel(String(localized: "Workspace emoji", comment: "Accessible name of the workspace emoji field."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window
            )
        }
        requestPicker(requestedPickerID)
    }

    @objc private func windowBecameKey() {
        requestPicker(requestedPickerID)
    }

    func requestPicker(_ requestID: Int) {
        requestedPickerID = requestID
        guard let window, window.isKeyWindow, fulfilledPickerID != requestID else { return }
        // The field must be attached and first responder before the system picker can insert into it.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, window.isKeyWindow,
                self.requestedPickerID == requestID, self.fulfilledPickerID != requestID, window.makeFirstResponder(self)
            else { return }
            self.setSelectedRange(NSRange(location: 0, length: self.string.utf16.count))
            guard window.firstResponder === self, let inputContext = self.inputContext
            else { return }
            // Reopening from a button must restore the text input client as well as first responder.
            inputContext.activate()
            inputContext.invalidateCharacterCoordinates()
            self.fulfilledPickerID = requestID
            self.openCharacterPalette(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let inserted = (insertString as? NSAttributedString)?.string ?? (insertString as? String)
        // A badge is one value; picker insertion must not depend on its retained selection.
        let range =
            WorkspaceEmoji.validated(inserted) != nil
            ? NSRange(location: 0, length: string.utf16.count) : replacementRange
        super.insertText(insertString, replacementRange: range)
    }

    func textDidChange(_ notification: Notification) {
        let bounded = String(string.unicodeScalars.prefix(64))
        if string != bounded { string = bounded }
        onChange?(bounded)
    }

    override func insertNewline(_ sender: Any?) { onSubmit?() }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { onSubmit?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
}
