import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Testing
@testable import awesoMux

@Suite("Managed SSH offer effect")
struct ManagedSSHOfferEffectTests {
    private static let appPath = "Sources/awesoMux/App/AwesoMuxApp.swift"

    // MARK: - Resolution

    @Test("no pending offer resolves to no effect")
    func noPendingOfferDoesNothing() {
        #expect(ManagedSSHOfferEffect.resolve(target: nil, config: .defaultValue) == .doNothing)
    }

    @Test("a suppressed destination resolves to no effect, not a prompt")
    func suppressedDestinationDoesNothing() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        let config = WorkspaceConfig(managedSSHOfferIgnoredDestinations: ["build-box"])

        #expect(ManagedSSHOfferEffect.resolve(target: target, config: config) == .doNothing)
    }

    @Test("an ordinary destination resolves to the prompt")
    func ordinaryDestinationPresents() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))

        #expect(ManagedSSHOfferEffect.resolve(target: target, config: .defaultValue) == .present)
    }

    @Test("a locally persisted always-managed destination converts with no session name")
    func locallyPersistedDestinationConvertsWithoutSessionName() throws {
        let target = try #require(RemoteTarget(parsing: "build-box"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("build-box", to: &config)

        #expect(
            ManagedSSHOfferEffect.resolve(target: target, config: config)
                == .convert(sessionName: nil)
        )
    }

    @Test("a remote-owned always-managed destination carries its session name through")
    func remoteOwnedDestinationCarriesSessionName() throws {
        let target = try #require(RemoteTarget(parsing: "prod"))
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))
        var config = WorkspaceConfig()
        _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination(
            "prod",
            sessionName: sessionName,
            to: &config
        )

        #expect(
            ManagedSSHOfferEffect.resolve(target: target, config: config)
                == .convert(sessionName: sessionName)
        )
    }

    // MARK: - Enactment
    //
    // These replace source-text assertions on the App's switch. A cross-model
    // review defeated those in one line: a regression that resolved the effect,
    // discarded it, and switched on a constant kept every token they looked for
    // while sending suppressed destinations back to the consent sheet. Injected
    // callbacks make "which action ran" the thing under test.

    private final class ActionLog {
        private(set) var converted: [RemoteSessionName?] = []
        private(set) var presented = 0
        private(set) var confirmed = 0
        var conversionSucceeds = true

        func convert(_ sessionName: RemoteSessionName?) -> Bool {
            converted.append(sessionName)
            return conversionSucceeds
        }
        func present() { presented += 1 }
        func confirm() { confirmed += 1 }
    }

    private func enact(_ effect: ManagedSSHOfferEffect, succeeding: Bool = true) -> ActionLog {
        let log = ActionLog()
        log.conversionSucceeds = succeeding
        ManagedSSHOfferEnactor.enact(
            effect,
            convert: log.convert,
            present: log.present,
            confirm: log.confirm
        )
        return log
    }

    @Test("no effect takes no action at all")
    func doNothingTakesNoAction() {
        let log = enact(.doNothing)

        #expect(log.converted.isEmpty)
        #expect(log.presented == 0)
        #expect(log.confirmed == 0)
    }

    @Test("the prompt effect presents and never converts")
    func presentEffectOnlyPresents() {
        let log = enact(.present)

        #expect(log.presented == 1)
        #expect(log.converted.isEmpty)
        #expect(log.confirmed == 0)
    }

    @Test("a successful conversion forwards the owner and confirms without prompting")
    func convertForwardsOwnerAndConfirms() throws {
        let sessionName = try #require(RemoteSessionName(rawValue: "mysession"))

        let log = enact(.convert(sessionName: sessionName))

        #expect(log.converted == [sessionName])
        #expect(log.confirmed == 1)
        #expect(log.presented == 0)
    }

    @Test("a failed conversion falls back to the prompt and does not confirm")
    func failedConversionFallsBackToPrompt() {
        let log = enact(.convert(sessionName: nil), succeeding: false)

        #expect(log.converted == [nil])
        #expect(log.presented == 1)
        #expect(log.confirmed == 0)
    }

    // MARK: - App wiring
    //
    // Narrow on purpose. The enactor above covers behaviour; these only pin the
    // App to it, and each asserts its anchor exists first — `String.split`
    // returns the whole input when the separator is absent, so a slice taken
    // without that check silently widens to the entire function body and starts
    // passing for the wrong reason.

    @Test("the app enacts the resolved effect rather than re-deciding")
    func appEnactsResolvedEffect() throws {
        let source = try SourceContract.source(at: Self.appPath)
        let body = try SourceContract.declarationBody(
            after: "private func requestManagedSSHWorkspaceOffer(",
            in: source,
            path: Self.appPath
        )

        #expect(body.contains("ManagedSSHOfferEffect.resolve("))
        // Re-deciding in the App is what the extraction exists to prevent.
        #expect(!body.contains("ManagedSSHOfferPolicy.decision("))
        #expect(body.contains("sessionName: sessionName"))

        // The enactor must receive the RESOLVED effect. Asserting only that
        // both calls appear leaves the regression a cross-model review found:
        // resolve, discard the answer, and enact a constant instead — every
        // token present, suppressed destinations back at the consent sheet.
        let enactCall = try #require(
            body.range(of: "ManagedSSHOfferEnactor.enact(")
        )
        let firstArgument = try #require(body.range(of: "convert:", range: enactCall.upperBound..<body.endIndex))
        #expect(body[enactCall.upperBound..<firstArgument.lowerBound].contains("pendingEffect"))
    }

    @Test("the sheet-stacking guard defers only the arm that presents a sheet")
    func sheetGuardDefersOnlyThePresentingArm() throws {
        let source = try SourceContract.source(at: Self.appPath)
        let body = try SourceContract.declarationBody(
            after: "private func requestManagedSSHWorkspaceOffer(",
            in: source,
            path: Self.appPath
        )

        // Peeking before the consume is the whole point: consuming and then
        // deferring drops the destination permanently, because the pane's
        // `.task(id:)` does not fire again for the same identity.
        let peek = try #require(body.range(of: "pendingManagedSSHWorkspaceOffer("))
        let consume = try #require(body.range(of: "consumeManagedSSHWorkspaceOffer("))
        #expect(peek.lowerBound < consume.lowerBound)
        #expect(body.contains("pendingEffect == .present && isAnySheetPresented"))
    }

    @Test("the conversion discards the old surface and refuses to enable the bridge")
    func conversionDiscardsSurfaceAndRefusesBridgeEnable() throws {
        let source = try SourceContract.source(at: Self.appPath)
        let body = try SourceContract.declarationBody(
            after: "private func reconnectPaneAsManagedSSH(",
            in: source,
            path: Self.appPath
        )

        #expect(body.contains("ghosttyRuntime.discardSurface(for: discardedPaneID)"))
        // A per-destination preference is not consent to change a global
        // setting, so this path refuses rather than enabling it.
        #expect(!body.contains("commandBridgeEnabled = true"))
        #expect(body.contains("commandBridgeEnabled {"))
    }
}
