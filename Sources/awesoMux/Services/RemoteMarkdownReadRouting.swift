import AppKit
import AwesoMuxCore
import SwiftUI

/// All remote viewer reads cross this operation-scoped boundary before starting SSH.
@MainActor
enum RemoteMarkdownReadRouting {
    static let authorization = RemoteMarkdownReadAuthorization()

    struct Read {
        let reference: RemoteMarkdownReference
        let attempt: RemoteMarkdownReadAttempt

        var fetcher: RemoteMarkdownSnapshotFetcher {
            var fetcher = RemoteMarkdownSnapshotFetcher()
            fetcher.transport = attempt.readPolicy == .confirmationRequired ? .unmanaged : .managed
            return fetcher
        }
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
            let host = NSHostingController(rootView: view)
            sheet.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            sheet.setContentSize(host.view.fittingSize)
            parent.beginSheet(sheet)
        }
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
            Text("Open Remote Markdown").font(.title2).accessibilityAddTraits(.isHeader)
            Text("Read one file over SSH as a read-only snapshot.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let target {
                LabeledContent("File-read destination", value: target.sshDestination)
            } else {
                Text("File-read SSH config alias")
                TextField("Alias from ~/.ssh/config", text: $alias)
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .alias)
                    .accessibilityLabel("File-read SSH config alias")
                Text(
                    "Choose the destination for this read. Existing terminal SSH options and connections cannot be reused; configure an alias in OpenSSH."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Remote path")
            if locksPath {
                Text(path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("/path/file.md, ~/file.md, or relative file.md", text: $path)
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .path)
                    .accessibilityLabel("Remote Markdown path")
            }
            if !path.hasPrefix("/"), !path.hasPrefix("~") {
                Text("Choose a remote base directory")
                TextField("/remote/directory or ~/directory", text: $base)
                    .textFieldStyle(.roundedBorder).focused($focused, equals: .base)
                    .accessibilityLabel("Chosen remote base directory")
                Text(
                    "The terminal's current directory is unavailable. Choose a base directory or replace the path with a full /… or ~/… path."
                )
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let chosenTarget, let resolved {
                LabeledContent("Destination", value: chosenTarget.sshDestination)
                LabeledContent("Resolved remote path", value: resolved)
                    .textSelection(.enabled)
            }
            if originChanged {
                Text("The originating pane or document changed. Cancel and open the file again.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { complete(nil) }.keyboardShortcut(.cancelAction)
                Button("Read File") {
                    guard let chosenTarget, let resolved else { return }
                    guard isCurrent() else {
                        originChanged = true
                        return
                    }
                    complete(.init(target: chosenTarget, path: resolved, base: RemoteMarkdownPath.normalize(base)))
                }.keyboardShortcut(.defaultAction).disabled(chosenTarget == nil || resolved == nil)
            }
        }
        .padding(20).frame(minWidth: 420, idealWidth: 520)
        .onAppear { focused = target == nil ? .alias : .path }
    }
}
