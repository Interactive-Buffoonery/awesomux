import AwesoMuxCore
import Foundation
import Observation

/// App-owned mapping seam for reliable domain events. Capture sites provide
/// existing domain values; this coordinator reduces them to closed analytics
/// inputs and never accepts arbitrary event names or property dictionaries.
/// Repeating handled failures are capped to one event per kind per launch.
@MainActor
@Observable
final class AnalyticsCaptureCoordinator {
    @ObservationIgnored private let client: any AnalyticsClient
    @ObservationIgnored private let remoteContextProvider: () -> AnalyticsRemoteContext
    @ObservationIgnored private let analyticsEnabled: () -> Bool
    @ObservationIgnored private var capturedErrorKinds: Set<AnalyticsErrorKind> = []

    init(
        client: any AnalyticsClient,
        remoteContextProvider: @escaping () -> AnalyticsRemoteContext,
        analyticsEnabled: @escaping () -> Bool = { true }
    ) {
        self.client = client
        self.remoteContextProvider = remoteContextProvider
        self.analyticsEnabled = analyticsEnabled
    }

    func captureAppLaunch(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) {
        client.capture(
            .appLaunched(
                Self.launchSnapshot(
                    appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                    operatingSystemVersion: processInfo.operatingSystemVersion,
                    cpuArchitecture: Self.currentCPUArchitecture
                )))
    }

    func captureDiagnostic(_ input: LocalDiagnosticEventInput) {
        // Do not consume the per-launch cap while analytics is off. The client
        // still performs the authoritative live consent check before delivery.
        guard analyticsEnabled(),
            var context = Self.errorContext(for: input),
            capturedErrorKinds.insert(context.errorKind).inserted
        else { return }
        context.remote = remoteContextProvider()
        client.capture(.errorReported(context))
    }

    func captureDiagnosticsOpened(section: AnalyticsDiagnosticsSection) {
        client.capture(.diagnosticsOpened(section: section))
    }

    static func launchSnapshot(
        appVersion: String?,
        buildNumber: String?,
        operatingSystemVersion: OperatingSystemVersion,
        cpuArchitecture: String
    ) -> AppLaunchSnapshot {
        AppLaunchSnapshot(
            appVersion: appVersion ?? "0",
            buildNumber: buildNumber ?? "0",
            macOSMajor: operatingSystemVersion.majorVersion,
            macOSMinor: operatingSystemVersion.minorVersion,
            cpuArchitecture: cpuArchitecture
        )
    }

    static func errorContext(
        for input: LocalDiagnosticEventInput
    ) -> AnalyticsErrorContext? {
        switch input {
        case .runtimeEventRejected:
            AnalyticsErrorContext(featureArea: .runtime, errorKind: .runtimeEventRejected)
        case .runtimeEventsDropped:
            AnalyticsErrorContext(featureArea: .runtime, errorKind: .runtimeEventsDropped)
        case .runtimeEventFileUnavailable:
            AnalyticsErrorContext(featureArea: .runtime, errorKind: .runtimeEventFileUnavailable)
        case .configurationRejected:
            AnalyticsErrorContext(featureArea: .configuration, errorKind: .configurationRejected)
        case .configurationResetRejected:
            AnalyticsErrorContext(featureArea: .configuration, errorKind: .configurationResetRejected)
        case .restoreArchived:
            AnalyticsErrorContext(featureArea: .restore, errorKind: .restoreArchived)
        case .restoreSanitized:
            AnalyticsErrorContext(featureArea: .restore, errorKind: .restoreSanitized)
        case .terminalFailed:
            AnalyticsErrorContext(featureArea: .terminal, errorKind: .terminalFailed)
        case .processSamplingFailed:
            AnalyticsErrorContext(featureArea: .diagnostics, errorKind: .processSamplingFailed)
        case .configurationReloaded, .configurationReset, .terminalReady, .terminalReloaded:
            nil
        }
    }

    static func remoteContext(in store: SessionStore) -> AnalyticsRemoteContext {
        let panes = store.groups.flatMap(\.sessions).flatMap(\.panes)
        let remotePaneCount = panes.count { pane in
            pane.executionPlan.remoteTarget != nil || pane.remoteHost != nil
        }
        guard let session = store.selectedSession,
            let activePane = session.layout.pane(id: session.activePaneID)
        else {
            return AnalyticsRemoteContext(
                presence: .unknown,
                activePaneRemote: nil,
                remotePaneCount: remotePaneCount
            )
        }

        if activePane.executionPlan.remoteTarget != nil || activePane.remoteHost != nil {
            return AnalyticsRemoteContext(
                presence: .remote,
                activePaneRemote: true,
                remotePaneCount: remotePaneCount
            )
        }
        if activePane.pendingRemoteSSHTarget != nil {
            return AnalyticsRemoteContext(
                presence: .unknown,
                activePaneRemote: nil,
                remotePaneCount: remotePaneCount
            )
        }
        return AnalyticsRemoteContext(
            presence: .local,
            activePaneRemote: false,
            remotePaneCount: remotePaneCount
        )
    }

    private static var currentCPUArchitecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }
}
