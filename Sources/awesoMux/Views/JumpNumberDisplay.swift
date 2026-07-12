/// How a collapsed-rail tile renders its ⌘1–9 jump number.
///
/// Numbers are collapsed-mode-only (INT-527). At rest the rail is clean and
/// the digit reveals only while ⌘ is held; the always-on setting instead
/// pins a small digit below each tile for passive discoverability.
enum JumpNumberDisplay: Equatable {
    case hidden
    case overlay    // centered over the tile while ⌘ is held
    case belowTile  // always-on setting

    static func resolve(collapsed: Bool, alwaysOn: Bool, commandHeld: Bool) -> JumpNumberDisplay {
        guard collapsed else { return .hidden }
        if alwaysOn { return .belowTile }
        return commandHeld ? .overlay : .hidden
    }
}
