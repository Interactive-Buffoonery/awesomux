import Testing
@testable import awesoMux

@Suite("Sheet wedge recovery policy")
struct SheetWedgeRecoveryPolicyTests {
    private func snapshot(
        keys: Set<String> = [],
        scrollbackPanes: Int = 0,
        modal: Bool = false
    ) -> SheetWedgeRecoveryPolicy.Snapshot {
        .init(
            pendingRequestKeys: keys,
            scrollbackDumpPaneCount: scrollbackPanes,
            hasNativeModalPresentation: modal
        )
    }

    @Test("a request pending across both snapshots with no presentation heals")
    func stablePendingRequestHeals() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(keys: ["sshWorkspaceConnect"]),
            recheck: snapshot(keys: ["sshWorkspaceConnect"])
        )
        #expect(keys == ["sshWorkspaceConnect"])
    }

    @Test("a native modal presentation at recheck vetoes all healing")
    func nativeModalVetoesHealing() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(keys: ["quickSettings"], scrollbackPanes: 1),
            recheck: snapshot(keys: ["quickSettings"], scrollbackPanes: 1, modal: true)
        )
        #expect(keys.isEmpty)
    }

    @Test("a request that appears only at recheck is inside its mount grace")
    func freshRequestIsNotHealed() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(),
            recheck: snapshot(keys: ["workspaceEdit"])
        )
        #expect(keys.isEmpty)
    }

    @Test("a request resolved before recheck is not healed")
    func resolvedRequestIsNotHealed() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(keys: ["workspaceGroupRename"]),
            recheck: snapshot()
        )
        #expect(keys.isEmpty)
    }

    @Test("latched scrollback-dump flags heal alongside request vars")
    func scrollbackFlagHeals() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(keys: ["paneEdit"], scrollbackPanes: 2),
            recheck: snapshot(keys: ["paneEdit"], scrollbackPanes: 2)
        )
        #expect(keys == ["paneEdit", SheetWedgeRecoveryPolicy.scrollbackDumpKey])
    }

    @Test("a scrollback flag cleared before recheck is not healed")
    func clearedScrollbackFlagIsNotHealed() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(scrollbackPanes: 1),
            recheck: snapshot(scrollbackPanes: 0)
        )
        #expect(keys.isEmpty)
    }
}
