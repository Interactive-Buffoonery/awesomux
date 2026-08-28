import AwesoMuxCore

@MainActor
struct TerminalPaneLiveTitleResolver {
    static func title(for pane: TerminalPane, from box: LiveTitleBox) -> String {
        box.paneTitle(for: pane.id) ?? pane.title
    }
}
