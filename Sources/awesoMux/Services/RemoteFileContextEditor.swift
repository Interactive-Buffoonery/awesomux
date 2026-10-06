import AppKit
import AwesoMuxCore
import AwesoMuxConfig
import DesignSystem
import SwiftUI
import Observation

@MainActor
@Observable
final class RemoteFileContextEditor {
    static let shared = RemoteFileContextEditor()
    private(set) var isPresented = false

    private init() {}
    func present(sessionID: TerminalSession.ID, paneID: TerminalPane.ID, store: SessionStore) {
        guard !isPresented, let pane = store.session(id: sessionID)?.layout.pane(id: paneID), pane.executionPlan == .local,
            let origin = RemoteMarkdownReadRouting.origin(sessionID: sessionID, paneID: paneID, store: store),
            let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil
        else { return }
        let sheet = NSWindow()
        sheet.styleMask = [.titled]
        let editor = RemoteFileContextSheet(context: pane.remoteFileContext) { context in
            guard RemoteMarkdownReadRouting.current(origin, store: store) == origin else { return false }
            return store.setRemoteFileContext(
                context, sessionID: sessionID, paneID: paneID, expectedTerminalSessionID: pane.terminalSessionID)
        } dismiss: {
            parent.endSheet(sheet)
        }
        let host = NSHostingController(
            rootView: RemoteFileContextSheetAppearance(
                content: editor, settings: RemoteMarkdownReadRouting.appSettingsStore))
        sheet.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        sheet.setContentSize(host.view.fittingSize)
        isPresented = true
        parent.beginSheet(sheet) { [self] _ in
            sheet.contentViewController = nil
            isPresented = false
        }
    }
}

private struct RemoteFileContextSheetAppearance: View {
    let content: RemoteFileContextSheet
    let settings: AppSettingsStore?
    var body: some View {
        if let settings { content.appearanceBridge(settings) } else { content }
    }
}

private struct RemoteFileContextSheet: View {
    let save: (RemoteFileContext?) -> Bool
    let dismiss: () -> Void
    @State private var alias: String
    @State private var user: String
    @State private var directory: String
    @State private var changed = false
    @FocusState private var focusedField: Field?
    private enum Field { case alias, user, directory }

    init(context: RemoteFileContext?, save: @escaping (RemoteFileContext?) -> Bool, dismiss: @escaping () -> Void) {
        self.save = save
        self.dismiss = dismiss
        _alias = State(initialValue: context?.target.host ?? "")
        _user = State(initialValue: context?.target.user ?? "")
        _directory = State(initialValue: context?.baseDirectory ?? "")
    }

    private var normalizedUser: String {
        user.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedDirectory: String? {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !MarkdownLinkIntercept.containsUnsafePathScalars(value) else { return nil }
        return RemoteMarkdownPath.normalize(value)
    }

    private var validationMessage: String? {
        if alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter an SSH config alias.", comment: "Required-field guidance for remote file context")
        }
        if !alias.isEmpty, RemoteMarkdownReadRouting.configAlias(alias) == nil {
            return String(
                localized: "Use a simple SSH config alias without a username, spaces, or flags.",
                comment: "Inline validation for the remote file alias")
        }
        if !normalizedUser.isEmpty, RemoteMarkdownReadRouting.configAlias(normalizedUser) == nil {
            return String(
                localized: "Use a username without spaces or SSH flags.", comment: "Inline validation for the optional remote file username"
            )
        }
        if directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                localized: "Enter a remote base directory.", comment: "Required-field guidance for the fixed remote file directory")
        }
        if normalizedDirectory == nil {
            return String(
                localized: "Enter an absolute /… or ~/… directory without control or invisible characters.",
                comment: "Inline validation for the fixed remote file directory")
        }
        return nil
    }

    private var context: RemoteFileContext? {
        guard let alias = RemoteMarkdownReadRouting.configAlias(alias),
            normalizedUser.isEmpty || RemoteMarkdownReadRouting.configAlias(normalizedUser) != nil,
            let target = RemoteTarget(user: normalizedUser, host: alias),
            let directory = normalizedDirectory
        else { return nil }
        return RemoteFileContext(target: target, baseDirectory: directory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Set Remote File Context…", comment: "Title for configuring runtime-only remote Markdown file links"))
                .awFont(AwFont.UI.title).accessibilityAddTraits(.isHeader)
            Text(
                String(
                    localized:
                        "Choose a fixed destination and directory for Markdown links in this pane. Click a Markdown filename to open a read-only snapshot and confirm each read. Update this context when you change hosts or directories."
                )
            )
            .fixedSize(horizontal: false, vertical: true)
            TextField(
                String(localized: "File-read SSH config alias", comment: "Label for a simple OpenSSH configuration alias"), text: $alias
            ).focused($focusedField, equals: .alias)
            TextField(String(localized: "SSH user (optional)", comment: "Label for an optional separate SSH username"), text: $user)
                .focused($focusedField, equals: .user)
            TextField(
                String(
                    localized: "Remote base directory (/… or ~/…)", comment: "Label requesting a fixed lexical directory on the remote host"
                ), text: $directory
            )
            .focused($focusedField, equals: .directory)
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(
                String(
                    localized: "Setting this context does not connect over SSH. It lasts only for this pane and is not restored.",
                    comment: "Help describing the runtime-only lifetime of remote file context")
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if changed {
                Text(RemoteMarkdownReadRouting.originChangedMessage).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Cancel editing remote file context"), role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Set Context", comment: "Save the fixed file-read context without connecting")) {
                    guard let context else { return }
                    if save(context) {
                        dismiss()
                    } else if !changed {
                        changed = true
                        TerminalAccessibilityAnnouncer.announce(RemoteMarkdownReadRouting.originChangedMessage)
                    }
                }.disabled(context == nil).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder).awFont(AwFont.UI.body)
        .padding(20).frame(width: 520)
        .onAppear { focusedField = .alias }
        .onChange(of: focusedField) { previous, _ in
            if previous != nil, let validationMessage {
                TerminalAccessibilityAnnouncer.announce(validationMessage)
            }
        }
    }
}
