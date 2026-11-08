import Testing
@testable import awesoMux

struct AppDropdownNavigationTests {
    @Test func navigationSkipsDisabledRowsAndWraps() {
        #expect(AppDropdownNavigation.next(after: nil, forward: true, enabled: [1, 3]) == 1)
        #expect(AppDropdownNavigation.next(after: 1, forward: true, enabled: [1, 3]) == 3)
        #expect(AppDropdownNavigation.next(after: 3, forward: true, enabled: [1, 3]) == 1)
        #expect(AppDropdownNavigation.next(after: 1, forward: false, enabled: [1, 3]) == 3)
        #expect(AppDropdownNavigation.next(after: nil, forward: false, enabled: [1, 3]) == 3)
        #expect(AppDropdownNavigation.next(after: 7, forward: true, enabled: []) == nil)
        #expect(AppDropdownNavigation.next(after: 7, forward: true, enabled: [3]) == 3)
    }
    @Test func typingFindsEnabledChoicesCaseInsensitively() {
        let titles = ["New Agent in", "Personal", "Development", "Démo", "Disabled"]
        #expect(AppDropdownNavigation.match(prefix: "de", titles: titles, enabled: [1, 2, 3]) == 2)
        #expect(AppDropdownNavigation.match(prefix: "DEMO", titles: titles, enabled: [1, 2, 3]) == 3)
        #expect(AppDropdownNavigation.match(prefix: "disabled", titles: titles, enabled: [1, 2, 3]) == nil)
        #expect(AppDropdownNavigation.match(prefix: "missing", titles: titles, enabled: []) == nil)
    }

    @Test func selectionFollowsIdentityAcrossRenamesReordersAndRemoval() {
        #expect(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a", "b"], enabled: [0, 1], fallback: 0) == 1)
        #expect(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["b", "a"], enabled: [0, 1], fallback: 1) == 0)
        #expect(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a"], enabled: [0], fallback: 0) == 0)
        #expect(AppDropdownNavigation.reconcile(current: 1, old: ["a", "b"], new: ["a", "b"], enabled: [0], fallback: 0) == 0)
        #expect(AppDropdownNavigation.reconcile(current: nil, old: ["a"], new: ["a"], enabled: [], fallback: nil) == nil)
    }

}
