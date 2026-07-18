import Foundation
import Testing
@testable import AwesoMuxCore

@Suite struct WorkspacePaneCapabilitiesTests {
    private func localPane() -> TerminalPane {
        TerminalPane(title: "zsh", workingDirectory: "/tmp", executionPlan: .local)
    }

    private func remotePane() -> TerminalPane {
        TerminalPane(
            title: "ssh",
            workingDirectory: "/tmp",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(user: "ed", host: "box")!))
        )
    }

    private func localDoc() -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "cap-\(UUID().uuidString).md"),
            title: "notes.md"
        )
    }

    private func remoteDoc() -> DocumentPane {
        DocumentPane(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "cap-\(UUID().uuidString).md"),
            title: "remote.md",
            remoteResourceIdentity: ResourceIdentity(
                location: .remote(RemoteTarget(parsing: "me@example.com")!),
                path: ResourcePath(rawValue: "/home/me/remote.md")
            )
        )
    }

    @Test func localTerminalIsFullyCapable() {
        let caps = WorkspacePaneCapabilities.of(.terminal(localPane()))
        #expect(caps.localFileAccess)
        #expect(!caps.remoteProvenance)
        #expect(caps.safeInputTarget)
        #expect(caps.duplicable)
        #expect(caps.presetEligible)
    }

    @Test func remoteTerminalIsNotLocalNotPresetEligible() {
        let caps = WorkspacePaneCapabilities.of(.terminal(remotePane()))
        #expect(!caps.localFileAccess)
        #expect(caps.remoteProvenance)
        #expect(!caps.safeInputTarget)  // never hand a remote pane a Mac path
        #expect(caps.duplicable)
        #expect(!caps.presetEligible)  // host identity must not reach a preset
    }

    @Test func localDocumentGroupIsNeitherInputTargetNorPresetEligible() {
        let doc = localDoc()
        let group = DocumentGroup(tabs: [doc], selectedTabID: doc.id)
        let caps = WorkspacePaneCapabilities.of(.documentGroup(group))
        #expect(caps.localFileAccess)
        #expect(!caps.remoteProvenance)
        #expect(!caps.safeInputTarget)
        #expect(!caps.duplicable)
        #expect(!caps.presetEligible)
    }

    @Test func remoteSnapshotTabTaintsGroupProvenance() {
        let local = localDoc()
        let remote = remoteDoc()
        let group = DocumentGroup(tabs: [local, remote], selectedTabID: local.id)
        let caps = WorkspacePaneCapabilities.of(.documentGroup(group))
        #expect(!caps.localFileAccess)  // one remote tab taints the fold
        #expect(caps.remoteProvenance)
    }

    // Every kind resolves a full capability set through one dispatch: a new kind
    // must extend `WorkspacePaneCapabilities.of` or fail to compile — the
    // "localized wiring" property, not a second framework.
    @Test func everyKindHasACapabilityRow() {
        for kind in WorkspacePaneKind.allCases {
            let leaf: WorkspaceLeaf
            switch kind {
            case .terminal:
                leaf = .terminal(localPane())
            case .documentGroup:
                let doc = localDoc()
                leaf = .documentGroup(DocumentGroup(tabs: [doc], selectedTabID: doc.id))
            }
            #expect(leaf.kind == kind)
            _ = leaf.capabilities  // resolves without trapping
        }
    }
}
