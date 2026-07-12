import Foundation
import ServiceManagement
import Testing
@testable import awesoMux

@Suite("Open at Login settings")
struct LoginItemSettingsModelTests {
    @Test("SMAppService statuses map to settings states")
    func statusMapping() {
        #expect(LoginItemSettingsModel.displayStatus(for: .enabled) == .on)
        #expect(LoginItemSettingsModel.displayStatus(for: .requiresApproval) == .needsApproval)
        #expect(LoginItemSettingsModel.displayStatus(for: .notRegistered) == .off)
        #expect(LoginItemSettingsModel.displayStatus(for: .notFound) == .unavailable)
    }

    @MainActor
    @Test("refresh mirrors the current login item state")
    func refreshMirrorsStatus() {
        var currentStatus = SMAppService.Status.notRegistered
        let model = LoginItemSettingsModel(service: LoginItemService(
            status: { currentStatus },
            register: {},
            unregister: {}
        ))

        model.refresh()
        #expect(model.status == .off)
        #expect(!model.isRequested)

        currentStatus = .requiresApproval
        model.refresh()
        #expect(model.status == .needsApproval)
        #expect(model.isRequested)
    }

    @MainActor
    @Test("enabling registers and refreshes status")
    func enablingRegisters() {
        var didRegister = false
        var currentStatus = SMAppService.Status.notRegistered
        let model = LoginItemSettingsModel(service: LoginItemService(
            status: { currentStatus },
            register: {
                didRegister = true
                currentStatus = .enabled
            },
            unregister: {}
        ))

        model.setRequested(true)

        #expect(didRegister)
        #expect(model.status == .on)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    @Test("disabling unregisters and refreshes status")
    func disablingUnregisters() {
        var didUnregister = false
        var currentStatus = SMAppService.Status.enabled
        let model = LoginItemSettingsModel(service: LoginItemService(
            status: { currentStatus },
            register: {},
            unregister: {
                didUnregister = true
                currentStatus = .notRegistered
            }
        ))

        model.setRequested(false)

        #expect(didUnregister)
        #expect(model.status == .off)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    @Test("mutation failures keep live status and surface remediation")
    func mutationFailureSurfacesRemediation() {
        var currentStatus = SMAppService.Status.notRegistered
        let model = LoginItemSettingsModel(service: LoginItemService(
            status: { currentStatus },
            register: { throw LoginItemTestError() },
            unregister: {}
        ))

        model.setRequested(true)

        #expect(model.status == .off)
        #expect(model.errorMessage?.contains("Could not turn on Open at Login") == true)
        #expect(model.errorMessage?.contains("System Settings > General > Login Items") == true)
        #expect(model.errorMessage?.contains("registration failed") == true)

        currentStatus = .enabled
        model.refresh()
        #expect(model.status == .on)
        #expect(model.errorMessage == nil)
    }

    @Test("General settings wires the login item model to the UI")
    func generalSettingsWiresLoginItemModel() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // awesoMuxTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/awesoMux/Views/Settings/Panes/GeneralSettingsPane.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("hint: loginItemModel.statusHint"))
        #expect(source.contains("get: { loginItemModel.isRequested }"))
        #expect(source.contains("set: { loginItemModel.setRequested($0) }"))
        #expect(source.contains("loginItemModel.refresh()"))
    }
}

private struct LoginItemTestError: LocalizedError {
    var errorDescription: String? { "registration failed" }
}
