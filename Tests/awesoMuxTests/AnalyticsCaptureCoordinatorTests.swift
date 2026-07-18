import AwesoMuxConfig
import AwesoMuxCore
import Foundation
import Testing

@testable import awesoMux

@MainActor
@Suite("Analytics capture coordinator")
struct AnalyticsCaptureCoordinatorTests {
    @MainActor
    private final class ClientSpy: AnalyticsClient {
        private(set) var inputs: [AnalyticsEventInput] = []

        func reconcileConsent(level: AnalyticsConfig.ConsentLevel) {}
        func capture(_ input: AnalyticsEventInput) { inputs.append(input) }
        func optIn(level: AnalyticsConfig.ConsentLevel) {}
        func optOut(deleteLocalState: Bool) -> Bool { true }
    }

    @Test("launch mapping uses only version, OS, and architecture fields")
    func launchMapping() {
        let snapshot = AnalyticsCaptureCoordinator.launchSnapshot(
            appVersion: "1.4.0",
            buildNumber: "203",
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 4,
                patchVersion: 9
            ),
            cpuArchitecture: "arm64"
        )

        #expect(
            snapshot
                == AppLaunchSnapshot(
                    appVersion: "1.4.0",
                    buildNumber: "203",
                    macOSMajor: 15,
                    macOSMinor: 4,
                    cpuArchitecture: "arm64"
                ))
        #expect(
            AnalyticsCaptureCoordinator.launchSnapshot(
                appVersion: nil,
                buildNumber: nil,
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 15,
                    minorVersion: 0,
                    patchVersion: 0
                ),
                cpuArchitecture: "unknown"
            ).appVersion == "0")
    }

    @Test("only handled failure diagnostics map to analytics errors")
    func diagnosticMapping() {
        let mappings: [(LocalDiagnosticEventInput, AnalyticsFeatureArea, AnalyticsErrorKind)] = [
            (.runtimeEventRejected, .runtime, .runtimeEventRejected),
            (.runtimeEventsDropped, .runtime, .runtimeEventsDropped),
            (.runtimeEventFileUnavailable, .runtime, .runtimeEventFileUnavailable),
            (.configurationRejected(trigger: .watcher), .configuration, .configurationRejected),
            (.configurationResetRejected, .configuration, .configurationResetRejected),
            (.restoreArchived, .restore, .restoreArchived),
            (.restoreSanitized, .restore, .restoreSanitized),
            (.terminalFailed, .terminal, .terminalFailed),
            (.processSamplingFailed, .diagnostics, .processSamplingFailed),
        ]
        for (input, area, kind) in mappings {
            let context = AnalyticsCaptureCoordinator.errorContext(for: input)
            #expect(context?.featureArea == area)
            #expect(context?.errorKind == kind)
            #expect(context?.remote == nil)
        }

        let informational: [LocalDiagnosticEventInput] = [
            .configurationReloaded(trigger: .manual),
            .configurationReset,
            .terminalReady,
            .terminalReloaded,
        ]
        for input in informational {
            #expect(AnalyticsCaptureCoordinator.errorContext(for: input) == nil)
        }
    }

    @Test("diagnostic capture adds coarse context and caps each failure kind per launch")
    func diagnosticCapture() throws {
        let client = ClientSpy()
        let remote = AnalyticsRemoteContext(
            presence: .remote,
            activePaneRemote: true,
            remotePaneCount: 7
        )
        let coordinator = AnalyticsCaptureCoordinator(
            client: client,
            remoteContextProvider: { remote }
        )

        coordinator.captureDiagnostic(.terminalFailed)
        coordinator.captureDiagnostic(.terminalFailed)
        coordinator.captureDiagnostic(.terminalReady)

        let input = try #require(client.inputs.first)
        guard case .errorReported(let context) = input else {
            Issue.record("expected a handled error input")
            return
        }
        #expect(context.featureArea == .terminal)
        #expect(context.errorKind == .terminalFailed)
        #expect(context.remote == remote)
        #expect(client.inputs.count == 1)

        guard
            case .event(let event) = AnalyticsSanitizer().sanitize(
                input,
                consent: .errorReports
            )
        else {
            Issue.record("expected the mapped error to pass sanitization")
            return
        }
        #expect(
            Set(event.properties.keys) == [
                .featureArea,
                .errorKind,
                .remoteContext,
                .activePaneRemote,
                .remotePaneCountBucket,
                .schemaVersion,
                .consentLevel,
            ])
    }

    @Test("diagnostic cap is not consumed while analytics is off")
    func disabledDiagnosticDoesNotConsumeCap() {
        let client = ClientSpy()
        var isEnabled = false
        let coordinator = AnalyticsCaptureCoordinator(
            client: client,
            remoteContextProvider: {
                AnalyticsRemoteContext(presence: .unknown, activePaneRemote: nil, remotePaneCount: 0)
            },
            analyticsEnabled: { isEnabled }
        )

        coordinator.captureDiagnostic(.terminalFailed)
        isEnabled = true
        coordinator.captureDiagnostic(.terminalFailed)

        #expect(client.inputs.count == 1)
    }

    @Test("diagnostics openings remain a closed section enum")
    func diagnosticsOpened() {
        let client = ClientSpy()
        let coordinator = AnalyticsCaptureCoordinator(
            client: client,
            remoteContextProvider: {
                AnalyticsRemoteContext(presence: .unknown, activePaneRemote: nil, remotePaneCount: 0)
            }
        )

        coordinator.captureDiagnosticsOpened(section: .overview)
        coordinator.captureDiagnosticsOpened(section: .analytics)

        #expect(
            client.inputs == [
                .diagnosticsOpened(section: .overview),
                .diagnosticsOpened(section: .analytics),
            ])
    }

    @Test("remote context maps pane state without exposing host values")
    func remoteContext() throws {
        let localPane = TerminalPane(
            title: "private local title",
            workingDirectory: "/Users/private/project",
            executionPlan: .local
        )
        let remotePane = TerminalPane(
            title: "private remote title",
            workingDirectory: "/Users/private/other",
            remoteHost: "secret.example.com",
            executionPlan: .local
        )
        let session = TerminalSession(
            title: "private workspace",
            workingDirectory: "/Users/private/project",
            agentKind: .shell,
            layout: .split(
                TerminalSplit(
                    orientation: .vertical,
                    first: .pane(localPane),
                    second: .pane(remotePane)
                )),
            activePaneID: remotePane.id
        )
        let store = SessionStore(groups: [
            SessionGroup(name: "private group", sessions: [session])
        ])

        let context = AnalyticsCaptureCoordinator.remoteContext(in: store)

        #expect(
            context
                == AnalyticsRemoteContext(
                    presence: .remote,
                    activePaneRemote: true,
                    remotePaneCount: 1
                ))
    }

    @Test("declared SSH is remote before observation; pending local SSH is unknown")
    func declaredAndPendingRemoteContext() throws {
        let target = try #require(RemoteTarget(parsing: "private-host"))
        let declaredPane = TerminalPane(
            title: "private",
            workingDirectory: "/Users/private/project",
            executionPlan: .ssh(SSHExecution(target: target))
        )
        let declaredSession = TerminalSession(
            title: "private",
            workingDirectory: "/Users/private/project",
            layout: .pane(declaredPane),
            activePaneID: declaredPane.id
        )
        let declaredStore = SessionStore(groups: [
            SessionGroup(name: "private", sessions: [declaredSession])
        ])
        #expect(
            AnalyticsCaptureCoordinator.remoteContext(in: declaredStore)
                == AnalyticsRemoteContext(
                    presence: .remote,
                    activePaneRemote: true,
                    remotePaneCount: 1
                ))

        let pendingPane = TerminalPane(
            title: "private",
            workingDirectory: "/Users/private/project",
            pendingRemoteSSHTarget: "private-host",
            executionPlan: .local
        )
        let pendingSession = TerminalSession(
            title: "private",
            workingDirectory: "/Users/private/project",
            layout: .pane(pendingPane),
            activePaneID: pendingPane.id
        )
        let pendingStore = SessionStore(groups: [
            SessionGroup(name: "private", sessions: [pendingSession])
        ])
        #expect(
            AnalyticsCaptureCoordinator.remoteContext(in: pendingStore)
                == AnalyticsRemoteContext(
                    presence: .unknown,
                    activePaneRemote: nil,
                    remotePaneCount: 0
                ))
    }
}
