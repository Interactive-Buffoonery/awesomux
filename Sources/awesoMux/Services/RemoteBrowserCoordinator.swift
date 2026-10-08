import AppKit
import AwesoMuxBridgeProtocol
import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import SwiftUI

@MainActor
final class RemoteBrowserCoordinator {
    private static var presentedRequest: UUID?
    private static var recentRequests: [Date] = []

    private let token: String
    private let session: String
    private weak var settings: AppSettingsStore?
    private let destination: () -> String?
    private let window: () -> NSWindow?
    private let isConnected: (BridgeConnectionActor.Generation) async -> Bool
    private let reply: (BridgeEnvelope, BridgeConnectionActor.Generation) async -> Void
    private var pending: Task<Void, Never>?
    private var generation: BridgeConnectionActor.Generation?
    private var alert: NSAlert?

    init(
        token: String,
        session: String,
        settings: AppSettingsStore?,
        destination: @escaping () -> String?,
        window: @escaping () -> NSWindow?,
        isConnected: @escaping (BridgeConnectionActor.Generation) async -> Bool,
        reply: @escaping (BridgeEnvelope, BridgeConnectionActor.Generation) async -> Void
    ) {
        self.token = token
        self.session = session
        self.settings = settings
        self.destination = destination
        self.window = window
        self.isConnected = isConnected
        self.reply = reply
    }

    func receive(_ envelope: BridgeEnvelope, generation: BridgeConnectionActor.Generation) {
        guard case .browserOpenRequest(let request) = envelope.message else { return }
        guard pending == nil else {
            Task { await send(.busy, id: envelope.id, generation: generation) }
            return
        }
        self.generation = generation
        pending = Task { [weak self] in
            guard let self else { return }
            let outcome = await process(request, generation: generation)
            if !Task.isCancelled { await send(outcome, id: envelope.id, generation: generation) }
            if self.generation == generation {
                pending = nil
                self.generation = nil
            }
        }
    }

    func connectionLost(_ generation: BridgeConnectionActor.Generation) {
        guard self.generation == generation else { return }
        teardown()
    }

    func teardown() {
        pending?.cancel()
        pending = nil
        generation = nil
        if let alert, let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
    }

    private func send(_ outcome: BrowserOpenOutcome, id: String, generation: BridgeConnectionActor.Generation) async {
        await reply(
            BridgeEnvelope(
                token: token, session: session, id: UUID().uuidString,
                ts: Date().timeIntervalSince1970,
                message: .browserOpenResult(BrowserOpenResult(inReplyTo: id, outcome: outcome))
            ), generation
        )
    }

    private func process(
        _ request: BrowserOpenRequest, generation: BridgeConnectionActor.Generation
    ) async -> BrowserOpenOutcome {
        guard let settings, settings.workspaces.value.remoteBrowserEnabled else { return .disabled }
        guard let source = destination() else { return .disconnected }
        guard let url = Self.webURL(request.url), let origin = Self.origin(url) else { return .invalid }
        let deadline = min(Date(timeIntervalSince1970: request.expiresAt), Date().addingTimeInterval(120))
        guard deadline > Date() else { return .expired }

        // This cap also covers remembered permissions and survives reconnects.
        Self.recentRequests.removeAll { Date().timeIntervalSince($0) > 10 }
        guard Self.recentRequests.count < 3 else { return .rateLimited }
        Self.recentRequests.append(Date())

        let safeToRemember: Bool
        let warning: String?
        switch URLClassifier.classify(url) {
        case .openDirect:
            safeToRemember = true
            warning = nil
        case .blockConfirm(let reason, let displayHost, let punycodeHost):
            safeToRemember = false
            warning = GhosttyRuntime.alertBodyForBlockedURL(
                url, reason: reason, displayHost: displayHost, punycodeHost: punycodeHost
            )
        }
        let wasRemembered =
            safeToRemember
            && settings.workspaces.value.remoteBrowserAllowedOrigins[source, default: []].contains(origin)
        var remember = false
        if !wasRemembered {
            guard Self.presentedRequest == nil, let parent = window(), parent.attachedSheet == nil else { return .busy }
            let presentationID = UUID()
            Self.presentedRequest = presentationID
            defer { if Self.presentedRequest == presentationID { Self.presentedRequest = nil } }
            let choice = RemoteBrowserPromptChoice()
            let alert = NSAlert()
            alert.messageText = String(localized: "Open this link on your Mac?")
            alert.informativeText = String(localized: "A program on \(source) wants to open this page in your default browser.")
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Open Link"))
            alert.addButton(withTitle: String(localized: "Copy Link"))
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            alert.buttons[2].keyEquivalent = ""
            let view = NSHostingView(
                rootView: RemoteBrowserPromptView(
                    source: source, url: url, warning: warning, choice: choice,
                    canRemember: safeToRemember && !settings.isDiskConfigInvalid
                ))
            view.setFrameSize(NSSize(width: 420, height: warning == nil ? 180 : 300))
            alert.accessoryView = view
            self.alert = alert
            let expiry = DispatchWorkItem { [weak alert] in
                MainActor.assumeIsolated {
                    guard let alert, let parent = alert.window.sheetParent else { return }
                    parent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: expiry)
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
            }
            expiry.cancel()
            self.alert = nil
            guard !Task.isCancelled, await isConnected(generation), destination() == source else { return .disconnected }
            guard deadline > Date() else { return .expired }
            guard settings.workspaces.value.remoteBrowserEnabled else { return .disabled }
            if response == .alertThirdButtonReturn {
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(url.absoluteString, forType: .string) ? .copied : .failed
            }
            guard response == .alertSecondButtonReturn else { return .cancelled }
            remember = choice.remember && safeToRemember
        }

        guard !Task.isCancelled, await isConnected(generation), destination() == source else { return .disconnected }
        guard deadline > Date() else { return .expired }
        guard settings.workspaces.value.remoteBrowserEnabled else { return .disabled }
        // A grant revoked while the connection check awaited must not auto-open.
        if wasRemembered && !settings.workspaces.value.remoteBrowserAllowedOrigins[source, default: []].contains(origin) {
            return .cancelled
        }
        guard NSWorkspace.shared.open(url) else { return .failed }
        if remember, !settings.isDiskConfigInvalid {
            settings.workspaces.update { config in
                if !config.remoteBrowserAllowedOrigins[source, default: []].contains(origin) {
                    config.remoteBrowserAllowedOrigins[source, default: []].append(origin)
                }
            }
        }
        return .opened
    }

    static func webURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 4096,
            !raw.unicodeScalars.contains(where: GhosttyRuntime.isUnsafeAlertBodyScalar),
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
            let host = url.host, !host.isEmpty,
            url.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        return url
    }

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
