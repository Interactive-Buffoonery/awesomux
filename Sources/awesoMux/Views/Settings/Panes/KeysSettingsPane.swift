import AppKit
import AwesoMuxConfig
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

struct KeysSettingsPane: View {
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Environment(CustomCommandStore.self) private var customCommandStore
    @State private var editorRequest: CustomCommandEditorRequest?
    @State private var removalRequest: CustomCommand?
    @State private var collision: ShortcutCollisionMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(index: 1, title: "Cheatsheet") {
                SettingsField(
                    label: "Show cheatsheet",
                    hint: "Open the searchable keyboard shortcuts overlay.",
                    isFirst: true
                ) {
                    Button("Show Cheatsheet") {
                        NotificationCenter.default.post(
                            name: .awesoMuxKeyboardCheatsheetRequested,
                            object: nil
                        )
                    }
                    .buttonStyle(.bordered)
                }

                SettingsField(
                    label: "Custom shortcuts",
                    hint: "Stored in config.toml and applied to menus and the command palette."
                ) {
                    Button("Reset All") {
                        appSettingsStore.keyboard.update { $0.shortcuts.removeAll() }
                        collision = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(appSettingsStore.keyboard.value.shortcuts.isEmpty)
                }
            }

            if let collision {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.aw.peach)
                        .accessibilityHidden(true)
                    Text(collision.text)
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .fill(Color.aw.surface.elevated)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AwRadius.button)
                        .stroke(Color.aw.border, lineWidth: 0.5)
                }
                .padding(.bottom, 8)
            }

            SettingsSection(index: 2, title: "Ghostty keybinds") {
                SettingsField(
                    label: "App actions",
                    hint: "Ghostty keybinds for app, window, workspace, split, config, and command-palette actions are ignored here. If the same chord is an awesoMux menu shortcut, awesoMux handles it first.",
                    isFirst: true
                ) {
                    Text("Use awesoMux shortcuts")
                        .foregroundStyle(Color.aw.text2)
                }
            }

            ForEach(indexedSections, id: \.section.id) { indexed in
                KeysSection(
                    index: indexed.index,
                    section: indexed.section,
                    customIDs: Set(appSettingsStore.keyboard.value.shortcuts.keys),
                    onCapture: assignShortcut,
                    onReset: resetShortcut
                )
            }
            customCommandsSection
        }
        .sheet(item: $editorRequest) { request in
            CustomCommandEditorSheet(
                editing: request.command,
                onCancel: { editorRequest = nil },
                onSave: { name, command in
                    // Dismissal is gated on the store accepting the values, so
                    // a sheet-vs-store validation drift can't silently drop a
                    // save — a rejected save keeps the sheet open.
                    let saved: Bool
                    if let existing = request.command {
                        saved = customCommandStore.update(
                            id: existing.id,
                            name: name,
                            command: command
                        )
                    } else {
                        saved = customCommandStore.add(name: name, command: command) != nil
                    }
                    if saved {
                        editorRequest = nil
                    }
                }
            )
        }
        .confirmationDialog(
            removalRequest.map { command in
                String(
                    localized: "Remove “\(command.name)”?",
                    comment: "Title of the confirmation dialog before deleting a custom command"
                )
            } ?? "",
            isPresented: Binding(
                get: { removalRequest != nil },
                set: { isPresented in
                    if !isPresented {
                        removalRequest = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: removalRequest
        ) { command in
            Button(String(
                localized: "Remove",
                comment: "Destructive confirmation button that deletes a custom command"
            ), role: .destructive) {
                customCommandStore.remove(id: command.id)
                removalRequest = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(String(
                localized: "This can't be undone.",
                comment: "Message of the confirmation dialog before deleting a custom command"
            ))
        }
    }

    private var customCommandsSection: some View {
        SettingsSection(
            index: indexedSections.count + 3,
            title: String(
                localized: "Custom Commands",
                comment: "Keys settings section title for user-defined command shortcuts"
            ),
            subtitle: String(
                localized: "Saved shell commands that appear in the command palette and run in a new workspace tab.",
                comment: "Keys settings section subtitle explaining custom command shortcuts"
            )
        ) {
            ForEach(
                Array(customCommandStore.commands.enumerated()),
                id: \.element.id
            ) { index, command in
                SettingsField(
                    label: command.name,
                    hint: command.command,
                    // The hint is the actual command, not guidance — promote
                    // it above the text3 guidance contrast and cap its height.
                    hintColor: Color.aw.text2,
                    hintLineLimit: 2,
                    isFirst: index == 0
                ) {
                    HStack(spacing: 8) {
                        Button(String(
                            localized: "Edit…",
                            comment: "Button that opens the editor for an existing custom command"
                        )) {
                            editorRequest = CustomCommandEditorRequest(command: command)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(String(
                            localized: "Edit \(command.name)",
                            comment: "Accessibility label for the edit button of a named custom command"
                        ))

                        Button(String(
                            localized: "Remove",
                            comment: "Button that deletes a custom command"
                        ), role: .destructive) {
                            removalRequest = command
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(String(
                            localized: "Remove \(command.name)",
                            comment: "Accessibility label for the remove button of a named custom command"
                        ))
                    }
                }
            }

            SettingsField(
                label: String(
                    localized: "New command",
                    comment: "Settings field label for the add-custom-command button"
                ),
                hint: String(
                    localized: "Give it a name and a single-line shell command.",
                    comment: "Settings field hint for the add-custom-command button"
                ),
                isFirst: customCommandStore.commands.isEmpty
            ) {
                Button(String(
                    localized: "Add Command…",
                    comment: "Button that opens the editor to create a custom command"
                )) {
                    editorRequest = CustomCommandEditorRequest(command: nil)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private struct IndexedSection {
        let index: Int
        let section: KeyboardShortcutSection
    }

    private var indexedSections: [IndexedSection] {
        KeyboardShortcutCatalog.settingsSections(keyboard: appSettingsStore.keyboard.value)
            .enumerated()
            .map { offset, section in
                IndexedSection(index: offset + 3, section: section)
            }
    }

    private func assignShortcut(_ candidate: ShortcutBindingConfig, to bindingID: String) {
        if let message = KeyboardShortcutCatalog.validationMessage(for: candidate) {
            collision = ShortcutCollisionMessage(text: message)
            return
        }

        var keyboard = appSettingsStore.keyboard.value
        keyboard.shortcuts[bindingID] = candidate
        if let duplicate = KeyboardShortcutCatalog.collision(
            for: candidate,
            assigning: bindingID,
            keyboard: appSettingsStore.keyboard.value
        ) {
            collision = ShortcutCollisionMessage(
                text: "That shortcut is already used by \(duplicate.action)."
            )
            return
        }

        appSettingsStore.keyboard.update { $0 = keyboard }
        collision = nil
    }

    private func resetShortcut(_ bindingID: String) {
        appSettingsStore.keyboard.update { $0.shortcuts.removeValue(forKey: bindingID) }
        collision = nil
    }
}

private struct KeysSection: View {
    let index: Int
    let section: KeyboardShortcutSection
    let customIDs: Set<String>
    let onCapture: (ShortcutBindingConfig, String) -> Void
    let onReset: (String) -> Void

    var body: some View {
        SettingsSection(index: index, title: section.title) {
            ForEach(Array(section.entries.enumerated()), id: \.element.id) { rowIndex, entry in
                KeysRow(
                    entry: entry,
                    isFirst: rowIndex == 0,
                    customIDs: customIDs,
                    onCapture: onCapture,
                    onReset: onReset
                )
            }
        }
    }
}

private struct KeysRow: View {
    let entry: KeyboardShortcutEntry
    let isFirst: Bool
    let customIDs: Set<String>
    let onCapture: (ShortcutBindingConfig, String) -> Void
    let onReset: (String) -> Void

    var body: some View {
        SettingsField(label: entry.action, isFirst: isFirst) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(entry.bindings.enumerated()), id: \.element.id) { index, binding in
                    HStack(spacing: 8) {
                        if index > 0 {
                            Text("or")
                                .awFont(AwFont.Mono.kbd)
                                .foregroundStyle(Color.aw.textFaint)
                                .accessibilityHidden(true)
                        }
                        ShortcutChordView(binding: binding)
                        ShortcutCaptureButton(binding: binding) { captured in
                            onCapture(captured, binding.id)
                        }
                        Button("Reset") {
                            onReset(binding.id)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!customIDs.contains(binding.id))
                    }
                }
            }
        }
    }
}

/// Sheet request: `command == nil` creates, otherwise edits that command.
private struct CustomCommandEditorRequest: Identifiable {
    let id = UUID()
    let command: CustomCommand?
}

/// Editor form for a custom command. Follows the `WorkspaceGroupCreateSheet`
/// form-sheet precedent: the Save gate lives here in the content (own Save
/// button, disabled until valid) rather than on any modal chrome.
private struct CustomCommandEditorSheet: View {
    let editing: CustomCommand?
    let onCancel: () -> Void
    let onSave: (_ name: String, _ command: String) -> Void

    @State private var draftName: String
    @State private var draftCommand: String
    @FocusState private var isNameFocused: Bool

    init(
        editing: CustomCommand?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (_ name: String, _ command: String) -> Void
    ) {
        self.editing = editing
        self.onCancel = onCancel
        self.onSave = onSave
        _draftName = State(initialValue: editing?.name ?? "")
        _draftCommand = State(initialValue: editing?.command ?? "")
    }

    var body: some View {
        let sanitizedName = CustomCommandStore.sanitizedName(draftName)
        let trimmedCommand = CustomCommandStore.trimmedCommand(draftCommand)
        let nameValidation = nameValidationMessage(sanitizedName: sanitizedName)
        let commandValidation = commandValidationMessage(trimmedCommand: trimmedCommand)
        let validation = nameValidation ?? commandValidation
        let canSave = validation == nil

        return VStack(alignment: .leading, spacing: 16) {
            Text(sheetTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Command name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .focused($isNameFocused)
                    .accessibilityLabel("Custom command name")
                    .accessibilityHint(
                        nameValidation ?? "",
                        isEnabled: nameValidation != nil
                    )
                    .onSubmit {
                        submit(
                            name: sanitizedName,
                            command: trimmedCommand,
                            canSave: canSave,
                            validation: validation
                        )
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Shell command", text: $draftCommand)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .font(.body.monospaced())
                    .accessibilityLabel("Shell command")
                    .accessibilityHint(
                        commandValidation ?? "",
                        isEnabled: commandValidation != nil
                    )
                    .onSubmit {
                        submit(
                            name: sanitizedName,
                            command: trimmedCommand,
                            canSave: canSave,
                            validation: validation
                        )
                    }
            }

            if let validation {
                // Symbol + color so the error state doesn't rely on color
                // alone; the message is also attached to the offending field
                // as its accessibility hint above.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(validation)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(Color.aw.red)
            }

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    submit(
                        name: sanitizedName,
                        command: trimmedCommand,
                        canSave: canSave,
                        validation: validation
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                // Conditional hint on one stable button identity — an
                // if/else over two button copies resets focus mid-edit.
                .accessibilityHint(
                    validation ?? String(
                        localized: "Enter a name and a command to enable Save",
                        comment: "Fallback accessibility hint on the disabled custom-command Save button"
                    ),
                    isEnabled: !canSave
                )
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sheetTitle)
        .onAppear {
            isNameFocused = true
        }
    }

    private var sheetTitle: String {
        editing == nil
            ? String(
                localized: "New Custom Command",
                comment: "Title of the sheet that creates a custom command"
            )
            : String(
                localized: "Edit Custom Command",
                comment: "Title of the sheet that edits an existing custom command"
            )
    }

    private func nameValidationMessage(sanitizedName: String) -> String? {
        guard sanitizedName.isEmpty else {
            return nil
        }
        return draftName.isEmpty
            ? String(
                localized: "Enter a name.",
                comment: "Validation message when the custom command name is empty"
            )
            : String(
                localized: "Enter a visible name.",
                comment: "Validation message when the custom command name has no visible characters"
            )
    }

    /// Mirrors every `CustomCommandStore.validated` command rule — the store
    /// re-checks on save, and a message missing here would surface as a
    /// disabled-looking Save with no explanation.
    private func commandValidationMessage(trimmedCommand: String) -> String? {
        if CustomCommandStore.commandHasEmbeddedNewline(draftCommand) {
            return String(
                localized: "Commands must be a single line — remove the line breaks.",
                comment: "Validation message when the custom command text contains embedded newlines"
            )
        }

        if CustomCommandStore.commandHasDisallowedScalar(draftCommand) {
            return String(
                localized: "Commands can't contain control or invisible characters.",
                comment: "Validation message when the custom command text contains control, bidirectional-override, or other invisible characters"
            )
        }

        if CustomCommandStore.commandExceedsLengthCap(draftCommand) {
            return String(
                localized: "That command is too long — the limit is 4,096 bytes.",
                comment: "Validation message when the custom command text exceeds the stored-command length cap"
            )
        }

        if trimmedCommand.isEmpty {
            return String(
                localized: "Enter a command.",
                comment: "Validation message when the custom command text is empty"
            )
        }

        return nil
    }

    private func submit(
        name: String,
        command: String,
        canSave: Bool,
        validation: String?
    ) {
        guard canSave else {
            // Return-key submits give no visual response when rejected; speak
            // the reason so VoiceOver users aren't left with silence.
            if let validation {
                AccessibilityNotification.Announcement(validation).post()
            }
            return
        }
        onSave(name, command)
    }
}

private struct ShortcutCaptureButton: View {
    let binding: KeyBinding
    let onCapture: (ShortcutBindingConfig) -> Void
    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        Button(isCapturing ? "Press Keys" : "Record") {
            isCapturing.toggle()
        }
        .buttonStyle(.bordered)
        .onChange(of: isCapturing) { _, capturing in
            capturing ? startCapture() : stopCapture()
        }
        .onDisappear {
            stopCapture()
        }
        .accessibilityLabel("Record shortcut for \(binding.action)")
    }

    private func startCapture() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isCapturing else { return event }
            if ShortcutCapture.shouldCancel(event) {
                isCapturing = false
                return nil
            }
            guard let captured = ShortcutCapture.capturedBinding(from: event) else {
                NSSound.beep()
                return nil
            }
            onCapture(captured)
            isCapturing = false
            return nil
        }
    }

    private func stopCapture() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isCapturing = false
    }
}

enum ShortcutCapture {
    static func shouldCancel(_ event: NSEvent) -> Bool {
        event.keyCode == UInt16(kVK_Escape)
            && ShortcutEventMatcher.normalizedModifierFlags(for: event).isEmpty
    }

    static func capturedBinding(from event: NSEvent) -> ShortcutBindingConfig? {
        guard let key = ShortcutKeyResolver.configKey(for: event) else {
            return nil
        }
        let modifiers = ShortcutEventMatcher.normalizedModifierFlags(for: event)
            .shortcutModifiers
        return ShortcutBindingConfig(key: key, modifiers: modifiers)
    }
}

private struct ShortcutCollisionMessage: Equatable {
    let text: String
}

private extension NSEvent.ModifierFlags {
    var shortcutModifiers: [ShortcutModifier] {
        [
            contains(.control) ? .control : nil,
            contains(.option) ? .option : nil,
            contains(.shift) ? .shift : nil,
            contains(.command) ? .command : nil
        ].compactMap { $0 }
    }
}
