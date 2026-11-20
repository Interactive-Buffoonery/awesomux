import AwesoMuxCore
import SwiftUI

@MainActor
@Observable
final class PrimaryPaneTree {
    struct Key: Hashable {
        let sessionID: TerminalSession.ID
        let selectionRevision: UInt64
        let readinessRevision: UInt64
    }

    struct Mount: Equatable {
        let key: Key
        let generation: UUID
    }

    private(set) var mount: Mount?
    private(set) var size: CGSize?
    private var drags: [TerminalSplit.ID: UUID] = [:]

    func attach(_ mount: Mount, size: CGSize) {
        self.mount = mount
        self.size = Self.validSize(size)
        drags.removeAll()
    }

    func measure(_ mount: Mount, size: CGSize) {
        guard self.mount == mount else { return }
        self.size = Self.validSize(size)
    }

    func detach(_ mount: Mount) {
        guard self.mount == mount else { return }
        self.mount = nil
        size = nil
        drags.removeAll()
    }

    func beginDrag(_ token: UUID, splitID: TerminalSplit.ID, mount: Mount) -> Bool {
        guard self.mount == mount, drags[splitID] == nil else { return false }
        drags[splitID] = token
        return true
    }

    func ownsDrag(_ token: UUID, splitID: TerminalSplit.ID, mount: Mount) -> Bool {
        self.mount == mount && drags[splitID] == token
    }

    func endDrag(_ token: UUID, splitID: TerminalSplit.ID, mount: Mount) {
        guard ownsDrag(token, splitID: splitID, mount: mount) else { return }
        drags.removeValue(forKey: splitID)
    }

    func balanceSize(for mount: Mount) -> CGSize? {
        guard self.mount == mount, drags.isEmpty else { return nil }
        return size
    }

    private static func validSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return size
    }
}

@MainActor
struct PrimaryPaneTreeContext {
    let tree: PrimaryPaneTree
    let store: SessionStore
    let runtime: GhosttyRuntime
    let key: PrimaryPaneTree.Key

    init(tree: PrimaryPaneTree, store: SessionStore, runtime: GhosttyRuntime, sessionID: TerminalSession.ID) {
        self.tree = tree
        self.store = store
        self.runtime = runtime
        key = Self.key(store: store, runtime: runtime, sessionID: sessionID)
    }

    static func key(store: SessionStore, runtime: GhosttyRuntime, sessionID: TerminalSession.ID) -> PrimaryPaneTree.Key {
        PrimaryPaneTree.Key(
            sessionID: sessionID,
            selectionRevision: store.selectionRevision,
            readinessRevision: runtime.readinessRevision
        )
    }

    var isCurrent: Bool {
        store.selectedSessionID == key.sessionID && runtime.isReady
            && key == Self.key(store: store, runtime: runtime, sessionID: key.sessionID)
    }

    var currentMount: PrimaryPaneTree.Mount? {
        guard isCurrent, let mount = tree.mount, mount.key == key else { return nil }
        return mount
    }
}

extension EnvironmentValues {
    @Entry var primaryPaneTreeContext: PrimaryPaneTreeContext? = nil
}

/// Only the measurement probe has generation-dependent view identity.
struct PrimaryPaneTreeMeasurement: View {
    private struct Sample: Equatable {
        let mount: PrimaryPaneTree.Mount
        let size: CGSize
    }

    let context: PrimaryPaneTreeContext
    @State private var generation: UUID?

    var body: some View {
        GeometryReader { geometry in
            let sample = generation.map {
                Sample(mount: .init(key: context.key, generation: $0), size: geometry.size)
            }
            Color.clear
                .onAppear {
                    guard context.isCurrent else { return }
                    let generation = UUID()
                    self.generation = generation
                    context.tree.attach(.init(key: context.key, generation: generation), size: geometry.size)
                }
                .onChange(of: sample) { _, sample in
                    guard context.isCurrent, let sample else { return }
                    context.tree.measure(sample.mount, size: sample.size)
                }
                .onDisappear {
                    guard let generation else { return }
                    context.tree.detach(.init(key: context.key, generation: generation))
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
