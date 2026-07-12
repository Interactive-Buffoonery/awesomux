import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@MainActor
@Suite("Pane title-bar band treatment")
struct PaneTitleBarBandTreatmentTests {
    @Test("default pane color always uses neutral chrome")
    func defaultColorUsesChrome() {
        #expect(PaneTitleBarView.bandTreatment(for: nil, reduceTransparency: false) == .chrome)
        #expect(PaneTitleBarView.bandTreatment(for: nil, reduceTransparency: true) == .chrome)
    }

    @Test("normal mode preserves the translucent wash for every pane color")
    func normalModeUsesWash() {
        #expect(PaneTitleBarView.washOpacity == 0.22)

        for color in WorkspaceGroupColor.allCases {
            #expect(
                PaneTitleBarView.bandTreatment(
                    for: .palette(color),
                    reduceTransparency: false
                ) == .wash(ProjectTint.accent(for: color))
            )
        }
    }

    @Test("Reduce Transparency selects the opaque muted band for every pane color")
    func reduceTransparencyUsesOpaqueBand() {
        for color in WorkspaceGroupColor.allCases {
            #expect(
                PaneTitleBarView.bandTreatment(
                    for: .palette(color),
                    reduceTransparency: true
                ) == .opaqueMuted(ProjectTint.accent(for: color))
            )
        }
    }

    @Test("toggling Reduce Transparency changes treatment without changing pane identity")
    func settingChangePreservesIdentity() {
        let color = PaneColor.palette(.teal)
        let normal = PaneTitleBarView.bandTreatment(for: color, reduceTransparency: false)
        let reduced = PaneTitleBarView.bandTreatment(for: color, reduceTransparency: true)

        #expect(normal == .wash(.teal))
        #expect(reduced == .opaqueMuted(.teal))
        #expect(normal != reduced)
    }

    @Test("Reduce Transparency participates in equality for live environment updates")
    func settingParticipatesInEquality() {
        let pane = TerminalPane(title: "left", workingDirectory: "/tmp")
        let session = TerminalSession(
            title: "workspace",
            workingDirectory: "/tmp",
            layout: .pane(pane)
        )
        let store = SessionStore(
            groups: [SessionGroup(name: "group", sessions: [session])],
            selectedSessionID: session.id
        )
        let coordinator = PaneDragCoordinator()
        let runtime = GhosttyRuntime()

        let normal = PaneTitleBarView(
            session: session,
            pane: pane,
            sessionStore: store,
            dragCoordinator: coordinator,
            runtime: runtime,
            reduceTransparency: false
        )
        let reduced = PaneTitleBarView(
            session: session,
            pane: pane,
            sessionStore: store,
            dragCoordinator: coordinator,
            runtime: runtime,
            reduceTransparency: true
        )

        #expect(normal != reduced)
        #expect(normal == normal)
    }
}
