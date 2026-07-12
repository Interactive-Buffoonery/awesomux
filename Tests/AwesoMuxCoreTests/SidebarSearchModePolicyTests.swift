import Testing
@testable import AwesoMuxCore

@Suite("Sidebar search mode policy")
struct SidebarSearchModePolicyTests {
    @Test("no-match feedback requires an active expanded-mode filter")
    func noMatchFeedbackRequiresExpandedFilter() {
        #expect(!SidebarSearchModePolicy.showsNoMatches(
            isFiltering: false,
            hasVisibleResults: false,
            displayMode: .expanded
        ))
        #expect(!SidebarSearchModePolicy.showsNoMatches(
            isFiltering: true,
            hasVisibleResults: false,
            displayMode: .collapsed
        ))
        #expect(!SidebarSearchModePolicy.showsNoMatches(
            isFiltering: true,
            hasVisibleResults: true,
            displayMode: .expanded
        ))
        #expect(SidebarSearchModePolicy.showsNoMatches(
            isFiltering: true,
            hasVisibleResults: false,
            displayMode: .expanded
        ))
    }

    @Test("entering the collapsed rail clears the inline search")
    func collapsedRailClearsInlineSearch() {
        #expect(SidebarSearchModePolicy.query(
            afterChangingTo: .collapsed,
            currentQuery: "codex"
        ) == "")
        #expect(SidebarSearchModePolicy.query(
            afterChangingTo: .expanded,
            currentQuery: "codex"
        ) == "codex")
    }
}
