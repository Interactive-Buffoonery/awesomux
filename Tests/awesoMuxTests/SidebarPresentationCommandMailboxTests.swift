import AppKit
import Foundation
import Testing
@testable import awesoMux

@MainActor
@Suite("Sidebar presentation command mailbox")
struct SidebarPresentationCommandMailboxTests {
    @Test("focus then visibility retains the newer hidden target without stale focus")
    func focusThenVisibilityRetainsNewerHide() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let focusID = UUID()
        let visibilityID = UUID()

        fixture.mailbox.requestFocus(id: focusID)
        fixture.deliver()
        fixture.mailbox.requestVisibilityToggle(
            currentIsHidden: fixture.model.userWantsHidden,
            id: visibilityID)
        fixture.deliver()

        #expect(
            fixture.mailbox.pending
                == SidebarPresentationCommand(
                    id: visibilityID,
                    isHidden: true,
                    shouldFocusSidebar: false))
        #expect(fixture.acknowledgedIDs.isEmpty)
        #expect(fixture.focusedIDs.isEmpty)
        #expect(!fixture.mailbox.acknowledge(id: focusID))
        #expect(fixture.mailbox.pending?.id == visibilityID)

        fixture.installCommandHost()
        fixture.deliver()

        #expect(fixture.model.userWantsHidden)
        #expect(fixture.controller.hostModeForTesting == .hidden)
        #expect(fixture.publishedHiddenTargets == [true])
        #expect(fixture.focusedIDs.isEmpty)
        #expect(fixture.acknowledgedIDs == [visibilityID])
        #expect(fixture.mailbox.pending == nil)
    }

    @Test("visibility then focus retains visible focus without stranding the older command")
    func visibilityThenFocusRetainsNewerFocus() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let visibilityID = UUID()
        let focusID = UUID()

        fixture.mailbox.requestVisibilityToggle(
            currentIsHidden: fixture.model.userWantsHidden,
            id: visibilityID)
        fixture.deliver()
        fixture.mailbox.requestFocus(id: focusID)
        fixture.deliver()

        #expect(
            fixture.mailbox.pending
                == SidebarPresentationCommand(
                    id: focusID,
                    isHidden: false,
                    shouldFocusSidebar: true))
        #expect(fixture.acknowledgedIDs.isEmpty)

        fixture.installCommandHost()
        fixture.deliver()

        #expect(!fixture.model.userWantsHidden)
        #expect(fixture.controller.hostModeForTesting == .persistent(width: 300))
        #expect(fixture.publishedHiddenTargets == [false])
        #expect(fixture.focusedIDs == [focusID])
        #expect(fixture.acknowledgedIDs == [focusID])
        #expect(fixture.mailbox.pending == nil)
    }

    @Test("coalesced visibility toggles preserve pending-target parity")
    func visibilityTogglesResolveAgainstPendingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()

        fixture.mailbox.requestVisibilityToggle(currentIsHidden: false, id: firstID)
        #expect(fixture.mailbox.pending?.isHidden == true)
        fixture.mailbox.requestVisibilityToggle(currentIsHidden: false, id: secondID)
        #expect(fixture.mailbox.pending?.isHidden == false)
        fixture.mailbox.requestVisibilityToggle(currentIsHidden: false, id: thirdID)
        #expect(fixture.mailbox.pending?.isHidden == true)

        fixture.installCommandHost()
        fixture.deliver()

        #expect(fixture.nativeVisibilityRequests == [false])
        #expect(fixture.publishedHiddenTargets == [true])
        #expect(fixture.acknowledgedIDs == [thirdID])
    }

    @Test("only the latest command is delivered and acknowledged exactly once")
    func onlyLatestCommandCompletesOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let staleID = UUID()
        let latestID = UUID()

        fixture.mailbox.requestFocus(id: staleID)
        fixture.mailbox.requestFocus(id: latestID)
        fixture.installCommandHost()

        fixture.deliver()
        fixture.deliver()

        #expect(fixture.nativeVisibilityRequests == [true])
        #expect(fixture.publishedHiddenTargets == [false])
        #expect(fixture.focusedIDs == [latestID])
        #expect(fixture.acknowledgedIDs == [latestID])
        #expect(!fixture.mailbox.acknowledge(id: staleID))
    }

    @Test("rejected command clears only itself and the next command can apply")
    func rejectedCommandClearsAndNextCommandApplies() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let rejectedID = UUID()
        let appliedID = UUID()
        fixture.nativeDeliveryOverride = .rejected

        fixture.mailbox.requestVisibilityToggle(currentIsHidden: false, id: rejectedID)
        fixture.deliver()

        #expect(fixture.mailbox.pending == nil)
        #expect(!fixture.model.userWantsHidden)
        #expect(fixture.publishedHiddenTargets.isEmpty)
        #expect(fixture.focusedIDs.isEmpty)
        #expect(fixture.acknowledgedIDs == [rejectedID])

        fixture.nativeDeliveryOverride = .applied
        fixture.mailbox.requestVisibilityToggle(currentIsHidden: false, id: appliedID)
        fixture.deliver()

        #expect(fixture.model.userWantsHidden)
        #expect(fixture.publishedHiddenTargets == [true])
        #expect(fixture.acknowledgedIDs == [rejectedID, appliedID])
    }

    @Test("finalized host defers focus until its replacement becomes usable")
    func finalizedHostReplacementRetriesSameFocusOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let focusID = UUID()
        fixture.installCommandHost()
        fixture.controller.finalizeOwnedLifecycle()
        fixture.mailbox.requestFocus(id: focusID)

        fixture.deliver()

        #expect(fixture.mailbox.pending?.id == focusID)
        #expect(fixture.focusedIDs.isEmpty)
        #expect(fixture.acknowledgedIDs.isEmpty)

        let replacement = SidebarSplitController(
            sidebar: NSViewController(), detail: NSViewController())
        replacement.loadViewIfNeeded()
        replacement.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        replacement.view.layoutSubtreeIfNeeded()
        replacement.setSidebarWidth(300)
        replacement.installCommandHandlers(on: fixture.proxy)

        fixture.deliver()
        fixture.deliver()

        #expect(fixture.focusedIDs == [focusID])
        #expect(fixture.acknowledgedIDs == [focusID])
        #expect(fixture.mailbox.pending == nil)
    }

    @MainActor
    private final class Fixture {
        let mailbox = SidebarPresentationCommandMailbox()
        let model: SidebarPresentationModel
        let controller: SidebarSplitController
        let proxy = SidebarSplitProxy()
        let defaults: UserDefaults
        let suiteName: String
        var nativeVisibilityRequests: [Bool] = []
        var publishedHiddenTargets: [Bool] = []
        var focusedIDs: [UUID] = []
        var acknowledgedIDs: [UUID] = []
        var nativeDeliveryOverride: SidebarPersistentVisibilityDeliveryResult?

        init() throws {
            suiteName = "SidebarPresentationCommandMailboxTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            model = SidebarPresentationModel(
                store: SidebarPresentationPreferenceStore(defaults: defaults))
            controller = SidebarSplitController(
                sidebar: NSViewController(),
                detail: NSViewController())
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
            controller.view.layoutSubtreeIfNeeded()
            controller.setSidebarWidth(300)
        }

        func deliver() {
            guard let command = mailbox.pending else { return }
            let deliveryResult = model.applyPersistentHidden(
                command.isHidden,
                applyNativeVisibility: { visible in
                    nativeVisibilityRequests.append(visible)
                    return nativeDeliveryOverride
                        ?? proxy.setPersistentVisible?(visible)
                        ?? .deferredUntilHostReady
                })
            switch deliveryResult {
            case .deferredUntilHostReady:
                return
            case .rejected:
                guard mailbox.acknowledge(id: command.id) else { return }
                acknowledgedIDs.append(command.id)
                return
            case .applied:
                break
            }

            publishedHiddenTargets.append(model.userWantsHidden)
            if command.shouldFocusSidebar {
                focusedIDs.append(command.id)
            }
            guard mailbox.acknowledge(id: command.id) else { return }
            acknowledgedIDs.append(command.id)
        }

        func installCommandHost() {
            controller.installCommandHandlers(on: proxy)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
