import Testing
@testable import awesoMux
@testable import AwesoMuxCore

@Suite("Sheet wedge recovery policy")
struct SheetWedgeRecoveryPolicyTests {
    private static let paneA = TerminalPane.ID()
    private static let paneB = TerminalPane.ID()

    private func snapshot(
        keys: Set<String> = [],
        scrollbackPanes: Set<TerminalPane.ID> = [],
        modal: Bool = false,
        primarySheet: Bool = false,
        anySheet: Bool = false
    ) -> SheetWedgeRecoveryPolicy.Snapshot {
        .init(
            pendingRequestKeys: keys,
            scrollbackDumpPaneIDs: scrollbackPanes,
            hasModalWindow: modal,
            primaryWindowSheetAttached: primarySheet,
            anyWindowSheetAttached: anySheet
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

    @Test("a modal window at recheck vetoes all healing")
    func modalWindowVetoesHealing() {
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(
            initial: snapshot(keys: ["quickSettings"], scrollbackPanes: [Self.paneA]),
            recheck: snapshot(keys: ["quickSettings"], scrollbackPanes: [Self.paneA], modal: true)
        )
        #expect(keys.isEmpty)
    }

    @Test("a primary-window sheet vetoes all healing")
    func primarySheetVetoesAllHealing() {
        // A primary-window attached sheet is also an app-wide attached sheet,
        // so both flags travel together in production; the per-class scoping
        // only diverges when a NON-primary window holds the sheet (covered by
        // the any-window test below).
        let initial = snapshot(keys: ["workspaceEdit"], scrollbackPanes: [Self.paneA])
        let recheck = snapshot(
            keys: ["workspaceEdit"],
            scrollbackPanes: [Self.paneA],
            primarySheet: true,
            anySheet: true
        )
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(initial: initial, recheck: recheck)
        #expect(keys.isEmpty)
    }

    @Test("any-window sheet vetoes scrollback healing but not request vars")
    func anyWindowSheetVetoesScrollbackOnly() {
        // Scrollback dumps can be hosted in floating/companion panels, so a
        // sheet anywhere may be a live dump; the seven request sheets present
        // only on the primary content window.
        let initial = snapshot(keys: ["paneEdit"], scrollbackPanes: [Self.paneA])
        let recheck = snapshot(keys: ["paneEdit"], scrollbackPanes: [Self.paneA], anySheet: true)
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(initial: initial, recheck: recheck)
        #expect(keys == ["paneEdit"])
        #expect(
            SheetWedgeRecoveryPolicy.scrollbackPaneIDsToHeal(initial: initial, recheck: recheck)
                .isEmpty
        )
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

    @Test("scrollback flags heal by pane identity, not count")
    func scrollbackFlagsHealByIdentity() {
        // Pane A's wedge cleared while pane B raised a fresh dump inside the
        // beat: the count stayed at one, but no pane is wedged across both
        // snapshots, so nothing heals — force-dismissing B's just-opened dump
        // would reopen the wrong-heal class this policy exists to close.
        let initial = snapshot(scrollbackPanes: [Self.paneA])
        let recheck = snapshot(scrollbackPanes: [Self.paneB])
        #expect(SheetWedgeRecoveryPolicy.keysToHeal(initial: initial, recheck: recheck).isEmpty)
        #expect(
            SheetWedgeRecoveryPolicy.scrollbackPaneIDsToHeal(initial: initial, recheck: recheck)
                .isEmpty
        )
    }

    @Test("a wedged pane heals alongside pending request vars")
    func wedgedPaneHealsAlongsideRequests() {
        let initial = snapshot(keys: ["paneEdit"], scrollbackPanes: [Self.paneA, Self.paneB])
        let recheck = snapshot(keys: ["paneEdit"], scrollbackPanes: [Self.paneA])
        let keys = SheetWedgeRecoveryPolicy.keysToHeal(initial: initial, recheck: recheck)
        #expect(keys == ["paneEdit", SheetWedgeRecoveryPolicy.scrollbackDumpKey])
        #expect(
            SheetWedgeRecoveryPolicy.scrollbackPaneIDsToHeal(initial: initial, recheck: recheck)
                == [Self.paneA]
        )
    }

    @Test("every request key is producible by the snapshot mapping")
    func everyRequestKeyIsProducible() {
        // Guards the snapshot/heal coupling: a key added to RequestKey.all
        // without a corresponding branch in pendingRequestKeys (or vice versa)
        // fails here instead of silently logging heals that clear nothing.
        #expect(
            SheetWedgeRecoveryPolicy.pendingRequestKeys(
                workspaceEdit: true,
                paneEdit: true,
                workspaceGroupCreate: true,
                remoteWorkspaceGroupCreate: true,
                sshWorkspaceConnect: true,
                workspaceGroupRename: true,
                quickSettings: true
            ) == SheetWedgeRecoveryPolicy.RequestKey.all
        )
        #expect(SheetWedgeRecoveryPolicy.RequestKey.all.count == 7)
    }

    @Test("pending request keys map each var to its stable key")
    func pendingRequestKeysMapping() {
        #expect(
            SheetWedgeRecoveryPolicy.pendingRequestKeys(
                workspaceEdit: true,
                paneEdit: false,
                workspaceGroupCreate: true,
                remoteWorkspaceGroupCreate: false,
                sshWorkspaceConnect: true,
                workspaceGroupRename: false,
                quickSettings: true
            ) == ["workspaceEdit", "workspaceGroupCreate", "sshWorkspaceConnect", "quickSettings"]
        )
        #expect(
            SheetWedgeRecoveryPolicy.pendingRequestKeys(
                workspaceEdit: false,
                paneEdit: true,
                workspaceGroupCreate: false,
                remoteWorkspaceGroupCreate: true,
                sshWorkspaceConnect: false,
                workspaceGroupRename: true,
                quickSettings: false
            ) == ["paneEdit", "remoteWorkspaceGroupCreate", "workspaceGroupRename"]
        )
    }
}
