import AppKit
import AwesoMuxConfig
import AwesoMuxCore
import DesignSystem
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SidebarDragPointerPolicy {
    static func hoverPublication(
        isDragActive: Bool,
        pointerInside: Bool
    ) -> Bool? {
        if isDragActive, !pointerInside { return nil }
        return pointerInside
    }

    static func clearPublication(
        wasDragActive: Bool,
        resampledPointerInside: Bool
    ) -> Bool? {
        wasDragActive ? resampledPointerInside : nil
    }
}

struct SidebarView: View {
    @Bindable var sessionStore: SessionStore
    let ghosttyRuntime: GhosttyRuntime
    let workspacesWithBackgroundedFloatingWork: Set<TerminalSession.ID>
    let promotedSessionID: TerminalSession.ID?
    let promotionPulseSessionID: TerminalSession.ID?
    let onCloseWorkspace: (TerminalSession) -> Void
    let onClearWorkspace: (TerminalSession) -> Void
    let onCloseWorkspaceGroup: (SessionGroup) -> Void
    let onRenameWorkspace: (TerminalSession) -> Void
    let onRenameWorkspaceGroup: (SessionGroup) -> Void
    let onNewWorkspaceGroup: () -> Void
    let onConnectViaSSH: (SessionGroup) -> Void
    let canMakeWorkspaceManaged: (TerminalSession) -> Bool
    let onMakeWorkspaceManaged: (TerminalSession) -> Void
    let onOpenQuickSettings: () -> Void
    /// Opens the command palette from the collapsed rail's search button —
    /// the rail is too narrow for the inline search field (INT-537).
    let onToggleCommandPalette: () -> Void
    /// Jump to an exact agent pane from the activity panel (INT-722). Wired by
    /// the app to select + focus + acknowledge that pane.
    let onFocusPane: (TerminalSession.ID, UUID) -> Void
    let focusRequestID: UUID?
    /// Live sidebar width (updated per divider tick). Read in `body` (via the
    /// computed `displayMode`) so the sidebar re-renders — and its layout mode
    /// switches live as the drag crosses width bands — without re-rendering
    /// `ContentView` or the terminal pane (INT-535).
    let sidebarLiveWidth: SidebarLiveWidth
    let resampleSidebarPointer: () -> Bool?
    let onSidebarHover: (Bool) -> Void

    @State private var searchText = ""
    @State private var collapsedGroupIDs = Set<SessionGroup.ID>()
    @State private var activeDragKind: SidebarDragKind?
    @State private var activeDragID: UUID?
    @State private var activeGroupDragSourceID: SessionGroup.ID?
    @State private var activeWorkspaceDragSourceID: TerminalSession.ID?
    @State private var activeWorkspaceDragSourceGroupID: SessionGroup.ID?
    /// Whether the active workspace drag started from a pinned tile. Frozen at
    /// drag start (not read live from the store) so a mid-drag ⌥⌘P pin/unpin
    /// can't flip which delegate family accepts the drop. Group drop targets
    /// reject when true and the pinned-section delegate accepts only when
    /// true — cross-boundary pin/unpin drags are out of scope for v1.
    @State private var activeWorkspaceDragSourceWasPinned = false
    @State private var dragClearScheduler = SidebarDragClearScheduler()
    @State private var reorderAnnouncer = SidebarReorderAnnouncer()
    @State private var lastDragWatchdogRefresh = Date.distantPast
    @State private var sidebarDragClearDeadline: Date?
    @State private var groupFrames: [SessionGroup.ID: CGRect] = [:]
    @State private var groupDropIndex: Int?
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedRowTarget: SidebarVisibleRowTarget?
    @FocusState private var isCollapsedEmptyActionFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var isCommandKeyHeld = false
    // Focus-visible: the accent `awFocusRing` should only show while the user is
    // actually navigating by keyboard, not on the mouse-selected row. (The blue
    // macOS *system* ring is suppressed entirely via `.focusEffectDisabled()`.)
    // Set true only on explicit keyboard navigation — `focusKeyboardTarget(
    // viaKeyboardNavigation: true)` — never on programmatic default/auto-focus,
    // and cleared on any pointer interaction (tap/hover). Mouse users still see
    // the selected row via its tinted border.
    @State private var isKeyboardNavigating = false
    /// INT-722 roster panel. Transient by design — resets on relaunch.
    @State private var activityPanelOpen = false
    @State private var activityPanelScrollTarget: AgentDisplayState?

    private let groupCoordinateSpaceName = "sidebar-groups"

    /// Rendered layout mode. Derived from the live width so it switches as a drag
    /// crosses width bands. Computed (not a stored param) so every use reads the
    /// live width reactively and re-renders only this pane (INT-535).
    private var displayMode: SidebarWidthMode {
        SidebarWidthPolicy.mode(for: sidebarLiveWidth.value)
    }

    var body: some View {
        // Trim once at the body and thread the normalized query through every
        // dependent computation. Two readers of `searchText` previously
        // disagreed on whether whitespace-only input meant "filtering": the
        // trim happened in `computedSnapshot` but not here, so a single space
        // would force-expand collapsed groups while the snapshot rendered as
        // unfiltered.
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !normalizedQuery.isEmpty
        let snapshot = computedSnapshot(query: normalizedQuery, isFiltering: isFiltering)
        // Disambiguate across pinned AND in-group tiles, keyed by each pinned
        // tile's ORIGIN group identity — feeding pinned entries under a
        // synthetic group would change the "N of M" qualifiers a pinned tile
        // shares with its still-in-group twin (INT-737 review).
        let disambiguationInput: [SidebarGroupEntry] =
            snapshot.pinned.isEmpty
            ? snapshot.entries
            : snapshot.entries
                + snapshot.pinned.map { pinnedEntry in
                    SidebarGroupEntry(
                        group: pinnedEntry.originGroup,
                        unfilteredIndex: pinnedEntry.originGroupUnfilteredIndex,
                        sessions: [pinnedEntry.entry]
                    )
                }
        let duplicateDisambiguationBySessionID =
            SidebarDuplicateDisambiguator.disambiguationBySessionID(for: disambiguationInput)
        let density = SidebarDensity(compact: appSettingsStore.general.value.sidebarCompactMode)
        let visibleGroupIDs = snapshot.entries.map { $0.group.id }
        // Pinned tiles render above every group, so ⌘1-9 must count them first
        // to keep the on-tile jump digits truthful (INT-737).
        let jumpOrderedSessions =
            snapshot.pinned.isEmpty
            ? snapshot.entries.flatMap(\.sessions)
            : snapshot.pinned.map(\.entry) + snapshot.entries.flatMap(\.sessions)
        let jumpIndexBySessionID = Dictionary(
            jumpOrderedSessions
                .enumerated()
                .map { ($0.element.session.id, $0.offset + 1) },
            uniquingKeysWith: { first, _ in first }
        )
        let visibleRows = SidebarVisibleRows.rows(
            pinned: snapshot.pinned,
            for: snapshot.entries,
            collapsedGroupIDs: collapsedGroupIDs,
            isFiltering: isFiltering
        )
        let rotorEntries = SidebarVisibleRows.rotorEntries(
            pinned: snapshot.pinned,
            for: snapshot.entries
        )
        // Computed once per render and captured by the preference-change
        // closure below, which would otherwise rebuild this set on every
        // layout pass during a drag.
        let visibleGroupIDSet = Set(visibleGroupIDs)
        let structuralAnimation: Animation? =
            reduceMotion || isFiltering
            ? nil
            : .easeOut(duration: 0.12)

        // Precompute group→index map once per render so SidebarGroupView's
        // currentGroupIndex parameter is O(1) instead of O(N) per ForEach
        // iteration (was O(N²) over the whole sidebar).
        //
        // `uniquingKeysWith:` (not `uniqueKeysWithValues:`) so a corrupted
        // snapshot with duplicate group IDs doesn't trap fatally at render
        // time — we keep the first occurrence (the one rendered first in
        // the sidebar) and ignore later collisions.
        let groupIndexLookup: [SessionGroup.ID: Int] = Dictionary(
            sessionStore.groups.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        return VStack(spacing: 0) {
            searchHeader(topMatchID: snapshot.topMatchID)

            GeometryReader { scrollViewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: density.groupStackSpacing) {
                        if !snapshot.pinned.isEmpty {
                            pinnedSection(
                                pinned: snapshot.pinned,
                                density: density,
                                isFiltering: isFiltering,
                                jumpIndexBySessionID: jumpIndexBySessionID,
                                duplicateDisambiguationBySessionID: duplicateDisambiguationBySessionID
                            )
                        }

                        if sessionStore.groups.isEmpty,
                            !isFiltering,
                            displayMode == .collapsed
                        {
                            CollapsedEmptySidebarAction(
                                onNewWorkspace: addWorkspaceInCurrentContext,
                                focused: $isCollapsedEmptyActionFocused
                            )
                        }

                        ForEach(snapshot.entries, id: \.group.id) { entry in
                            SidebarGroupView(
                                group: entry.group,
                                entries: entry.sessions,
                                density: density,
                                tint: ProjectTint(
                                    groupName: entry.group.name,
                                    color: entry.group.color,
                                    index: entry.unfilteredIndex
                                ),
                                workspacesWithBackgroundedFloatingWork: workspacesWithBackgroundedFloatingWork,
                                promotedSessionID: promotedSessionID,
                                promotionPulseSessionID: promotionPulseSessionID,
                                // Force-expand groups while a filter is active so
                                // matched sessions don't hide under a collapsed
                                // header — phantom counts confuse search users.
                                isCollapsed: !isFiltering
                                    && collapsedGroupIDs.contains(entry.group.id),
                                isFiltering: isFiltering,
                                displayMode: displayMode,
                                duplicateDisambiguationBySessionID:
                                    duplicateDisambiguationBySessionID,
                                allGroups: sessionStore.groups,
                                jumpIndexBySessionID: jumpIndexBySessionID,
                                selectedSessionID: sessionStore.selectedSessionID,
                                onToggle: {
                                    toggleGroup(entry.group.id)
                                },
                                onSelect: selectSession,
                                onNewSessionInGroup: {
                                    sessionStore.addSession(groupName: entry.group.name)
                                },
                                onConnectViaSSH: onConnectViaSSH,
                                canMakeWorkspaceManaged: canMakeWorkspaceManaged,
                                onMakeWorkspaceManaged: onMakeWorkspaceManaged,
                                onNewSessionHere: { session in
                                    sessionStore.addSession(
                                        workingDirectory: session.workingDirectory,
                                        groupName: entry.group.name
                                    )
                                },
                                onNewGroup: onNewWorkspaceGroup,
                                onRenameGroup: {
                                    onRenameWorkspaceGroup(entry.group)
                                },
                                onSetGroupColor: { color in
                                    sessionStore.setGroupColor(id: entry.group.id, color: color)
                                },
                                canRemoveGroup: entry.group.sessions.isEmpty
                                    && sessionStore.groups.count > 1,
                                // Same path as the header X / context menu —
                                // a direct `removeGroup` here would skip the
                                // VoiceOver announcement and the empty-remote
                                // confirm.
                                onRemoveGroup: {
                                    onCloseWorkspaceGroup(entry.group)
                                },
                                onCloseGroup: {
                                    onCloseWorkspaceGroup(entry.group)
                                },
                                onAcknowledge: { session in
                                    sessionStore.acknowledgeSession(id: session.id)
                                },
                                onMoveSession: moveSession,
                                onMoveGroup: moveGroup(fromIndex:toIndex:),
                                activeDragKind: activeDragKind,
                                activeDragID: activeDragID,
                                activeWorkspaceDragSourceID: activeWorkspaceDragSourceID,
                                activeWorkspaceDragSourceGroupID: activeWorkspaceDragSourceGroupID,
                                activeDragSourceIsPinned: activeWorkspaceDragSourceWasPinned,
                                onGroupDragStarted: beginGroupDrag,
                                onWorkspaceDragStarted: beginWorkspaceDrag,
                                onDragRefreshed: refreshSidebarDrag,
                                onDragEnded: clearSidebarDragState,
                                onDragExited: scheduleSidebarDragStateClear,
                                // Pass the raw Optional — SidebarGroupView gates
                                // Move Group actions on non-nil to prevent the
                                // wrong-row mutation that would otherwise result
                                // from a duplicate-ID snapshot (the `?? 0`
                                // fallback would route both occurrences' move
                                // actions to the FIRST occurrence's index).
                                currentGroupIndex: groupIndexLookup[entry.group.id],
                                totalGroupCount: sessionStore.groups.count,
                                onUncollapse: {
                                    collapsedGroupIDs.remove(entry.group.id)
                                },
                                onClose: onCloseWorkspace,
                                onClear: onClearWorkspace,
                                onRename: onRenameWorkspace,
                                onToggleNotificationsMute: { session in
                                    sessionStore.setNotificationsMuted(
                                        id: session.id,
                                        muted: !session.notificationsMuted
                                    )
                                },
                                onTogglePin: { session in
                                    sessionStore.togglePin(sessionID: session.id)
                                },
                                focusedRowTarget: $focusedRowTarget,
                                isKeyboardNavigating: $isKeyboardNavigating
                            )
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(
                                            key: SidebarGroupFramePreferenceKey.self,
                                            value: [
                                                entry.group.id: proxy.frame(in: .named(groupCoordinateSpaceName))
                                            ]
                                        )
                                }
                            )
                            // Group reorder drops are owned solely by the
                            // stack-level SidebarGroupReorderDropDelegate
                            // below. It is framed to the full viewport, so it
                            // already covers every group row during a group
                            // drag (the per-row workspace drop targets are
                            // disabled while dragging a group). A second
                            // per-section delegate here would be a redundant,
                            // separately-computed move owner — exactly the
                            // double-apply risk the review flagged.
                        }

                        if SidebarSearchModePolicy.showsNoMatches(
                            isFiltering: isFiltering,
                            hasVisibleResults: !snapshot.entries.isEmpty || !snapshot.pinned.isEmpty,
                            displayMode: displayMode
                        ) {
                            EmptySidebarFilterView(
                                searchText: normalizedQuery,
                                onClear: clearFilters
                            )
                        }
                    }
                    .coordinateSpace(name: groupCoordinateSpaceName)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: scrollViewport.size.height,
                        alignment: .topLeading
                    )
                    .contentShape(Rectangle())
                    .animation(structuralAnimation, value: visibleGroupIDs)
                    .onPreferenceChange(SidebarGroupFramePreferenceKey.self) { frames in
                        groupFrames = frames.filter { visibleGroupIDSet.contains($0.key) }
                    }
                    .onChange(of: visibleGroupIDs) { _, groupIDs in
                        let visibleIDs = Set(groupIDs)
                        groupFrames = groupFrames.filter { visibleIDs.contains($0.key) }
                        // Clear the held drop index on ANY change to the group
                        // list, not only when it shrinks past the index. A
                        // same-count reorder leaves an in-range-but-stale index
                        // pointing between different groups; dropUpdated will
                        // recompute it on the next hover.
                        if groupDropIndex != nil {
                            setGroupDropIndex(nil)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if activeDragKind == .group,
                            !isFiltering,
                            let groupDropIndex,
                            let y = SidebarInsertionResolver.insertionY(
                                forInsertionIndex: groupDropIndex,
                                orderedIDs: visibleGroupIDs,
                                frames: groupFrames,
                                spacing: density.groupStackSpacing
                            )
                        {
                            let clampedY = groupDropIndex == 0 ? max(0, y) : y
                            SidebarGroupInsertionIndicator(tint: Color.aw.mauve)
                                .offset(y: clampedY - SidebarGroupInsertionIndicator.height / 2)
                                .allowsHitTesting(false)
                        }
                    }
                    .sidebarDrop(
                        enabled: activeDragKind == .group && !isFiltering,
                        delegate: SidebarGroupReorderDropDelegate(
                            groupIDs: visibleGroupIDs,
                            groupFrames: groupFrames,
                            isFiltering: isFiltering,
                            activeDragKind: activeDragKind,
                            activeDragID: activeDragID,
                            activeGroupDragSourceID: activeGroupDragSourceID,
                            setInsertionIndex: setGroupDropIndex,
                            onMoveGroup: moveGroup,
                            onDragRefreshed: refreshSidebarDrag,
                            onDropEnded: clearSidebarDragState,
                            onDropExited: {
                                setGroupDropIndex(nil)
                                scheduleSidebarDragStateClear()
                            }
                        )
                    )
                }
                .scrollClipDisabled(displayMode == .collapsed)
            }
            // Per-keystroke score-driven reorders inside an active filter would
            // otherwise animate matched rows sliding under the user's finger.
            // Suppress animations on snapshot changes only while filtering;
            // group add/remove (the other animation source) is rare and not
            // visually noisy in this scope.
            .transaction { transaction in
                if isFiltering {
                    transaction.disablesAnimations = true
                }
            }

            if activityPanelOpen, displayMode != .collapsed {
                Divider()
                AgentActivityPanel(
                    groups: snapshot.roster.groups.map { group in
                        (state: group.state, items: group.rows.map(panelItem))
                    },
                    scrollTarget: activityPanelScrollTarget,
                    onSelect: { row in
                        // If the target session is hidden under the active search
                        // filter, clear the filter first so the jump lands somewhere
                        // visible (mirrors the search onSubmit top-match clear).
                        if isFiltering,
                            !snapshot.entries.contains(where: { entry in
                                entry.sessions.contains { $0.session.id == row.sessionID }
                            }),
                            !snapshot.pinned.contains(where: { $0.entry.session.id == row.sessionID })
                        {
                            clearFilters()
                        }
                        onFocusPane(row.sessionID, row.paneID)
                    },
                    onClose: { setActivityPanel(open: false) }
                )
            }

            SidebarStatusFooter(
                counts: snapshot.counts,
                total: snapshot.total,
                displayMode: displayMode,
                onOpenQuickSettings: onOpenQuickSettings,
                onSelectNextMatchingState: { focusNextAgentPane(matching: $0, in: snapshot.roster) },
                onToggleActivityPanel: { state in
                    // Chips only open/retarget; closing lives on the total
                    // label and the panel's own close button. Keeps the chips'
                    // "Show…" tooltips truthful — a same-state second click
                    // used to silently close the panel (review finding).
                    if activityPanelOpen, state == nil {
                        setActivityPanel(open: false)
                    } else {
                        setActivityPanel(open: true, scrollTarget: state)
                    }
                },
                activityPanelOpen: activityPanelOpen
            )
        }
        .background(Color.aw.surface.sidebar)
        .onHover { pointerInside in
            guard
                let publication = SidebarDragPointerPolicy.hoverPublication(
                    isDragActive: activeDragID != nil,
                    pointerInside: pointerInside
                )
            else { return }
            onSidebarHover(publication)
        }
        .accessibilityRotor(
            "Workspaces",
            entries: rotorEntries,
            entryID: \.id,
            entryLabel: \.label
        )
        .onMoveCommand { direction in
            switch direction {
            case .up:
                moveKeyboardFocus(offset: -1, visibleRows: visibleRows)
            case .down:
                moveKeyboardFocus(offset: 1, visibleRows: visibleRows)
            default:
                break
            }
        }
        .onKeyPress(.home) {
            focusKeyboardTarget(SidebarVisibleRows.firstTarget(in: visibleRows), viaKeyboardNavigation: true)
            return .handled
        }
        .onKeyPress(.end) {
            focusKeyboardTarget(SidebarVisibleRows.lastTarget(in: visibleRows), viaKeyboardNavigation: true)
            return .handled
        }
        .onDisappear {
            // The clear scheduler can hold a pending main-actor task for up
            // to `activeTimeout` after a drag starts. If the sidebar is torn
            // down inside that window (window closed, view replaced) nothing
            // else cancels it — disarm it here so it doesn't outlive the view.
            dragClearScheduler.cancel()
        }
        .onChange(of: isFiltering) { _, filtering in
            if filtering {
                clearSidebarDragState()
            }
        }
        .onChange(of: displayMode) { _, mode in
            searchText = SidebarSearchModePolicy.query(
                afterChangingTo: mode,
                currentQuery: searchText
            )
            // The panel is expanded-mode only; collapsing while it's open would
            // strand the open state + its announcement. Close it so both stay
            // coherent with what's on screen.
            if mode == .collapsed, activityPanelOpen {
                setActivityPanel(open: false)
            }
        }
        .onChange(of: sessionStore.selectedSessionID) { _, newValue in
            // Selection can land inside a collapsed group via more than
            // notification clicks (⌘+number, prev/next workspace) — expanding
            // here covers all of them from one place instead of each caller.
            guard let newValue,
                let group = sessionStore.groups.first(where: { group in
                    group.sessions.contains { $0.id == newValue }
                })
            else {
                return
            }
            // A pinned session renders in the Pinned section, not its origin
            // group; silently expanding that origin group would be a surprising
            // side effect (especially on the collapsed rail), so skip it.
            guard !sessionStore.isPinned(newValue) else {
                return
            }
            collapsedGroupIDs.remove(group.id)
        }
        .onChange(of: sessionStore.pinnedSessionIDs) { oldIDs, newIDs in
            // Single all-paths hook for pin/unpin side effects (sidebar menu,
            // ⌥⌘P, command palette all mutate this array). A pure reorder
            // leaves the ID set unchanged (added/removed both empty → no-op),
            // so it doesn't collide with `movePinnedSession`'s announcement.
            let added = Set(newIDs).subtracting(oldIDs)
            let removed = Set(oldIDs).subtracting(newIDs)
            // Skip wholesale replacement (state restore) — a real toggle is
            // exactly one net add or one net remove.
            guard added.count + removed.count == 1 else {
                return
            }
            if let addedID = added.first, let session = sessionStore.session(id: addedID) {
                reorderAnnouncer.announce("Pinned \(session.title)")
            }
            if let removedID = removed.first,
                let session = sessionStore.session(id: removedID),
                let group = sessionStore.groups.first(where: { group in
                    group.sessions.contains { $0.id == removedID }
                })
            {
                // Auto-expand the origin group so the returning tile isn't
                // hidden under a collapsed header. A pin pruned on close has
                // no live session → this lookup fails → no-op, as intended.
                collapsedGroupIDs.remove(group.id)
                reorderAnnouncer.announce("Unpinned \(session.title), returned to \(group.name)")
            }
        }
        .onChange(of: focusRequestID) { _, requestID in
            if requestID != nil {
                ShortcutDiagnostics.log("stage=sidebarView receivedFocusRequest=true")
                if displayMode == .collapsed {
                    ShortcutDiagnostics.log("stage=sidebarView action=focusRail")
                    if let target = defaultSidebarFocusTarget(in: visibleRows) {
                        isCollapsedEmptyActionFocused = false
                        focusKeyboardTarget(target)
                    } else {
                        focusedRowTarget = nil
                        isCollapsedEmptyActionFocused = true
                    }
                    return
                }

                guard !searchFieldAppearsFocused else {
                    ShortcutDiagnostics.log("stage=sidebarView action=focusSearch skipped=alreadyFocused")
                    return
                }

                // @FocusState won't re-fire if it already reads `true` (e.g. the
                // chord arrives while SwiftUI thinks the field is focused but the
                // AppKit field editor isn't first responder). Reset to false, then
                // re-assert true on the next runloop tick so SwiftUI re-applies
                // first responder even from the already-"focused" state.
                isSearchFocused = false
                DispatchQueue.main.async {
                    ShortcutDiagnostics.log("stage=sidebarView action=focusSearch")
                    isSearchFocused = true
                }
            }
        }
        .onChange(of: focusedRowTarget) { _, target in
            guard let sessionID = SidebarVisibleRows.sessionID(for: target) else {
                return
            }
            sessionStore.selectedSessionID = sessionID
        }
        .environment(\.isCommandKeyHeld, isCommandKeyHeld)
        .modifier(CollapsedCommandKeyTracking(isCollapsed: displayMode == .collapsed, isHeld: $isCommandKeyHeld))
    }

    private var searchFieldAppearsFocused: Bool {
        isSearchFocused && NSApp.keyWindow?.firstResponder is NSTextView
    }

    // The palette shortcut is user-rebindable; resolve the live binding so the
    // rail tooltip tracks Settings instead of advertising a stale ⌘K.
    private var paletteShortcutSymbol: String {
        KeyboardShortcutCatalog.commandPaletteDisplaySymbol(
            keyboard: appSettingsStore.keyboard.value
        )
    }

    @ViewBuilder
    private func searchHeader(topMatchID: TerminalSession.ID?) -> some View {
        if displayMode == .collapsed {
            collapsedSearchHeader
        } else {
            expandedSearchHeader(topMatchID: topMatchID)
        }
    }

    private var collapsedSearchHeader: some View {
        VStack(spacing: 6) {
            Button {
                onToggleCommandPalette()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    // Matches the 40pt collapsed workspace tile
                    // (SidebarSessionTile.swift) so the rail reads as one
                    // consistent column width, not a narrower control.
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aw.text3)
            // Same family as a workspace tile's fill (SidebarSessionTile.swift
            // tileBackground), dimmed a notch so search reads as a utility
            // control rather than "one more workspace" next to the actual
            // tiles below it.
            .background(Color.aw.surface.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: AwRadius.panel))
            .accessibilityLabel("Search")
            .accessibilityHint("Opens the command palette to search workspaces and actions.")
            .help("Search workspaces and actions (\(paletteShortcutSymbol))")

            NewWorkspaceMenuButton(
                size: 40,
                // Matches the search chip above and the workspace tiles below
                // (both AwRadius.panel) so the collapsed rail's three chip
                // types share one corner radius.
                cornerRadius: AwRadius.panel,
                // Blend into the sidebar, matching the expanded header's
                // treatment of this same button — not a separate boxed color.
                restFill: Color.aw.surface.sidebar,
                otherGroups: sessionStore.groups.map { ($0.id, $0.name) },
                onNewWorkspace: addWorkspaceInCurrentContext,
                onNewWorkspaceInGroup: addWorkspace(inGroupID:),
                onNewWorkspaceGroup: onNewWorkspaceGroup
            )
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func expandedSearchHeader(topMatchID: TerminalSession.ID?) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)

                TextField("Search sessions", text: $searchText)
                    .textFieldStyle(.plain)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .focused($isSearchFocused)
                    .accessibilityLabel("Sidebar search")
                    .accessibilityHint("Filters workspaces. Press Return to open the top match. Press Escape to clear.")
                    // ⏎ commits the highest-ranked filtered session and
                    // collapses the search query. Full ↑↓ navigation is
                    // deferred to INT-320.
                    .onSubmit {
                        if let topMatchID {
                            sessionStore.selectedSessionID = topMatchID
                            searchText = ""
                        }
                    }
                    // Esc clears the query without affecting the active
                    // selection. `.onKeyPress` on a TextField sees macOS field-
                    // editor keys before SwiftUI's default cancel routing in
                    // macOS 15, which is what we want here. If a future macOS
                    // changes this, fall back to a focused-command binding.
                    .onKeyPress(.escape) {
                        if !searchText.isEmpty {
                            searchText = ""
                            return .handled
                        }
                        return .ignored
                    }
                    // Freeze search input during an active sidebar drag.
                    // Typing here would flip `isFiltering`, whose onChange
                    // tears down all drop targets mid-drag — leaving the
                    // user's drag image chasing the cursor with nowhere to
                    // land. A reorder drag is brief and mouse-bound, so the
                    // field is never actively in use during one.
                    .disabled(activeDragID != nil)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.aw.textFaint)
                    .accessibilityLabel("Clear search")
                    .help("Clear Search")
                }
            }
            .frame(minHeight: AwSpacing.searchFieldHeight)
            .padding(.horizontal, 10)
            .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.aw.border2, lineWidth: 0.5)
            }

            NewWorkspaceMenuButton(
                size: 34,
                cornerRadius: 7,
                // Blend into the sidebar so it pairs cleanly with the search field.
                restFill: Color.aw.surface.sidebar,
                otherGroups: sessionStore.groups.map { ($0.id, $0.name) },
                onNewWorkspace: addWorkspaceInCurrentContext,
                onNewWorkspaceInGroup: addWorkspace(inGroupID:),
                onNewWorkspaceGroup: onNewWorkspaceGroup
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func addWorkspaceInCurrentContext() {
        // INT-330: the top-level "+" button targets the currently selected
        // workspace's group. Cold-start falls back to the configured default.
        if let selectedSession = sessionStore.selectedSession,
            let owner = sessionStore.groups.first(where: { group in
                group.sessions.contains(where: { $0.id == selectedSession.id })
            })
        {
            sessionStore.addSession(groupName: owner.name)
        } else {
            sessionStore.addSession(
                groupName: appSettingsStore.workspaces.value.defaultGroup
            )
        }
    }

    private func addWorkspace(inGroupID groupID: SessionGroup.ID) {
        guard let target = sessionStore.groups.first(where: { $0.id == groupID }) else {
            return
        }
        sessionStore.addSession(groupName: target.name)
    }

    private func moveKeyboardFocus(offset: Int, visibleRows: [SidebarVisibleRow]) {
        focusKeyboardTarget(
            SidebarVisibleRows.target(
                after: focusedRowTarget,
                in: visibleRows,
                offset: offset
            ),
            viaKeyboardNavigation: true
        )
    }

    private func focusKeyboardTarget(
        _ target: SidebarVisibleRowTarget?,
        viaKeyboardNavigation: Bool = false
    ) {
        // The focus ring un-hides only on *explicit* keyboard navigation (arrow
        // / Home / End). Programmatic default-focus — e.g. auto-focusing the
        // selected row when the sidebar gains focus — must NOT trip it, or the
        // ring sits permanently on the mouse-selected row (the original bug).
        // Mouse clicks move focus through SwiftUI's `.focused` binding and never
        // reach here, so they also leave the ring hidden.
        if viaKeyboardNavigation {
            isKeyboardNavigating = true
        }
        focusedRowTarget = target
    }

    private func defaultSidebarFocusTarget(
        in visibleRows: [SidebarVisibleRow]
    ) -> SidebarVisibleRowTarget? {
        if let selectedSessionID = sessionStore.selectedSessionID {
            let selectedTarget = SidebarVisibleRowTarget.session(selectedSessionID)
            if visibleRows.contains(where: { $0.target == selectedTarget }) {
                return selectedTarget
            }
        }

        return SidebarVisibleRows.firstTarget(in: visibleRows)
    }

    /// Collapsed-rail chip jump: cycle pane-grain through the agent rows matching
    /// the chip's state, landing on the pane after the currently-active one. Uses
    /// the same `onFocusPane` the panel rows do, so a counted pane is never
    /// unreachable (session-grain cycling could skip a pane hiding behind a
    /// higher-priority winner in the same session).
    private func focusNextAgentPane(matching state: AwState, in roster: AgentActivityRoster) {
        let rows = roster.groups.flatMap(\.rows).filter { $0.state.awState == state }
        guard !rows.isEmpty else {
            return
        }
        let activePaneID = sessionStore.selectedSession?.activePaneID
        let startIndex =
            activePaneID.flatMap { id in
                rows.firstIndex { $0.paneID == id }
            } ?? -1
        let next = rows[(startIndex + 1) % rows.count]
        onFocusPane(next.sessionID, next.paneID)
    }

    /// Single writer for the roster panel's open state so the a11y announcement
    /// can't be missed by one path (spec §5: expansion is announced).
    private func setActivityPanel(open: Bool, scrollTarget: AgentDisplayState? = nil) {
        activityPanelScrollTarget = scrollTarget
        guard open != activityPanelOpen else {
            return
        }
        activityPanelOpen = open
        TerminalAccessibilityAnnouncer.announce(
            open
                ? String(
                    localized: "Agent activity panel opened",
                    comment: "VoiceOver announcement when the sidebar agent activity panel expands.")
                : String(
                    localized: "Agent activity panel closed",
                    comment: "VoiceOver announcement when the sidebar agent activity panel collapses.")
        )
    }

    private func panelItem(for row: AgentActivityRoster.Row) -> AgentActivityPanelItem {
        let session = sessionStore.session(id: row.sessionID)
        // Resolve the ROW's pane, not the session's sidebarLocation — that
        // helper reads the ACTIVE pane, which in a split can be a different
        // pane's cwd/host than the row being rendered (review finding).
        let pane = session?.layout.pane(id: row.paneID)
        let location: SidebarSessionLocation? = pane.map { pane in
            if let host = pane.remotePresentationHost {
                return .remote(host: host)
            }
            return .local(pane.workingDirectory)
        }
        // Split sessions: name the row after ITS pane (the pane title bar the
        // user sees), via the same displayTitle helper the bar uses so the two
        // can't diverge. Lone panes have no pane bar — the workspace title
        // names them, so the row keeps the session title there.
        let title: String
        if let pane, session?.layout.hasMultiplePanes == true {
            title = PaneTitleBarView.displayTitle(for: pane)
        } else {
            title = session?.title ?? ""
        }
        return AgentActivityPanelItem(
            row: row,
            title: title,
            locationText: location?.displayText ?? ""
        )
    }

    /// Builds the body's snapshot in one place: filter-independent state counts
    /// for the footer overview, the fuzzy projection, and post-trim of empty
    /// groups while filtering. Empty groups remain visible when no filter is
    /// active so the empty-group drop target keeps working.
    ///
    /// The counts are a single O(total sessions) pass over the unfiltered tree.
    /// The footer reports the global picture, so it counts every session
    /// regardless of the current query.
    private func computedSnapshot(query: String, isFiltering: Bool) -> SidebarSnapshot {
        // Pane-grain agent roster replaces the old session-grain state walk: it
        // folds every agent pane once (the same traversal `chromeAwState` did),
        // and the footer now reports agents, not workspaces.
        let roster = AgentActivityRoster.build(
            sessions: sessionStore.groups.flatMap(\.sessions),
            at: Date()
        )
        // Chip counts stay in the design-system state space the footer renders.
        var counts: [AwState: Int] = [:]
        for (state, count) in roster.counts {
            counts[state.awState, default: 0] += count
        }

        let projection = SidebarSearchProjection.project(
            groups: sessionStore.groups,
            query: query,
            haystacks: { session in
                SidebarSearchHaystacks(
                    title: session.title,
                    location: session.sidebarLocation.searchText
                )
            }
        )

        // Float pinned sessions into the synthetic Pinned section and drop
        // them from their origin groups. The empty-group trim (visible only
        // while filtering) folds into the projection's input here.
        let pinnedProjection = SidebarPinnedProjection.apply(
            entries: isFiltering
                ? projection.entries.filter { !$0.sessions.isEmpty }
                : projection.entries,
            pinnedSessionIDs: sessionStore.pinnedSessionIDs,
            isFiltering: isFiltering,
            searchTopMatch: projection.topMatch
        )

        return SidebarSnapshot(
            entries: pinnedProjection.entries,
            pinned: pinnedProjection.pinned,
            total: roster.total,
            counts: counts,
            roster: roster,
            topMatchID: pinnedProjection.topMatch
        )
    }

    /// The synthetic Pinned section. Extracted from `body` as a `@ViewBuilder`
    /// func (the file's existing `searchHeader` pattern) so its callback closures
    /// don't push the already-large body expression past the type-checker's
    /// budget.
    @ViewBuilder
    private func pinnedSection(
        pinned: [PinnedSessionEntry],
        density: SidebarDensity,
        isFiltering: Bool,
        jumpIndexBySessionID: [TerminalSession.ID: Int],
        duplicateDisambiguationBySessionID: [TerminalSession.ID: SidebarDuplicateDisambiguation]
    ) -> some View {
        SidebarPinnedSectionView(
            pinned: pinned,
            density: density,
            displayMode: displayMode,
            isFiltering: isFiltering,
            selectedSessionID: sessionStore.selectedSessionID,
            allGroups: sessionStore.groups,
            jumpIndexBySessionID: jumpIndexBySessionID,
            workspacesWithBackgroundedFloatingWork: workspacesWithBackgroundedFloatingWork,
            duplicateDisambiguationBySessionID: duplicateDisambiguationBySessionID,
            onSelect: selectSession,
            onTogglePin: { session in
                sessionStore.togglePin(sessionID: session.id)
            },
            onClose: onCloseWorkspace,
            onClear: onClearWorkspace,
            onRename: onRenameWorkspace,
            onAcknowledge: { session in
                sessionStore.acknowledgeSession(id: session.id)
            },
            onToggleNotificationsMute: { session in
                sessionStore.setNotificationsMuted(
                    id: session.id,
                    muted: !session.notificationsMuted
                )
            },
            canMakeWorkspaceManaged: canMakeWorkspaceManaged,
            onMakeWorkspaceManaged: onMakeWorkspaceManaged,
            onNewSessionHere: newSessionInPinnedOrigin,
            onMoveToGroup: { sessionID, destinationGroupID in
                moveSession(sessionID, toGroupID: destinationGroupID, atIndex: SessionStore.appendIndex)
            },
            onMovePinned: movePinnedSession(fromIndex:toIndex:),
            onWorkspaceDragStarted: beginWorkspaceDrag,
            activeDragKind: activeDragKind,
            activeDragID: activeDragID,
            activeWorkspaceDragSourceID: activeWorkspaceDragSourceID,
            onDragRefreshed: refreshSidebarDrag,
            onDragEnded: clearSidebarDragState,
            onDragExited: scheduleSidebarDragStateClear,
            focusedRowTarget: $focusedRowTarget,
            isKeyboardNavigating: $isKeyboardNavigating
        )
    }

    /// "New Workspace Here" from a pinned tile lands the new workspace in the
    /// pinned session's origin group, matching the in-group tile's behavior.
    private func newSessionInPinnedOrigin(_ session: TerminalSession) {
        guard
            let origin = sessionStore.groups.first(where: { group in
                group.sessions.contains { $0.id == session.id }
            })
        else {
            return
        }
        sessionStore.addSession(
            workingDirectory: session.workingDirectory,
            groupName: origin.name
        )
    }

    /// Selects a workspace and hands keyboard focus to its active pane. Shared
    /// by the in-group tile path and the Pinned section so the INT-652
    /// first-responder handoff can't drift between them.
    private func selectSession(_ session: TerminalSession) {
        sessionStore.selectedSessionID = session.id
        // Hand keyboard focus to the workspace's active pane directly (same
        // move as the command palette's jump). The mount-time vacancy reclaim
        // alone can't do this promptly here: the clicked row holds AppKit focus
        // and SwiftUI only reconciles it away ~0.5s later, which reads as a dead
        // keyboard (INT-652). One runloop hop so the switch render has mounted
        // the surface into the window first.
        let paneID = session.activePaneID
        DispatchQueue.main.async {
            guard let surface = ghosttyRuntime.cachedSurfaceView(for: paneID),
                let window = surface.window
            else {
                return
            }
            window.makeFirstResponder(surface)
        }
    }

    private func toggleGroup(_ id: SessionGroup.ID) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    private func clearFilters() {
        searchText = ""
    }

    /// Workspace move funnel for both drag drops and keyboard a11y actions.
    /// Mutates the store, then announces the landing position for VoiceOver.
    private func moveSession(
        _ sessionID: TerminalSession.ID,
        toGroupID destinationGroupID: SessionGroup.ID,
        atIndex index: Int
    ) {
        sessionStore.moveSession(
            id: sessionID,
            toGroupID: destinationGroupID,
            atIndex: index
        )
        announceWorkspaceReorder(sessionID)
    }

    /// Index-based group move (keyboard "Move Group Up/Down" a11y actions).
    /// The drag path uses `moveGroup(id:preRemovalIndex:)` instead.
    private func moveGroup(fromIndex: Int, toIndex: Int) {
        // Capture the moving group's id before the mutation so the landing
        // position can be announced afterward.
        let movedGroupID =
            sessionStore.groups.indices.contains(fromIndex)
            ? sessionStore.groups[fromIndex].id
            : nil
        sessionStore.moveGroup(from: fromIndex, to: toIndex)
        if let movedGroupID {
            announceGroupReorder(movedGroupID)
        }
    }

    private func moveGroup(id groupID: SessionGroup.ID, preRemovalIndex: Int) {
        guard let sourceIndex = sessionStore.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        let clampedPreRemovalIndex = max(0, min(preRemovalIndex, sessionStore.groups.count))
        let targetIndex = SidebarInsertionResolver.postRemovalTargetIndex(
            sourceIndex: sourceIndex,
            preRemovalIndex: clampedPreRemovalIndex
        )
        guard targetIndex != sourceIndex else {
            return
        }
        sessionStore.moveGroup(from: sourceIndex, to: targetIndex)
        announceGroupReorder(groupID)
    }

    /// VoiceOver announcement for a workspace landing at its new position.
    /// Reads the post-move position from the store so cross-group moves
    /// name the destination group too.
    private func announceWorkspaceReorder(_ sessionID: TerminalSession.ID) {
        guard
            let groupIndex = sessionStore.groups.firstIndex(where: {
                $0.sessions.contains(where: { $0.id == sessionID })
            }),
            let sessionIndex = sessionStore.groups[groupIndex].sessions
                .firstIndex(where: { $0.id == sessionID })
        else {
            return
        }
        let group = sessionStore.groups[groupIndex]
        let session = group.sessions[sessionIndex]
        reorderAnnouncer.announce(
            "Moved \(session.title) to position \(sessionIndex + 1) of \(group.sessions.count) in \(group.name)"
        )
    }

    private func announceGroupReorder(_ groupID: SessionGroup.ID) {
        guard let index = sessionStore.groups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        let group = sessionStore.groups[index]
        reorderAnnouncer.announce(
            "Moved \(group.name) group to position \(index + 1) of \(sessionStore.groups.count)"
        )
    }

    /// Pinned-reorder funnel for both the drag drop and the tile's keyboard
    /// Move Up/Down actions (both route through `onMovePinned`). Mutates the
    /// store, then announces the landing position for VoiceOver — the pinned
    /// twin of `moveSession`, whose pinned path bypassed the announcer.
    private func movePinnedSession(fromIndex: Int, toIndex: Int) {
        let movedID =
            sessionStore.pinnedSessionIDs.indices.contains(fromIndex)
            ? sessionStore.pinnedSessionIDs[fromIndex]
            : nil
        sessionStore.movePinnedSession(fromIndex: fromIndex, toIndex: toIndex)
        guard let movedID,
            let landedIndex = sessionStore.pinnedSessionIDs.firstIndex(of: movedID),
            let session = sessionStore.session(id: movedID)
        else {
            return
        }
        reorderAnnouncer.announce(
            "Moved \(session.title) to position \(landedIndex + 1) of \(sessionStore.pinnedSessionIDs.count) in Pinned"
        )
    }

    private func setGroupDropIndex(_ index: Int?) {
        if index != nil, activeDragID == nil {
            groupDropIndex = nil
            return
        }

        guard groupDropIndex != index else {
            return
        }

        groupDropIndex = index
    }

    private func beginGroupDrag(_ groupID: SessionGroup.ID) -> UUID {
        beginSidebarDrag(.group, groupID: groupID, workspaceID: nil)
    }

    private func beginWorkspaceDrag(_ workspaceID: TerminalSession.ID) -> UUID {
        let sourceGroupID = sessionStore.groups.first { group in
            group.sessions.contains { $0.id == workspaceID }
        }?.id
        // Freeze the source's pinned-ness now; a mid-drag ⌥⌘P must not change
        // which drop delegates accept this drag.
        activeWorkspaceDragSourceWasPinned = sessionStore.isPinned(workspaceID)
        return beginSidebarDrag(.workspace, groupID: sourceGroupID, workspaceID: workspaceID)
    }

    private func beginSidebarDrag(
        _ kind: SidebarDragKind,
        groupID: SessionGroup.ID?,
        workspaceID: TerminalSession.ID?
    ) -> UUID {
        let dragID = UUID()
        activeDragID = dragID
        activeDragKind = kind
        activeGroupDragSourceID = kind == .group ? groupID : nil
        activeWorkspaceDragSourceID = workspaceID
        activeWorkspaceDragSourceGroupID = kind == .workspace ? groupID : nil
        onSidebarHover(true)
        lastDragWatchdogRefresh = Date()
        scheduleSidebarDragStateClear(delay: SidebarDragStateTiming.activeTimeout)
        return dragID
    }

    private func refreshSidebarDrag(_ kind: SidebarDragKind) {
        guard activeDragID != nil else {
            return
        }
        if activeDragKind != kind {
            activeDragKind = kind
        }
        let now = Date()
        let clearIsSoon =
            sidebarDragClearDeadline.map {
                $0.timeIntervalSince(now) <= SidebarDragStateTiming.watchdogRefreshInterval
            } ?? true
        guard
            clearIsSoon
                || now.timeIntervalSince(lastDragWatchdogRefresh) >= SidebarDragStateTiming.watchdogRefreshInterval
        else {
            return
        }
        lastDragWatchdogRefresh = now
        scheduleSidebarDragStateClear(delay: SidebarDragStateTiming.activeTimeout)
    }

    /// The single source of truth for "what cleared drag state looks like".
    /// Both the immediate clear and the scheduled clear funnel through this
    /// so a future field can't be added to one path and forgotten in the
    /// other (which would leave a half-cleared drag).
    private func resetActiveDragState() {
        let wasDragActive = activeDragID != nil
        activeDragID = nil
        activeDragKind = nil
        activeGroupDragSourceID = nil
        activeWorkspaceDragSourceID = nil
        activeWorkspaceDragSourceGroupID = nil
        activeWorkspaceDragSourceWasPinned = false
        lastDragWatchdogRefresh = .distantPast
        sidebarDragClearDeadline = nil
        groupDropIndex = nil
        guard
            let pointerInside = resampleSidebarPointer(),
            SidebarDragPointerPolicy.clearPublication(
                wasDragActive: wasDragActive,
                resampledPointerInside: pointerInside
            ) != nil
        else { return }
        onSidebarHover(pointerInside)
    }

    private func clearSidebarDragState() {
        dragClearScheduler.cancel()
        resetActiveDragState()
    }

    private func scheduleSidebarDragStateClear() {
        scheduleSidebarDragStateClear(delay: SidebarDragStateTiming.exitTimeout)
    }

    private func scheduleSidebarDragStateClear(delay: TimeInterval) {
        sidebarDragClearDeadline = Date().addingTimeInterval(delay)
        dragClearScheduler.schedule(after: delay) {
            resetActiveDragState()
        }
    }
}

private struct CollapsedEmptySidebarAction: View {
    let onNewWorkspace: () -> Void
    let focused: FocusState<Bool>.Binding

    var body: some View {
        Button(action: onNewWorkspace) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 40, height: 40)
                .foregroundStyle(Color.aw.textFaint)
                .background(
                    Color.aw.surface.elevated.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            Color.aw.border2.opacity(0.75),
                            style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
                        )
                }
        }
        .buttonStyle(.plain)
        .focused(focused)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("New workspace")
        .help("New Workspace")
    }
}

private enum SidebarDragStateTiming {
    // SwiftUI exposes no reliable drag-cancel callback for legacy .onDrag.
    // The active timeout exists ONLY to recover state if a drag is lost
    // (cancelled with no exit callback). It is refreshed on `dropUpdated`,
    // which fires on cursor motion — so a legitimate drag held stationary
    // over a target does NOT refresh it. Keep the window long enough that a
    // motionless-but-live drag can't outlast it; a stationary cursor is not
    // evidence of a lost drag, so erring large here is harmless.
    static let activeTimeout: TimeInterval = 120
    static let exitTimeout: TimeInterval = 0.18
    static let watchdogRefreshInterval: TimeInterval = 0.75
}

@MainActor
private final class SidebarDragClearScheduler {
    private var pendingTask: Task<Void, Never>?

    /// Schedules `action` to run on the main actor after `delay`, cancelling
    /// any prior pending clear. A `Task { @MainActor }` carries the isolation
    /// by construction — the action mutates SwiftUI `@State`, so proving it
    /// runs on the main actor (rather than relying on `DispatchQueue.main`
    /// being the same actor by convention) matters under Swift 6 strict
    /// concurrency. `Task.isCancelled` replaces the hand-rolled UUID nonce.
    func schedule(after delay: TimeInterval, action: @MainActor @escaping () -> Void) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

/// Posts a VoiceOver announcement when a workspace or group is reordered, so
/// a VoiceOver user who triggers a keyboard reorder hears the result land
/// instead of firing the action into silence. Debounced so a burst of moves
/// announces only the latest position. A no-op when VoiceOver isn't running
/// (no assistive client receives `.announcementRequested`).
@MainActor
private final class SidebarReorderAnnouncer {
    private var pendingTask: Task<Void, Never>?

    func announce(_ message: String) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else {
                return
            }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }
}
