import AppKit
import AwesoMuxCore
import AwesoMuxConfig
import SwiftUI
import DesignSystem

/// All remote viewer reads cross this operation-scoped boundary before starting SSH.
@MainActor
enum RemoteMarkdownReadRouting {
    static let authorization = RemoteMarkdownReadAuthorization()
    static var appSettingsStore: AppSettingsStore?
    static var originChangedMessage: String {
        String(
            localized: "The originating pane or document changed. Cancel and open the file again.",
            comment: "Remote Markdown sheet notice when its captured source changes before the read")
    }

    struct Read: Sendable {
        let reference: RemoteMarkdownReference
        let attempt: RemoteMarkdownReadAttempt
        let lifetime = Lifetime()

        @MainActor
        func fetcher(store: SessionStore) -> RemoteMarkdownSnapshotFetcher {
            var fetcher = RemoteMarkdownSnapshotFetcher()
            fetcher.transport = attempt.readPolicy == .confirmationRequired ? .unmanaged : .managed
            fetcher.admission = {
                !lifetime.isCancelled
                    && authorization.validateBeforeTransport(attempt, currentOrigin: current(attempt.origin, store: store))
            }
            return fetcher
        }
    }

    final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    static func wait<T: Sendable>(for read: Read, operation: () async -> T) async -> T {
        if Task.isCancelled { read.lifetime.cancel() }
        return await withTaskCancellationHandler(operation: operation, onCancel: { read.lifetime.cancel() })
    }

    static func origin(
        sessionID: TerminalSession.ID,
        paneID: TerminalPane.ID?,
        documentID: DocumentPane.ID? = nil,
        store: SessionStore
    ) -> RemoteMarkdownReadOrigin? {
        guard let session = store.session(id: sessionID) else { return nil }
        let document = documentID.flatMap { session.layout.firstDocumentGroup?.tab(id: $0) }
        if documentID != nil, document == nil { return nil }
        let pane = paneID.flatMap { session.layout.pane(id: $0) }
        if paneID != nil, pane == nil { return nil }
        guard pane != nil || document != nil else { return nil }
        return RemoteMarkdownReadOrigin(sessionID: sessionID, pane: pane, document: document)
    }

    static func current(_ captured: RemoteMarkdownReadOrigin, store: SessionStore) -> RemoteMarkdownReadOrigin? {
        origin(sessionID: captured.sessionID, paneID: captured.paneID, documentID: captured.documentID, store: store)
    }

    static func isRemoteFileContext(_ pane: TerminalPane) -> Bool {
        pane.executionPlan.remoteTarget != nil || pane.hasManagedSSHObservation
    }

    static func consume(_ read: Read, store: SessionStore) -> Bool {
        guard !Task.isCancelled else {
            authorization.discard(read.attempt)
            return false
        }
        return authorization.consumeBeforeFetch(read.attempt, currentOrigin: current(read.attempt.origin, store: store))
    }

    static func validate(_ read: Read, store: SessionStore) -> Bool {
        authorization.validateAfterFetch(read.attempt, currentOrigin: current(read.attempt.origin, store: store))
    }

    static func authorize(
        path: String,
        origin: RemoteMarkdownReadOrigin,
        store: SessionStore,
        proposedTarget: RemoteTarget? = nil,
        locksPath: Bool = false
    ) async -> Read? {
        guard current(origin, store: store) == origin else { return nil }
        guard !Task.isCancelled else { return nil }
        if origin.documentID == nil, origin.executionPlan?.remoteTarget == nil,
            origin.observedRemoteHost == nil, origin.observedSSHTarget == nil,
            origin.pendingSSHTarget == nil, origin.observedPendingSSHProcess != true
        {
            return nil
        }
        let declared = authorization.authorizeDeclared(origin: origin)
        let target = declared?.target ?? origin.documentIdentity?.remoteTarget
        let normalized = RemoteMarkdownReference.normalizedTypedPath(path)
        if let declared, let normalized,
            let reference = RemoteMarkdownReference.make(typedPath: normalized, target: declared.target)
        {
            return Read(reference: reference, attempt: declared)
        }
        if let declared { authorization.discard(declared) }
        // An observed alias is only an editable suggestion. It never creates authority.
        let observed = origin.observedSSHTarget ?? origin.pendingSSHTarget
        let prefill = observed.flatMap(configAlias) ?? ""
        guard
            let choice = await present(
                target: target,
                suggestedAlias: proposedTarget.map(\.sshDestination) ?? prefill,
                path: path, locksPath: locksPath,
                isCurrent: { current(origin, store: store) == origin }
            ), current(origin, store: store) == origin, !Task.isCancelled,
            let reference = RemoteMarkdownReference.make(typedPath: choice.path, target: choice.target)
        else { return nil }
        let attempt: RemoteMarkdownReadAttempt?
        if target != nil, origin.documentReadPolicy != .confirmationRequired,
            origin.documentID != nil || origin.executionPlan?.remoteTarget != nil
        {
            attempt = authorization.authorizeDeclared(origin: origin, chosenBaseDirectory: choice.base)
        } else {
            attempt = authorization.confirmOneOperation(origin: origin, target: choice.target, chosenBaseDirectory: choice.base)
        }
        guard let attempt else { return nil }
        return Read(reference: reference, attempt: attempt)
    }

    static func configAlias(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-"),
            value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
        else { return nil }
        return value
    }

    struct Choice {
        let target: RemoteTarget
        let path: String
        let base: String?
    }

    private static var presenting = false

    private static func present(
        target: RemoteTarget?, suggestedAlias: String, path: String, locksPath: Bool, isCurrent: @escaping () -> Bool
    ) async -> Choice? {
        guard !presenting, let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil else { return nil }
        presenting = true
        defer { presenting = false }
        return await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled]
            var completed = false
            let view = RemoteMarkdownReadConfirmationSheet(
                target: target, suggestedAlias: suggestedAlias, initialPath: path, locksPath: locksPath, isCurrent: isCurrent
            ) { choice in
                guard !completed else { return }
                completed = true
                parent.endSheet(sheet)
                sheet.contentViewController = nil
                continuation.resume(returning: choice)
            }
            let host = NSHostingController(rootView: RemoteMarkdownReadSheetAppearance(content: view, settings: appSettingsStore))
            sheet.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            sheet.setContentSize(host.view.fittingSize)
            parent.beginSheet(sheet)
        }
    }
}

private struct RemoteMarkdownReadSheetAppearance: View {
    let content: RemoteMarkdownReadConfirmationSheet
    let settings: AppSettingsStore?
    var body: some View {
        if let settings { content.appearanceBridge(settings) } else { content }
    }
}

private struct RemoteMarkdownReadConfirmationSheet: View {
    let target: RemoteTarget?
    let complete: (RemoteMarkdownReadRouting.Choice?) -> Void
    let locksPath: Bool
    let isCurrent: () -> Bool
    @State private var originChanged = false
    @State private var alias: String
    @State private var path: String
    @State private var base = ""
    @FocusState private var focused: Field?
    private enum Field { case alias, path, base }

    init(
        target: RemoteTarget?, suggestedAlias: String, initialPath: String,
        locksPath: Bool, isCurrent: @escaping () -> Bool,
        complete: @escaping (RemoteMarkdownReadRouting.Choice?) -> Void
    ) {
        self.target = target
        self.complete = complete
        self.locksPath = locksPath
        self.isCurrent = isCurrent
        _alias = State(initialValue: suggestedAlias)
        _path = State(initialValue: initialPath)
    }

    private var chosenTarget: RemoteTarget? {
        target ?? RemoteMarkdownReadRouting.configAlias(alias).flatMap { RemoteTarget(parsing: $0) }
    }

    private var resolved: String? {
        guard let resolved = RemoteMarkdownPath.resolve(path.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base),
            let supported = RemoteMarkdownReference.normalizedTypedPath(resolved)
        else { return nil }
        return supported
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Open Remote Markdown", comment: "Title for confirming one remote Markdown file read")).awFont(
                AwFont.UI.title
            ).accessibilityAddTraits(.isHeader)
            Text(
                String(
                    localized: "Read one file over SSH as a read-only snapshot.",
                    comment: "Caption explaining the one-operation remote Markdown confirmation")
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let target {
                LabeledContent(
                    String(localized: "File-read destination", comment: "Label for the independently authorized SSH file-read destination"),
                    value: target.sshDestination)
            } else {
                Text(String(localized: "File-read SSH config alias", comment: "Label for the OpenSSH config alias used for this file read"))
                TextField(
                    String(
                        localized: "Alias from ~/.ssh/config",
                        comment: "Placeholder requesting an OpenSSH config alias, not SSH command flags"), text: $alias
                )
                .textFieldStyle(.roundedBorder).focused($focused, equals: .alias)
                .accessibilityLabel(
                    String(localized: "File-read SSH config alias", comment: "Label for the OpenSSH config alias used for this file read"))
                Text(
                    String(
                        localized:
                            "Choose the destination for this read. Existing terminal SSH options and connections cannot be reused; configure an alias in OpenSSH.",
                        comment: "Help explaining independent SSH file-read configuration")
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(String(localized: "Remote path", comment: "Label for the remote Markdown file path"))
            if locksPath {
                Text(path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(
                    String(
                        localized: "/path/file.md, ~/file.md, or relative file.md",
                        comment: "Placeholder showing supported remote Markdown path forms"), text: $path
                )
                .textFieldStyle(.roundedBorder).focused($focused, equals: .path)
                .accessibilityLabel(
                    String(localized: "Remote Markdown path", comment: "Accessibility label for the remote Markdown file path field"))
            }
            if !path.hasPrefix("/"), !path.hasPrefix("~") {
                Text(
                    String(
                        localized: "Choose a remote base directory",
                        comment: "Label requiring an explicitly chosen remote directory for a relative link"))
                TextField(
                    String(
                        localized: "/remote/directory or ~/directory",
                        comment: "Placeholder for an absolute or home-relative remote base directory"), text: $base
                )
                .textFieldStyle(.roundedBorder).focused($focused, equals: .base)
                .accessibilityLabel(
                    String(
                        localized: "Chosen remote base directory",
                        comment: "Accessibility label for the explicitly chosen remote base directory"))
                Text(
                    String(
                        localized:
                            "The terminal's current directory is unavailable. Choose a base directory or replace the path with a full /… or ~/… path.",
                        comment: "Help explaining how to resolve a remote relative link without trustworthy cwd metadata")
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let chosenTarget, let resolved {
                LabeledContent(
                    String(localized: "Destination", comment: "Label for the exact SSH destination in the file-read preview"),
                    value: chosenTarget.sshDestination)
                LabeledContent(
                    String(localized: "Resolved remote path", comment: "Label for the exact lexical remote path in the file-read preview"),
                    value: resolved
                )
                .textSelection(.enabled)
            }
            if originChanged {
                Text(RemoteMarkdownReadRouting.originChangedMessage)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel", comment: "Cancel one remote Markdown file read"), role: .cancel) { complete(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Read File", comment: "Confirm the displayed SSH destination and path for one read")) {
                    guard let chosenTarget, let resolved else { return }
                    guard isCurrent() else {
                        if !originChanged {
                            originChanged = true
                            TerminalAccessibilityAnnouncer.announce(RemoteMarkdownReadRouting.originChangedMessage)
                        }
                        return
                    }
                    complete(.init(target: chosenTarget, path: resolved, base: RemoteMarkdownPath.normalize(base)))
                }.keyboardShortcut(.defaultAction).disabled(chosenTarget == nil || resolved == nil)
            }
        }
        .awFont(AwFont.UI.body)
        .padding(20).frame(minWidth: 420, idealWidth: 520)
        .onAppear { focused = target == nil ? .alias : .path }
    }
}
