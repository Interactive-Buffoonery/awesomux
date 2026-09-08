@testable import AwesoMuxConfig
import AwesoMuxCore
import AwesoMuxTestSupport
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Managed SSH connection preference transaction")
struct ManagedSSHConnectionPreferenceTests {
    @Test("failed remember submissions restore disk preferences and allow retry", arguments: [false, true])
    func failedConnectionRollsBack(allDestinations: Bool) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        let before = WorkspaceConfig(
            managedSSHOffersEnabled: false,
            managedSSHOfferIgnoredDestinations: ["other", "  build-box  "],
            managedSSHAlwaysManaged: ["@build-box": ManagedSSHAlwaysManagedEntry(sessionName: "old")]
        )
        store.workspaces.update { $0 = before }
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: "new"))
        let preference: ManagedSSHConnectionPreference = allDestinations ? .allDestinations : .destination
        var submission = SSHWorkspaceConnectionSubmission()
        var announcements: [String] = []
        let saved = preference.submit(execution: execution, store: store) {
            submission.submit(
                execution: execution, isCommandBridgeEnabled: false, enableCommandBridge: { false },
                connect: { _ in false }, announce: { announcements.append($0) }
            )
        }
        #expect(saved == .finished)
        #expect(store.workspaces.value == before)
        #expect(try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces == before)
        #expect(!submission.isConnecting)
        #expect(submission.errorMessage != nil)
        #expect(announcements.count == 1)

        #expect(
            preference.submit(execution: execution, store: store) {
                submission.submit(
                    execution: execution, isCommandBridgeEnabled: false, enableCommandBridge: { false },
                    connect: { _ in true }, announce: { announcements.append($0) }
                )
            } == .finished)
        #expect(submission.isConnecting)
        #expect(submission.errorMessage == nil)
        #expect(store.workspaces.value != before)
        #expect(try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces == store.workspaces.value)
    }

    @Test("rollback retains unrelated changes made by the connection callback", arguments: [false, true])
    func preservesOtherEdits(allDestinations: Bool) throws {
        let directory = try TemporaryDirectory()
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: directory.url.appending(path: "config.toml")),
            legacySnapshotProvider: { nil }
        )
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: ""))
        let preference: ManagedSSHConnectionPreference = allDestinations ? .allDestinations : .destination
        #expect(
            preference.submit(execution: execution, store: store) {
                store.workspaces.update {
                    $0.defaultGroup = "Changed"
                    _ = ManagedSSHOfferPolicy.addAlwaysManagedDestination("other", to: &$0)
                    _ = ManagedSSHOfferPolicy.addIgnoredDestination("ignored", to: &$0)
                }
                store.terminal.update { $0.commandBridgeEnabled = true }
                return false
            } == .finished)
        #expect(store.workspaces.value.defaultGroup == "Changed")
        #expect(store.workspaces.value.managedSSHAlwaysManaged["other"] != nil)
        #expect(store.workspaces.value.managedSSHOfferIgnoredDestinations == ["ignored"])
        #expect(store.workspaces.value.managedSSHAlwaysManaged["build-box"] == nil)
        #expect(!store.workspaces.value.managedSSHAlwaysManageAllDestinations)
        #expect(store.terminal.value.commandBridgeEnabled)
    }

    @Test("a newer answer for the same destination survives rollback")
    func preservesNewDestinationAnswer() throws {
        let directory = try TemporaryDirectory()
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: directory.url.appending(path: "config.toml")),
            legacySnapshotProvider: { nil }
        )
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: ""))
        #expect(
            ManagedSSHConnectionPreference.destination.submit(execution: execution, store: store) {
                store.workspaces.update { _ = ManagedSSHOfferPolicy.addIgnoredDestination("build-box", to: &$0) }
                return false
            } == .finished)
        #expect(store.workspaces.value.managedSSHAlwaysManaged.isEmpty)
        #expect(store.workspaces.value.managedSSHOfferIgnoredDestinations == ["build-box"])
    }

    @Test("failure to enable background sessions rolls back the remembered destination")
    func bridgeFailureRollsBack() throws {
        let directory = try TemporaryDirectory()
        let store = AppSettingsStore(
            fileStore: ConfigFileStore(configURL: directory.url.appending(path: "config.toml")),
            legacySnapshotProvider: { nil }
        )
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: ""))
        var submission = SSHWorkspaceConnectionSubmission()
        #expect(
            ManagedSSHConnectionPreference.destination.submit(execution: execution, store: store) {
                submission.submit(
                    execution: execution, isCommandBridgeEnabled: false, enableCommandBridge: { false },
                    connect: { _ in
                        Issue.record("Connection should not run"); return true
                    }, announce: { _ in }
                )
            } == .finished)
        #expect(store.workspaces.value.managedSSHAlwaysManaged.isEmpty)
        #expect(!submission.isConnecting)
    }
    @Test("a rejected preference save never attempts the connection")
    func saveFailureStopsConnection() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        store.saveToDisk = { _ throws(ConfigFileStoreError) in throw .cannotWrite(url, message: "Test failure") }
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: ""))
        let result = ManagedSSHConnectionPreference.destination.submit(execution: execution, store: store) {
            Issue.record("Connection should not run after a failed preference save")
            return true
        }
        #expect(result == .saveFailed)
        #expect(store.workspaces.value.managedSSHAlwaysManaged.isEmpty)
    }

    @Test("rollback failure is distinguished from connection failure")
    func rollbackFailureIsReported() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "config.toml")
        let store = AppSettingsStore(fileStore: ConfigFileStore(configURL: url), legacySnapshotProvider: { nil })
        let execution = try #require(SSHWorkspaceConnectFields.execution(destination: "build-box", sessionName: ""))
        let result = ManagedSSHConnectionPreference.destination.submit(execution: execution, store: store) {
            store.saveToDisk = { _ throws(ConfigFileStoreError) in throw .cannotWrite(url, message: "Test failure") }
            return false
        }
        #expect(result == .rollbackFailed)
        #expect(store.workspaces.value.managedSSHAlwaysManaged["build-box"] != nil)
        #expect(try TOMLConfigCodec().decode(Data(contentsOf: url)).workspaces == store.workspaces.value)
    }

}
