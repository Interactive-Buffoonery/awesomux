import Testing
import AwesoMuxCore
@testable import awesoMux

@Suite("Floating slot book")
@MainActor
struct FloatingSlotBookTests {
    @Test("toggle shows a slot that is not open")
    func showsUnopened() {
        #expect(FloatingSlotBook.toggleAction(isOpen: false, isVisible: false, isKeyWindow: false) == .show)
    }

    @Test("toggle restores focus for an open non-key slot")
    func restoresFocus() {
        #expect(FloatingSlotBook.toggleAction(isOpen: true, isVisible: true, isKeyWindow: false) == .restoreFocus)
    }

    @Test("toggle dismisses an open visible key slot")
    func dismissesKey() {
        #expect(FloatingSlotBook.toggleAction(isOpen: true, isVisible: true, isKeyWindow: true) == .dismiss)
    }

    @Test("ensureStore seeds once then returns the cached slot")
    func ensureStoreCaches() {
        let book = FloatingSlotBook()
        let id = TerminalSession.ID()
        var made = 0
        let makeStore: () -> SessionStore = {
            made += 1
            return SessionStore(groups: [SessionGroup(name: "Floating Panel", sessions: [])], selectedSessionID: nil)
        }
        _ = book.ensureStore(for: id, make: makeStore)
        _ = book.ensureStore(for: id, make: makeStore)
        #expect(made == 1)
        #expect(book.store(for: id) != nil)
    }

    @Test("the unattached sentinel migrates onto the first real workspace")
    func migratesSentinel() {
        let book = FloatingSlotBook()
        let sentinel = FloatingSlotBook.unattachedWorkspaceID
        _ = book.ensureStore(for: sentinel) {
            SessionStore(groups: [SessionGroup(name: "Floating Panel", sessions: [])], selectedSessionID: nil)
        }
        book.setActive(sentinel)
        let real = TerminalSession.ID()
        #expect(book.migrateUnattached(to: real) != nil)
        #expect(book.store(for: sentinel) == nil)
        #expect(book.store(for: real) != nil)
        #expect(book.activeWorkspaceID == real)
    }
}
