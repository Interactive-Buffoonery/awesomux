import AwesoMuxTestSupport
import Foundation
import Testing
@testable import AwesoMuxConfig
@testable import awesoMux

@Suite("Remote helper remembered choices")
struct RemoteHelperChoiceTests {
    @Test("host choices persist independently and override the global fallback")
    @MainActor
    func hostChoice() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: false, store: store) == nil)
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: true, destination: "alice@sandbox", store: store) == nil)
        let saved = try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces
        #expect(saved.helperInstallPolicy(for: "alice@sandbox") == .alwaysInstall)
        #expect(saved.helperInstallPolicy(for: "bob@sandbox") == .neverAsk)
        #expect(saved.helperInstallPolicy(for: "other") == .neverAsk)
        store.saveToDisk = { _ throws(ConfigFileStoreError) in throw .cannotWrite(url, message: "Test failure") }
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: false, destination: "alice@sandbox", store: store) != nil)
        #expect(store.workspaces.value.helperInstallPolicy(for: "alice@sandbox") == .alwaysInstall)
    }

    @Test("all-host choices replace earlier host exceptions")
    @MainActor
    func allHostsChoice() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: false, destination: "sandbox", store: store) == nil)
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: true, store: store) == nil)
        let saved = try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces
        #expect(saved.remoteHelperHostPolicies.isEmpty)
        #expect(saved.helperInstallPolicy(for: "sandbox") == .alwaysInstall)
        #expect(saved.helperInstallPolicy(for: "other") == .alwaysInstall)
    }

    @Test("settings can revoke one host choice or replace all choices")
    @MainActor
    func revokeHostChoices() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: true, destination: "sandbox", store: store) == nil)
        #expect(RemoteAdditionalSSHFeaturesSheet.remember(install: false, destination: "other", store: store) == nil)
        store.workspaces.update { $0.remoteHelperHostPolicies.removeValue(forKey: "sandbox") }
        var saved = try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces
        #expect(saved.helperInstallPolicy(for: "sandbox") == .ask)
        #expect(saved.helperInstallPolicy(for: "other") == .neverAsk)
        store.workspaces.update { $0.rememberHelperInstallPolicy(.ask) }
        saved = try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces
        #expect(saved.remoteHelperHostPolicies.isEmpty)
        #expect(saved.helperInstallPolicy(for: "other") == .ask)
    }

    @Test("old configs keep their global helper preference")
    func oldConfig() throws {
        let config = try TOMLConfigCodec().decode("[workspaces]\nremote_helper_install_policy = \"never_ask\"\n")
        #expect(config.workspaces.remoteHelperHostPolicies.isEmpty)
        #expect(config.workspaces.helperInstallPolicy(for: "sandbox") == .neverAsk)
    }
}
