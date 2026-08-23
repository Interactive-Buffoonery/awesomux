import AwesoMuxConfig
import AwesoMuxCore

enum ManagedSSHOfferPolicy {
    enum AddResult: Equatable {
        case added(String)
        case duplicate
        case invalid
    }

    /// What happens when an SSH connection to a destination is detected.
    enum OfferDecision: Equatable {
        /// Carries the persistence owner the user remembered. Nil means
        /// local-amx — a daemon on this machine in front of the SSH child;
        /// a name means the remote host owns the session. Reading it from the
        /// stored entry is the point of storing it: a remembered destination
        /// that carried only its name converted every later connection to
        /// local-amx no matter what the user chose the first time.
        case connectAutomatically(sessionName: RemoteSessionName?)
        case offer
        case none
    }

    /// Precedence, most specific first. A per-destination answer outranks a
    /// blanket one, and within each level a decline outranks a grant.
    ///
    /// The negative-before-positive ordering is the load-bearing part. With it
    /// reversed, "Never Ask for Any Destination" was inert whenever the global
    /// always-toggle was on — including when the user picked it in the sheet
    /// that a failed auto-connect had just put in front of them, so a decline
    /// made seconds earlier changed nothing. Auto-connecting is the option with
    /// side effects, so a config that somehow says both things fails safe to
    /// the one that doesn't act.
    static func decision(target: RemoteTarget, config: WorkspaceConfig) -> OfferDecision {
        if isIgnored(target: target, config: config) {
            return .none
        }
        if let entry = alwaysManagedEntry(target: target, config: config) {
            switch resolvedSessionName(for: entry) {
            case .valid(let sessionName):
                return .connectAutomatically(sessionName: sessionName)
            case .unusable:
                // A stored name that no longer validates must not quietly
                // become a local-amx connection: that is the silent owner
                // inversion this entry exists to prevent. Ask instead — but
                // still not over the top of a blanket decline, which is the
                // one answer that outranks asking.
                return config.managedSSHOffersEnabled ? .offer : .none
            }
        }
        guard config.managedSSHOffersEnabled else {
            return .none
        }
        if config.managedSSHAlwaysManageAllDestinations {
            return .connectAutomatically(sessionName: nil)
        }
        return .offer
    }

    static func isIgnored(target: RemoteTarget, config: WorkspaceConfig) -> Bool {
        normalizedIgnoredDestinations(in: config).contains(target.sshDestination)
    }

    private static func alwaysManagedEntry(
        target: RemoteTarget,
        config: WorkspaceConfig
    ) -> ManagedSSHAlwaysManagedEntry? {
        normalizedAlwaysManaged(in: config)[target.sshDestination]
    }

    /// Whether the config records this destination *with this owner* — the
    /// check the connect sheet makes after writing, to tell a real save from a
    /// rejected one.
    ///
    /// It cannot be spelled `alwaysManagedEntry(…)?.sessionName == name`:
    /// optional chaining flattens that to `String?`, so a destination that was
    /// never stored compares nil-to-nil against a local-amx execution and a
    /// failed save reports itself as a success.
    static func records(
        target: RemoteTarget,
        sessionName: RemoteSessionName?,
        in config: WorkspaceConfig
    ) -> Bool {
        guard let entry = alwaysManagedEntry(target: target, config: config) else {
            return false
        }
        return entry.sessionName == sessionName?.rawValue
    }

    /// Destinations for display, ordered. The store is keyed, so it has no
    /// order of its own and an unsorted render would reshuffle on every edit.
    static func sortedAlwaysManagedDestinations(in config: WorkspaceConfig) -> [String] {
        config.managedSSHAlwaysManaged.keys.sorted()
    }

    /// Destinations with the owner each one remembered, for display. Without
    /// this the Settings row shows a bare destination and the persistence
    /// owner — the entire reason the store is keyed rather than a list — is
    /// invisible on the one screen that manages it.
    static func sortedAlwaysManagedEntries(
        in config: WorkspaceConfig
    ) -> [(destination: String, sessionName: String?)] {
        config.managedSSHAlwaysManaged
            .sorted { $0.key < $1.key }
            .map { (destination: $0.key, sessionName: $0.value.sessionName) }
    }

    static func addIgnoredDestination(
        _ text: String,
        to config: inout WorkspaceConfig
    ) -> AddResult {
        guard let destination = validDestination(from: text) else {
            return .invalid
        }
        removeAlwaysManagedDestination(destination, from: &config)
        guard !normalizedIgnoredDestinations(in: config).contains(destination) else {
            return .duplicate
        }
        config.managedSSHOfferIgnoredDestinations.append(destination)
        return .added(destination)
    }

    /// `sessionName` nil records local-amx persistence; a name records that the
    /// remote host owns the session. A non-nil name that does not validate is
    /// rejected outright rather than stored and downgraded on read.
    static func addAlwaysManagedDestination(
        _ text: String,
        sessionName: RemoteSessionName? = nil,
        to config: inout WorkspaceConfig
    ) -> AddResult {
        guard let destination = validDestination(from: text) else {
            return .invalid
        }
        removeIgnoredDestination(destination, from: &config)
        let entry = ManagedSSHAlwaysManagedEntry(sessionName: sessionName?.rawValue)
        // `.duplicate` means "already recorded, exactly as asked" — the owner
        // is part of that. Keying it on the destination alone made the stored
        // owner unchangeable: the sheet's post-write check is owner-sensitive,
        // so it read the untouched entry as a failed save, reported disk
        // trouble that had not happened, and dropped the user's connect.
        if let existing = normalizedAlwaysManaged(in: config)[destination], existing == entry {
            return .duplicate
        }
        // Remove first: a stored key that merely normalizes to `destination`
        // would otherwise survive alongside the one written here.
        removeAlwaysManagedDestination(destination, from: &config)
        config.managedSSHAlwaysManaged[destination] = entry
        return .added(destination)
    }

    static func removeIgnoredDestination(
        _ destination: String,
        from config: inout WorkspaceConfig
    ) {
        let normalized = normalizedIdentity(of: destination)
        config.managedSSHOfferIgnoredDestinations.removeAll { stored in
            matches(stored: stored, normalized: normalized, raw: destination)
        }
    }

    static func removeAlwaysManagedDestination(
        _ destination: String,
        from config: inout WorkspaceConfig
    ) {
        let normalized = normalizedIdentity(of: destination)
        config.managedSSHAlwaysManaged = config.managedSSHAlwaysManaged.filter { stored, _ in
            !matches(stored: stored, normalized: normalized, raw: destination)
        }
    }

    private enum ResolvedSessionName {
        case valid(RemoteSessionName?)
        case unusable
    }

    private static func resolvedSessionName(
        for entry: ManagedSSHAlwaysManagedEntry
    ) -> ResolvedSessionName {
        guard let rawValue = entry.sessionName else {
            return .valid(nil)
        }
        guard let sessionName = RemoteSessionName(rawValue: rawValue) else {
            return .unusable
        }
        return .valid(sessionName)
    }

    private static func validDestination(from text: String) -> String? {
        SSHWorkspaceDestinationValidation.target(from: text)?.sshDestination
    }

    private static func normalizedIdentity(of destination: String) -> String? {
        SSHWorkspaceDestinationValidation.target(from: destination)?.sshDestination
    }

    /// `normalized` is hoisted by the caller: parsing the search term once per
    /// element instead of once per call doubled the parse count on both lists.
    /// The raw fallback is what keeps a hand-edited unparseable row removable.
    private static func matches(stored: String, normalized: String?, raw: String) -> Bool {
        guard let normalized else {
            return stored == raw
        }
        return normalizedIdentity(of: stored) == normalized
    }

    private static func normalizedIgnoredDestinations(in config: WorkspaceConfig) -> Set<String> {
        Set(
            config.managedSSHOfferIgnoredDestinations.compactMap {
                SSHWorkspaceDestinationValidation.target(from: $0)?.sshDestination
            }
        )
    }

    /// Keyed by normalized identity, so a hand-edited config whose key is
    /// unparseable simply never matches a real target and fails safe.
    ///
    /// Collisions are the reason this is not a one-line `reduce`. Key identity
    /// is many-to-one — `"prod"`, `"@prod"`, and `"  prod  "` all normalize to
    /// `prod` — and the old `[String]` collapsed those into a `Set`, where
    /// ambiguity was free because only membership was read. Attaching an owner
    /// to the key made ambiguity consequential, and iterating a `Dictionary`
    /// resolves it by hash order, which Swift seeds per process: the same
    /// config file picked a different persistence owner on different launches,
    /// measured at 10 of 12 runs one way and 2 of 12 the other. That is the
    /// silent owner inversion this schema exists to prevent, made intermittent.
    ///
    /// The key that is already its own normalized form wins, because it is the
    /// only form the app itself ever writes; sort order breaks the remaining
    /// tie so the outcome is fixed rather than merely likely.
    private static func normalizedAlwaysManaged(
        in config: WorkspaceConfig
    ) -> [String: ManagedSSHAlwaysManagedEntry] {
        var normalized: [String: ManagedSSHAlwaysManagedEntry] = [:]
        var winnerIsCanonical: Set<String> = []
        for (stored, entry) in config.managedSSHAlwaysManaged.sorted(by: { $0.key < $1.key }) {
            guard let destination = normalizedIdentity(of: stored) else { continue }
            let isCanonical = stored == destination
            if normalized[destination] != nil, !isCanonical || winnerIsCanonical.contains(destination) {
                continue
            }
            normalized[destination] = entry
            if isCanonical {
                winnerIsCanonical.insert(destination)
            }
        }
        return normalized
    }
}
