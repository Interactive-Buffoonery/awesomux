import AwesoMuxCore
import SwiftUI

/// Hosts the existing file browser before a document has been selected.
struct DocumentFileBrowserPaneView: View {
    let group: AwesoMuxCore.DocumentGroup
    let session: TerminalSession
    let sessionStore: SessionStore
    let runtime: GhosttyRuntime
    @Environment(DocumentComposeTabActionHandler.self) private var documentTabActions
    @State private var fileBrowserFocusRequestID: UUID?

    private var rootURL: URL? {
        return DocumentFileBrowserView.rootURL(
            in: session,
            associatedWith: group.browserSourcePaneID
        )
    }

    var body: some View {
        DocumentFileBrowserView(
            rootURL: rootURL,
            currentFileURL: nil,
            onOpen: open,
            onCancel: close,
            focusRequestID: fileBrowserFocusRequestID,
            cancelLabel: String(
                localized: "Close Files",
                comment: "Accessible label for closing a browser with no open document"
            ),
            noDirectoryDetail: String(
                localized: "This Files view no longer has a local directory.",
                comment: "Empty-state detail shown when a browser-only file view cannot inspect its source terminal"
            )
        )
        .onAppear(perform: consumeFileBrowserRequest)
        .onChange(of: documentTabActions.fileBrowserRequest?.id) { _, _ in
            consumeFileBrowserRequest()
        }
        .onDisappear {
            documentTabActions.clearFileBrowserRequest(
                in: session.id,
                groupID: group.id,
                documentID: nil
            )
        }
    }

    private func open(_ fileURL: URL) {
        guard
            sessionStore.selectedSessionID == session.id,
            let currentSession = sessionStore.session(id: session.id),
            let currentGroup = currentSession.layout.documentGroup(id: group.id),
            currentGroup.isBrowserOnly,
            currentGroup.browserSourcePaneID == group.browserSourcePaneID,
            let effectiveSource = DocumentFileBrowserView.sourcePane(
                in: currentSession,
                associatedWith: group.browserSourcePaneID
            ),
            ExecutionContext(plan: effectiveSource.executionPlan)
                .capability(.inspectLocalFilesystem).isAllowed
        else {
            return
        }
        let association = group.browserSourcePaneID.flatMap {
            currentSession.layout.pane(id: $0)?.id
        }
        _ = sessionStore.openDocumentPane(
            fileURL: fileURL,
            in: session.id,
            associatedWith: association,
            associationPolicy: .preserveNil
        )
    }

    private func close() {
        guard sessionStore.closeFileBrowser(in: session.id) else { return }
        DispatchQueue.main.async {
            guard
                self.sessionStore.selectedSessionID == self.session.id,
                let currentSession = self.sessionStore.session(id: self.session.id),
                let paneID = Self.closeFocusPaneID(
                    in: currentSession,
                    preferredSourcePaneID: self.group.browserSourcePaneID
                )
            else {
                return
            }
            self.runtime.focusSurface(toPane: paneID)
        }
    }

    static func closeFocusPaneID(
        in session: TerminalSession,
        preferredSourcePaneID: TerminalPane.ID?
    ) -> TerminalPane.ID? {
        preferredSourcePaneID.flatMap { session.layout.pane(id: $0)?.id }
            ?? session.layout.pane(id: session.activePaneID)?.id
    }

    private func consumeFileBrowserRequest() {
        guard
            let request = documentTabActions.consumeFileBrowserRequest(
                in: session.id,
                groupID: group.id,
                documentID: nil
            )
        else { return }
        guard
            sessionStore.selectedSessionID == session.id,
            let currentSession = sessionStore.session(id: session.id),
            let currentGroup = currentSession.layout.documentGroup(id: group.id),
            currentGroup.isBrowserOnly,
            currentGroup.browserSourcePaneID == group.browserSourcePaneID
        else {
            return
        }
        fileBrowserFocusRequestID = request.id
    }
}
