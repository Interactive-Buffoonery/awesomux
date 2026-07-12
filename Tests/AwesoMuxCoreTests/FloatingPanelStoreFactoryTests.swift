import Foundation
import Testing
@testable import AwesoMuxCore

@MainActor
@Suite("FloatingPanelStoreFactory")
struct FloatingPanelStoreFactoryTests {
    private static let fallbackHome = "/Users/test"

    @Test("nil parent workspace produces an unattached floating panel at fallback home")
    func nilParentSeedsUnattachedFloatingPanel() throws {
        let store = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: nil,
            fallbackHome: Self.fallbackHome
        )

        let session = try #require(store.selectedSession)
        #expect(session.title == "floating panel")
        #expect(session.workingDirectory == Self.fallbackHome)
        #expect(session.agentKind == .shell)
        #expect(store.groups.count == 1)
        #expect(store.groups.first?.name == "Floating Panel")
        #expect(store.groups.first?.sessions.count == 1)
    }

    @Test("parent workspace title is interpolated with the floating prefix")
    func parentWorkspaceTitleInterpolated() throws {
        let parent = TerminalSession(
            title: "myrepo",
            workingDirectory: "/Users/test/projects/myrepo",
            agentKind: .claudeCode,
            agentState: .running
        )

        let store = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: parent,
            fallbackHome: Self.fallbackHome
        )

        let session = try #require(store.selectedSession)
        #expect(session.title == "floating · myrepo")
        #expect(session.workingDirectory == "/Users/test/projects/myrepo")
    }

    @Test("empty parent title falls back to the unattached label")
    func emptyParentTitleFallsBack() {
        let parent = TerminalSession(
            title: "",
            workingDirectory: "/tmp",
            agentKind: .shell,
            agentState: .running
        )

        let title = FloatingPanelStoreFactory.makeTitle(parentWorkspace: parent)
        #expect(title == "floating panel")
    }

    @Test("never seeds a literal tilde for working directory")
    func neverSeedsLiteralTilde() throws {
        let store = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: nil,
            fallbackHome: "/Users/example"
        )

        let session = try #require(store.selectedSession)
        #expect(session.workingDirectory != "~")
        #expect(session.workingDirectory.first == "/")
    }

    @Test("factory stores carry floating compact identity; plain stores do not")
    func factoryStoresCarryFloatingCompactIdentity() {
        let floating = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: nil,
            fallbackHome: Self.fallbackHome
        )
        #expect(floating.compactTerminalKind == .floatingPanel)
        #expect(SessionStore().compactTerminalKind == nil)
    }

    @Test("each call returns a fresh store so per-workspace dispatch keeps slots distinct")
    func makeStoreReturnsDistinctInstances() {
        let parent = TerminalSession(
            title: "alpha",
            workingDirectory: "/tmp/a",
            agentKind: .shell,
            agentState: .running
        )

        let storeA = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: parent,
            fallbackHome: Self.fallbackHome
        )
        let storeB = FloatingPanelStoreFactory.makeStore(
            parentWorkspace: parent,
            fallbackHome: Self.fallbackHome
        )

        // Distinct session IDs even when the parent is the same — the
        // controller is responsible for caching by workspace ID, not
        // the factory.
        #expect(storeA.selectedSession?.id != storeB.selectedSession?.id)
    }
}
