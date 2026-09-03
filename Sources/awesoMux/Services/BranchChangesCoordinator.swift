import AwesoMuxCore
import Foundation

/// Owns the complete lifetime of Show Branch Changes work.
///
/// Pane ordering and cache-slot ordering share one ticket sequence, but they do
/// not share one lifetime: a pane replaces only its own task while two panes may
/// legitimately request the same cache slot. Keeping both concerns here makes
/// cancellation and high-water cleanup follow the tasks that can still finish.
@MainActor
final class BranchChangesCoordinator {
    private struct PaneTask {
        let ticket: Int
        let task: Task<Void, Never>
    }

    private var nextTicket = 0
    private var paneTickets: [TerminalPane.ID: Int] = [:]
    private var paneTasks: [TerminalPane.ID: PaneTask] = [:]
    private var activeTickets: Set<Int> = []
    private var registeredTickets: [URL: Int] = [:]
    nonisolated private let slots = BranchChangesSlotRegistry()

    /// Starts a new pane generation and cancels the task it replaces.
    func begin(paneID: TerminalPane.ID) -> Int {
        paneTasks[paneID]?.task.cancel()
        nextTicket += 1
        paneTickets[paneID] = nextTicket
        activeTickets.insert(nextTicket)
        return nextTicket
    }

    /// Attaches the task after its closure has been formed with the issued ticket.
    func attach(_ task: Task<Void, Never>, ticket: Int, paneID: TerminalPane.ID) {
        guard paneTickets[paneID] == ticket else {
            task.cancel()
            return
        }
        paneTasks[paneID] = PaneTask(ticket: ticket, task: task)
    }

    func isCurrent(_ ticket: Int, paneID: TerminalPane.ID) -> Bool {
        paneTickets[paneID] == ticket
    }

    /// Retires one completed task and any high-water entries no older task can
    /// still reach. Arbitrary LRU cleanup would let a late completion win again;
    /// the minimum live ticket is the proof that makes removal safe.
    func finish(_ ticket: Int, paneID: TerminalPane.ID) {
        activeTickets.remove(ticket)
        if paneTasks[paneID]?.ticket == ticket {
            paneTasks.removeValue(forKey: paneID)
        }
        if paneTickets[paneID] == ticket {
            paneTickets.removeValue(forKey: paneID)
        }

        guard let oldestActive = activeTickets.min() else {
            registeredTickets.removeAll(keepingCapacity: true)
            slots.removeEntries(olderThan: Int.max)
            return
        }
        registeredTickets = registeredTickets.filter { $0.value >= oldestActive }
        slots.removeEntries(olderThan: oldestActive)
    }

    /// Accepts only monotonically newer self-write registrations for one path.
    func shouldRegister(_ ticket: Int, for fileURL: URL) -> Bool {
        guard (registeredTickets[fileURL] ?? 0) < ticket else { return false }
        registeredTickets[fileURL] = ticket
        return true
    }

    /// Called inside the generated-cache write lock, so claiming and writing are
    /// one ordered operation even though the render itself runs off MainActor.
    nonisolated func claimSlot(_ slot: String, ticket: Int) -> Bool {
        slots.claim(slot, ticket: ticket)
    }
}

private final class BranchChangesSlotRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tickets: [String: Int] = [:]

    func claim(_ slot: String, ticket: Int) -> Bool {
        lock.withLock {
            guard (tickets[slot] ?? 0) < ticket else { return false }
            tickets[slot] = ticket
            return true
        }
    }

    func removeEntries(olderThan ticket: Int) {
        lock.withLock {
            tickets = tickets.filter { $0.value >= ticket }
        }
    }
}
