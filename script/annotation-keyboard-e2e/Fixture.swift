import AppKit
import AwesoMuxCore
import SwiftUI

@main
struct AnnotationKeyboardFixtureApp: App {
    var body: some Scene {
        WindowGroup("Annotation keyboard fixture") {
            AnnotationKeyboardFixtureView()
        }
        .windowResizability(.contentSize)
    }
}

private struct AnnotationKeyboardFixtureView: View {
    @State private var surface = "Comment"
    @State private var saved: [String] = []
    @State private var generation = UUID()
    @State private var enabled = true
    @State private var failSave = false

    private let annotation = PlanAnnotation(id: "fixture", author: .user, payload: "Disposable annotation", anchor: .span)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Surface", selection: $surface) {
                ForEach(["Comment", "Compose", "Document note", "Rich input"], id: \.self) { Text($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Enabled", isOn: $enabled)
                Toggle("Fail save", isOn: $failSave)
                Button("Reset") {
                    saved = []; generation = UUID()
                }
            }
            Group {
                switch surface {
                case "Compose":
                    ComposeCommentPopover(onSave: { text, _ in save(text) }, onCancel: {})
                case "Document note":
                    DocumentNoteSheet(
                        note: nil, onAdd: { save($0) }, onEdit: { _, text in save(text) }, onSetStatus: { _, _ in .saved },
                        onDelete: { _ in .saved }, onClose: {})
                case "Rich input":
                    RichInputComposerSheet(
                        seed: "", title: "Disposable copy composer", reviewedFilePath: "/tmp/annotation-keyboard-fixture.md",
                        receivingTerminal: "Fixture only", capturedWorkingDirectory: "/tmp", isCopy: true,
                        onSend: { text in
                            saved.append(text)
                            return failSave ? .failed("Fixture failure; draft kept") : .sent
                        }, onClose: {})
                default:
                    FullCommentPopover(
                        displayNumber: 1, annotation: annotation, quotedText: "Disposable text", onEdit: { save($0) }, onDelete: { .saved },
                        onSetStatus: { _ in .saved }, onReply: { save($0) })
                }
            }
            .disabled(!enabled)
            .id(generation)
            Divider()
            Text("Submissions: \(saved.count)")
                .accessibilityIdentifier("fixture-submissions")
            ForEach(Array(saved.enumerated()), id: \.offset) { index, text in
                Text("\(index + 1): \(text)")
            }
        }
        .padding(16)
        .frame(width: 700)
        .task {
            if CommandLine.arguments.contains("--self-check") { await selfCheck() }
        }
    }

    private func selfCheck() async {
        typealias Check = AnnotationKeyboardSelfCheck
        var proof: [String: [Check.Probe.Command]] = [:]
        do {
            for target in ["Comment", "Rich input"] {
                saved = []
                failSave = true
                surface = target
                generation = UUID()
                let window = try await Check.ready("fixture window") {
                    NSApp.windows.first { $0.title == "Annotation keyboard fixture" && $0.contentView != nil }
                }
                NSApp.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                _ = try await Check.ready("active fixture") { NSApp.isActive && window.isKeyWindow ? true : nil }
                let editor: NSTextView
                let probe: Check.Probe
                if target == "Comment" {
                    let field = try await Check.ready("reply field") {
                        Check.descendant(NSTextField.self, in: window.contentView!, matching: { $0.placeholderString == "Reply…" })
                    }
                    field.selectText(nil)
                    editor = try await Check.ready("reply field editor") { field.currentEditor() as? NSTextView }
                    probe = Check.Probe(fieldDelegate: field.delegate)
                    field.delegate = probe
                } else {
                    editor = try await Check.ready("rich editor") {
                        Check.descendant(NSTextView.self, in: window.contentView!, matching: { $0.accessibilityLabel() == "Prompt" })
                    }
                    probe = Check.Probe(textDelegate: editor.delegate)
                    editor.delegate = probe
                    try Check.require(window.makeFirstResponder(editor), "rich focus")
                }
                try Check.require(window.firstResponder === editor, "fixture editor is not first responder")
                let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    MainActor.assumeIsolated {
                        probe.deliveredKeys.append(event.keyCode)
                        print(
                            "fixture-event key=\(event.keyCode) repeated=\(event.isARepeat) flags=\(event.modifierFlags.rawValue) current=\(NSApp.currentEvent === event)"
                        )
                    }
                    return event
                }!
                defer { NSEvent.removeMonitor(monitor) }
                editor.insertText("delegate proof", replacementRange: editor.selectedRange())
                await Check.mainTurn()
                if target == "Comment" {
                    let payload = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
                    payload.string = "annotation payload"
                    payload.isEditable = false
                    payload.isSelectable = true
                    window.contentView!.addSubview(payload)
                    try Check.require(window.makeFirstResponder(payload), "readonly payload focus")
                    payload.selectAll(nil)
                    for code: UInt16 in [36, 76] {
                        let count = probe.deliveredKeys.count
                        Check.post(to: window, code: code, flags: .command)
                        _ = try await Check.ready("readonly accept event") { probe.deliveredKeys.count > count ? true : nil }
                        await Check.mainTurn()
                        try Check.require(saved.isEmpty, "readonly focus submitted reply")
                        try Check.require(payload.string == "annotation payload", "readonly payload changed")
                    }
                    payload.removeFromSuperview()
                    let field = try await Check.ready("reply field after readonly focus") {
                        Check.descendant(NSTextField.self, in: window.contentView!, matching: { $0.placeholderString == "Reply…" })
                    }
                    field.selectText(nil)
                    try Check.require(field.currentEditor() === editor, "reply editor ownership changed")
                    try Check.require(editor.string == "delegate proof", "readonly focus changed draft")
                    print("READONLY_REPLY_CHECK_PASS keys=36,76 draft=unchanged callbacks=0")
                }
                for code: UInt16 in [36, 76] {
                    let count = probe.commands.count
                    Check.post(to: window, code: code, repeated: true)
                    _ = try await Check.ready("repeated Return delegate") { probe.commands.count > count ? true : nil }
                    await Check.mainTurn()
                    let command = probe.commands.last!
                    print("fixture-command \(command)")
                    try Check.require(command.selector == "insertNewline:", "repeat did not reach newline delegate")
                    try Check.require(
                        command.keyCode == code && command.repeated == true && command.flags == 0, "missing real current-event context")
                    try Check.require(saved.isEmpty, "repeated Return submitted in \(target)")
                }
                for code: UInt16 in [36, 76] {
                    for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control]] {
                        let count = probe.deliveredKeys.count
                        Check.post(to: window, code: code, flags: flags)
                        _ = try await Check.ready("rejected modified Return event") { probe.deliveredKeys.count > count ? true : nil }
                        await Check.mainTurn()
                        try Check.require(saved.isEmpty, "modified Return submitted in \(target)")
                    }
                }
                if target == "Rich input" {
                    for flags: NSEvent.ModifierFlags in [.shift, .option] {
                        let before = editor.string
                        let count = probe.commands.count
                        Check.post(to: window, code: 36, flags: flags)
                        _ = try await Check.ready("modified Return delegate") { probe.commands.count > count ? true : nil }
                        await Check.mainTurn()
                        try Check.require(editor.string == before + "\n" && saved.isEmpty, "modified Return submitted or lost newline")
                        try Check.require(probe.commands.last?.flags == flags.rawValue, "modified Return current-event flags missing")
                    }
                }
                Check.post(to: window, code: 36)
                _ = try await Check.ready("plain Return positive control") { saved.count == 1 ? true : nil }
                proof[target] = probe.commands
            }
            let output = try JSONEncoder().encode(proof)
            print("ANNOTATION_SELF_CHECK_PASS " + String(decoding: output, as: UTF8.self))
            exit(0)
        } catch {
            print("ANNOTATION_SELF_CHECK_FAIL \(error)")
            exit(1)
        }
    }

    private func save(_ text: String) -> AnnotationSaveOutcome {
        saved.append(text)
        return failSave ? .failed : .saved
    }
}
