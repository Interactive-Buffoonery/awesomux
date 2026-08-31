import AppKit
import AwesoMuxCore

struct BridgePreflightDependencies {
    let resolveRemoteHome: @MainActor (String, RemoteTarget) async -> String?
    let helperSupportsBridge: @MainActor (String, RemoteTarget, String) async -> Bool
    let offerHelperSetup:
        @MainActor (
            String,
            RemoteTarget,
            String,
            String,
            NSWindow?,
            @escaping @MainActor () -> Bool
        ) async -> Bool
    let attach:
        @MainActor (
            BridgeAttachPreflight,
            BridgeAttachPreflight.Request
        ) async -> BridgeAttachPreflight.Outcome
    let acknowledgeReady: @MainActor (BridgeAttachPreflight, String) async -> Void

    init(
        resolveRemoteHome: @escaping @MainActor (String, RemoteTarget) async -> String?,
        helperSupportsBridge: @escaping @MainActor (String, RemoteTarget, String) async -> Bool,
        offerHelperSetup:
            @escaping @MainActor (
                String,
                RemoteTarget,
                String,
                String,
                NSWindow?,
                @escaping @MainActor () -> Bool
            ) async -> Bool = { _, _, _, _, _, _ in false },
        attach:
            @escaping @MainActor (
                BridgeAttachPreflight,
                BridgeAttachPreflight.Request
            ) async -> BridgeAttachPreflight.Outcome,
        acknowledgeReady: @escaping @MainActor (BridgeAttachPreflight, String) async -> Void = {
            preflight,
            token in
            await preflight.completeReadyOutcome(token: token)
        }
    ) {
        self.resolveRemoteHome = resolveRemoteHome
        self.helperSupportsBridge = helperSupportsBridge
        self.offerHelperSetup = offerHelperSetup
        self.attach = attach
        self.acknowledgeReady = acknowledgeReady
    }

    static let live = BridgePreflightDependencies(
        resolveRemoteHome: { controlPath, remote in
            await GhosttySurfaceNSView.cachedRemoteHome(
                controlPath: controlPath,
                remote: remote
            )
        },
        helperSupportsBridge: { controlPath, remote, helperPath in
            await GhosttySurfaceNSView.remoteHelperSupportsBridge(
                controlPath: controlPath,
                remote: remote,
                helperPath: helperPath
            )
        },
        offerHelperSetup: { controlPath, remote, remoteHome, helperPath, window, authorityIsCurrent in
            await RemoteHelperInstaller.offerAdditionalSSHFeatures(
                remote: remote,
                controlPath: controlPath,
                remoteHome: remoteHome,
                helperPath: helperPath,
                window: window,
                authorityIsCurrent: authorityIsCurrent
            )
        },
        attach: { preflight, request in
            await preflight.attachForSurfaceLifecycle(request)
        }
    )
}
