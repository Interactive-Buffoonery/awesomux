# Collapsed Sidebar Group Roster Peek Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hovering a collapsed sidebar group's header shows a floating card listing every workspace in that group, each row clickable to jump straight to it — replacing the abandoned native-tooltip approach from 2026-07-12.

**Architecture:** Extend the existing `SidebarPeekModel`/`SidebarPeekCardOverlay` system (currently single-session-only) with a second, additive set of "group" state and methods that mirror the session ones exactly — same hide-grace/pointer-over-card mechanics, no shared-method signature changes, so every existing call site and test for the session peek is untouched. A new `SidebarGroupPeekCard` view reuses `SidebarSessionPeekCard`'s chrome. The collapsed group header (`SidebarGroupHeaderRow`) gets its own 180ms hover debounce, mirroring `SidebarSessionTile`'s existing pattern.

**Tech Stack:** Swift 6.3.3, SwiftUI, swift-testing (`@Suite`/`@Test`/`#expect`).

## Global Constraints

- Collapsed sidebar only — the expanded sidebar already shows group name and every workspace inline; this feature must not trigger, render, or otherwise change anything there.
- `SessionGroup.id` and `TerminalSession.id` are both plain `UUID` — `SidebarPeekModel`'s new group methods MUST use distinct names from the existing session methods (Swift cannot overload on identical parameter types), per the spec's decision to keep both APIs additive rather than unify them under one generic owner type.
- Row membership/order for the roster must come from whatever the collapsed rail is *already rendering* for that group (`SidebarGroupHeaderRow.entries`, a `[SidebarSessionEntry]` already excluding pinned-out sessions) — never re-derive from raw `SessionGroup.sessions`, which still includes them.
- Reuse `SidebarSessionPeekCard`'s exact chrome (padding, corner radius, border, shadow, left-edge tint stripe) for `SidebarGroupPeekCard` — only the background differs (tint wash vs. plain `surface.elevated`).
- Click-to-jump reuses `SidebarView.selectSession(_:)` (via the existing `wirePeekSelection`-style routing through `ContentView`) — no new selection logic.
- Out of scope: drag-and-drop between groups while collapsed (filed separately), any change to the expanded sidebar, any change to the existing single-session/multi-pane peek card's own behavior or styling.

---

## Task 1: `SessionPeekItem` — the group roster's row data model

**Files:**
- Create: `Sources/awesoMux/Views/SessionPeekItem.swift`
- Test: `Tests/awesoMuxTests/SessionPeekItemTests.swift`

**Interfaces:**
- Consumes: `TerminalSession` (`AwesoMuxCore`), `TerminalSession.agentRollup()`, `session.sidebarLocation` (`TerminalSession+Display.swift`), `AwAgentIcon`/`AwState` (`DesignSystem`).
- Produces: `struct SessionPeekItem: Identifiable, Equatable` with fields `id: TerminalSession.ID`, `title: String`, `agent: AwAgentIcon`, `state: AwState`, `unread: Int`, `isActive: Bool`, `isRemote: Bool`; static `SessionPeekItem.items(for sessions: [TerminalSession], activeSessionID: TerminalSession.ID?) -> [SessionPeekItem]`. Task 2 and Task 3 depend on this exact signature.

This mirrors `PanePeekItem.swift` one level up (session instead of pane).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/awesoMuxTests/SessionPeekItemTests.swift
import AwesoMuxCore
import DesignSystem
import Testing
@testable import awesoMux

@Suite("Session peek item (group roster rows)")
struct SessionPeekItemTests {
    @Test("items(for:activeSessionID:) preserves order and marks the active session")
    func itemsPreserveOrderAndActiveFlag() {
        let alpha = TerminalSession(
            title: "Alpha",
            workingDirectory: "/tmp/alpha",
            agentKind: .shell,
            agentState: .idle
        )
        let beta = TerminalSession(
            title: "Beta",
            workingDirectory: "/tmp/beta",
            agentKind: .claude,
            agentState: .needs
        )

        let items = SessionPeekItem.items(for: [alpha, beta], activeSessionID: beta.id)

        #expect(items.map(\.id) == [alpha.id, beta.id])
        #expect(items.map(\.title) == ["Alpha", "Beta"])
        #expect(items[0].isActive == false)
        #expect(items[1].isActive == true)
    }

    @Test("remote session is flagged isRemote")
    func remoteSessionFlagged() {
        let pane = TerminalPane(
            title: "remote",
            workingDirectory: "/tmp",
            executionPlan: .ssh(SSHExecution(target: RemoteTarget(host: "box.example.com")))
        )
        let session = TerminalSession(
            title: "Remote",
            workingDirectory: "/tmp",
            layout: .pane(pane),
            activePaneID: pane.id
        )

        let items = SessionPeekItem.items(for: [session], activeSessionID: nil)

        #expect(items[0].isRemote == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionPeekItemTests`
Expected: FAIL — `SessionPeekItem` does not exist yet (build error, not a test assertion failure).

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/awesoMux/Views/SessionPeekItem.swift
import AwesoMuxCore
import DesignSystem

/// One row in the collapsed sidebar's group-roster peek card. A flat,
/// pre-computed value so the card never re-walks agent rollups in `body` —
/// same shape as `PanePeekItem`, one level up (session instead of pane).
struct SessionPeekItem: Identifiable, Equatable {
    let id: TerminalSession.ID
    let title: String
    let agent: AwAgentIcon
    let state: AwState
    let unread: Int
    let isActive: Bool
    let isRemote: Bool
}

extension SessionPeekItem {
    /// Builds the row list in the caller's given order — callers pass the
    /// already-filtered, already-ordered list the collapsed rail is
    /// currently rendering for a group (see `SidebarGroupHeaderRow.entries`),
    /// never raw `SessionGroup.sessions` (which still includes sessions
    /// floated out to the synthetic Pinned section).
    static func items(
        for sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?
    ) -> [SessionPeekItem] {
        sessions.map { session in
            let rollup = session.agentRollup()
            return SessionPeekItem(
                id: session.id,
                title: session.title,
                agent: rollup.winningAgentKind.awAgentIcon,
                state: rollup.state.awState,
                unread: rollup.unreadTotal,
                isActive: session.id == activeSessionID,
                isRemote: session.sidebarLocation.kind == .remote
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionPeekItemTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/awesoMux/Views/SessionPeekItem.swift Tests/awesoMuxTests/SessionPeekItemTests.swift
git commit -m "feat(sidebar): add SessionPeekItem for the group roster peek card"
```

---

## Task 2: Extend `SidebarPeekModel` with group-roster state

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarSplitSupport.swift`
- Test: `Tests/awesoMuxTests/SidebarPeekModelTests.swift` (add cases; do not change existing ones)

**Interfaces:**
- Consumes: `SessionGroup` (`AwesoMuxCore`), `SessionPeekItem` (Task 1), existing `ProjectTint`.
- Produces on `SidebarPeekModel`:
  - `private(set) var group: SessionGroup?`
  - `private(set) var groupSessionItems: [SessionPeekItem]`
  - `@ObservationIgnored var onSelectGroupSession: ((TerminalSession.ID) -> Void)?`
  - `func showGroup(group: SessionGroup, tint: ProjectTint, sessions: [TerminalSession], activeSessionID: TerminalSession.ID?, frame: CGRect)`
  - `func updateGroupFrame(for id: SessionGroup.ID, frame: CGRect)`
  - `func refreshGroup(group: SessionGroup, tint: ProjectTint, sessions: [TerminalSession], activeSessionID: TerminalSession.ID?)`
  - `func hideGroup(for id: SessionGroup.ID)`
  - `func setPointerOverGroupCard(_ over: Bool, for id: SessionGroup.ID)`
  - `func requestHideGroup(for id: SessionGroup.ID)`

  Task 3/4/5 depend on these exact names and signatures. The existing `session`/`location`/`tint`/`paneItems` fields and `show`/`updateFrame`/`refresh`/`hide`/`setPointerOverCard`/`requestHide` methods are UNCHANGED except that `show(...)` and `showGroup(...)` each clear the other's state, so only one card is ever showing.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/awesoMuxTests/SidebarPeekModelTests.swift`, inside the existing `SidebarPeekModelTests` struct (after the existing tests, before the closing brace and the `waitUntil` helper):

```swift
    private func twoSessionGroup(_ name: String) -> (SessionGroup, TerminalSession, TerminalSession) {
        let a = TerminalSession(title: "A", workingDirectory: "~", agentKind: .shell, agentState: .idle)
        let b = TerminalSession(title: "B", workingDirectory: "~", agentKind: .shell, agentState: .idle)
        let group = SessionGroup(name: name, sessions: [a, b])
        return (group, a, b)
    }

    @Test("showGroup clears any active session peek, and vice versa")
    func showGroupAndShowSessionAreMutuallyExclusive() async {
        let model = SidebarPeekModel()
        let session = twoPaneSession("A")
        let (group, ga, gb) = twoSessionGroup("Code")

        model.show(session: session, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == session.id)
        #expect(model.group == nil)

        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: ga.id, frame: .zero)
        #expect(model.group?.id == group.id)
        #expect(model.groupSessionItems.map(\.id) == [ga.id, gb.id])
        #expect(model.session == nil) // showing the group cleared the session peek

        model.show(session: session, location: location, tint: tint, frame: .zero)
        #expect(model.session?.id == session.id)
        #expect(model.group == nil) // showing the session cleared the group peek
    }

    @Test("requestHideGroup hides after the grace when the pointer never reaches the card")
    func requestHideGroupHidesAfterGrace() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        gate.release()
        #expect(await waitUntil { model.group == nil })
        #expect(model.group == nil)
    }

    @Test("pointer reaching the group card cancels the pending hide")
    func pointerOverGroupCardCancelsHide() async {
        let gate = ManualDelayGate()
        let model = SidebarPeekModel(sleep: { _ in await gate.wait() })
        let (group, ga, gb) = twoSessionGroup("Code")
        model.showGroup(group: group, tint: tint, sessions: [ga, gb], activeSessionID: nil, frame: .zero)
        model.requestHideGroup(for: group.id)
        #expect(await waitUntil { gate.waiterCount == 1 })
        model.setPointerOverGroupCard(true, for: group.id)
        gate.release()
        await drainMainQueue()
        #expect(model.group?.id == group.id)
    }

    @Test("refreshGroup updates content only while this group owns the peek")
    func refreshGroupGuardsOwnership() async {
        let model = SidebarPeekModel()
        let (groupA, aOne, aTwo) = twoSessionGroup("A")
        let (groupB, _, _) = twoSessionGroup("B")
        model.showGroup(group: groupA, tint: tint, sessions: [aOne, aTwo], activeSessionID: nil, frame: .zero)

        // A different, non-owning group's refresh must no-op.
        model.refreshGroup(group: groupB, tint: tint, sessions: [], activeSessionID: nil)
        #expect(model.group?.id == groupA.id)

        // The owning group's refresh updates content in place.
        model.refreshGroup(group: groupA, tint: tint, sessions: [aOne], activeSessionID: aOne.id)
        #expect(model.groupSessionItems.map(\.id) == [aOne.id])
        #expect(model.groupSessionItems[0].isActive == true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SidebarPeekModelTests`
Expected: FAIL — `showGroup`, `group`, `groupSessionItems`, `requestHideGroup`, `setPointerOverGroupCard`, `refreshGroup` don't exist yet (build error).

- [ ] **Step 3: Implement the model additions**

In `Sources/awesoMux/Views/SidebarSplitSupport.swift`, inside `final class SidebarPeekModel`:

Add stored properties, right after the existing `paneItems` declaration:

```swift
    /// Group-roster peek state — mutually exclusive with `session` above.
    /// `showGroup` clears `session`/`location`/`paneItems`; `show` clears
    /// these. Only one card (session or group) is ever displayed.
    private(set) var group: SessionGroup?
    private(set) var groupSessionItems: [SessionPeekItem] = []
```

Add the callback property, right after `onSelectPane`:

```swift
    /// Routes a group-roster row click up to `ContentView` (select
    /// workspace + focus its active pane). Set once when the overlay is
    /// installed, same shape as `onSelectPane`.
    @ObservationIgnored var onSelectGroupSession: ((TerminalSession.ID) -> Void)?
```

Modify the existing `show(...)` to clear group state — add these two lines right after `isPointerOverCard = false`:

```swift
        isPointerOverCard = false
        group = nil
        groupSessionItems = []
        self.session = session
```

Add the new methods after the existing `requestHide(for:)` method, before the closing brace of `SidebarPeekModel`:

```swift
    func showGroup(
        group: SessionGroup,
        tint: ProjectTint,
        sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?,
        frame: CGRect
    ) {
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        session = nil
        location = nil
        paneItems = []
        self.group = group
        self.tint = tint
        groupSessionItems = SessionPeekItem.items(for: sessions, activeSessionID: activeSessionID)
        anchorY = frame.minY
        tileHeight = frame.height
        anchorX = frame.maxX
    }

    /// Keep the card tracking its header as the rail scrolls or resizes.
    /// No-op unless the given group currently owns the peek.
    func updateGroupFrame(for id: SessionGroup.ID, frame: CGRect) {
        guard group?.id == id else { return }
        anchorY = frame.minY
        tileHeight = frame.height
        anchorX = frame.maxX
    }

    /// Refresh the displayed content if this group owns the peek — same
    /// staleness problem `refresh(session:...)` solves one level down.
    func refreshGroup(
        group: SessionGroup,
        tint: ProjectTint,
        sessions: [TerminalSession],
        activeSessionID: TerminalSession.ID?
    ) {
        guard self.group?.id == group.id else { return }
        self.group = group
        self.tint = tint
        groupSessionItems = SessionPeekItem.items(for: sessions, activeSessionID: activeSessionID)
    }

    /// Clear only if this group owns the peek — guards the hover hand-off,
    /// same as `hide(for:)`.
    func hideGroup(for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        hideGraceTask?.cancel()
        hideGraceTask = nil
        isPointerOverCard = false
        group = nil
        tint = nil
        groupSessionItems = []
    }

    /// Pointer entered/left the hittable group-roster card — same grace
    /// cancel/request shape as `setPointerOverCard(_:for:)`.
    func setPointerOverGroupCard(_ over: Bool, for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        isPointerOverCard = over
        if over {
            hideGraceTask?.cancel()
            hideGraceTask = nil
        } else {
            requestHideGroup(for: id)
        }
    }

    /// Hide after the same short grace `requestHide(for:)` uses, covering
    /// the header→card pointer gap.
    func requestHideGroup(for id: SessionGroup.ID) {
        guard group?.id == id else { return }
        hideGraceTask?.cancel()
        hideGraceTask = Task { @MainActor [weak self, sleep] in
            await sleep(.milliseconds(220))
            guard !Task.isCancelled, let self, !self.isPointerOverCard else { return }
            self.hideGroup(for: id)
        }
    }
```

Also modify `showGroup`'s counterpart: the existing `hide(for:)`, `setPointerOverCard(_:for:)`, and `requestHide(for:)` do NOT need changes — they already guard on `session?.id == id`, which is `nil` while a group is showing, so they safely no-op.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SidebarPeekModelTests`
Expected: PASS (all previous tests + 4 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/awesoMux/Views/SidebarSplitSupport.swift Tests/awesoMuxTests/SidebarPeekModelTests.swift
git commit -m "feat(sidebar): add group-roster peek state to SidebarPeekModel"
```

---

## Task 3: `SidebarGroupPeekCard` view + shared peek-card metrics

**Files:**
- Create: `Sources/awesoMux/Views/SidebarGroupPeekCard.swift`
- Modify: `Sources/awesoMux/Views/ContentView.swift` (extend `SidebarPeekMetrics` with two constants currently private to `SidebarSessionPeekCard`)
- Modify: `Sources/awesoMux/Views/SidebarSessionPeekCard.swift` (point its existing scroll-threshold logic at the now-shared constants instead of its own private ones — no behavior change)

**Interfaces:**
- Consumes: `SessionPeekItem` (Task 1), `SessionGroup`, `ProjectTint`, `SidebarPeekMetrics.cardWidth` (existing), new `SidebarPeekMetrics.maxVisibleRows`/`.rowHeight`.
- Produces: `struct SidebarGroupPeekCard: View` with `init(group: SessionGroup, tint: ProjectTint, items: [SessionPeekItem], onSelectSession: @escaping (TerminalSession.ID) -> Void, onHoverChanged: @escaping (Bool) -> Void)`. Task 4 depends on this exact initializer.

**Step 1: Hoist the shared scroll-threshold constants (no behavior change)**

- [ ] In `Sources/awesoMux/Views/ContentView.swift`, extend `SidebarPeekMetrics`:

```swift
enum SidebarPeekMetrics {
    /// Horizontal gap between the hovered row's right edge and the card's
    /// leading edge.
    static let cardGap: CGFloat = AwSpacing.overlayGap
    static let cardWidth: CGFloat = 240
    /// Beyond this many rows a peek card's list scrolls instead of growing
    /// the card past the window — shared by the multi-pane card and the
    /// group-roster card so both cap at the same visual height.
    static let maxVisibleRows = 5
    static let rowHeight: CGFloat = 30
}
```

- [ ] In `Sources/awesoMux/Views/SidebarSessionPeekCard.swift`, remove the now-duplicate constants and point at the shared ones:

Remove:
```swift
    private static let maxVisibleRows = 5
    private static let rowHeight: CGFloat = 30
```

Replace the two use sites:
```swift
        if paneItems.count > Self.maxVisibleRows {
```
→
```swift
        if paneItems.count > SidebarPeekMetrics.maxVisibleRows {
```

and:
```swift
                .frame(maxHeight: CGFloat(Self.maxVisibleRows) * Self.rowHeight)
```
→
```swift
                .frame(maxHeight: CGFloat(SidebarPeekMetrics.maxVisibleRows) * SidebarPeekMetrics.rowHeight)
```

- [ ] Run: `swift build`
Expected: builds clean (pure rename, no behavior change — no test needed for this step, it's a non-observable refactor covered by every existing `SidebarSessionPeekCard`-adjacent test still passing).

**Step 2: Write the new card**

- [ ] Create `Sources/awesoMux/Views/SidebarGroupPeekCard.swift`:

```swift
import AwesoMuxCore
import DesignSystem
import SwiftUI

/// The collapsed-rail group-header hover peek card: lists every workspace
/// in the group, each row clickable to jump straight to it. Shares its
/// chrome (padding, corner radius, border, shadow, left tint stripe) with
/// `SidebarSessionPeekCard` so the two card types read as one visual
/// system — only the background differs, washed with the group's own tint
/// so it's legible at a glance which peek type is showing.
struct SidebarGroupPeekCard: View {
    let group: SessionGroup
    let tint: ProjectTint
    let items: [SessionPeekItem]
    let onSelectSession: (TerminalSession.ID) -> Void
    /// Pointer entered/left the card — same hover-handoff grace purpose as
    /// `SidebarSessionPeekCard.onHoverChanged`.
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
                .overlay(tint.borderHue.opacity(0.4))
                .allowsHitTesting(false)
            rowList
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.aw.surface.elevated)
                .overlay {
                    // Tint wash: reads as "this card is about a group" at a
                    // glance without fighting the row content's own colors.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.hue.opacity(0.10))
                }
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(tint.hue)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.borderHue.opacity(0.85), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(0.20), radius: 16, y: 8)
                .allowsHitTesting(false)
        }
        .onHover { onHoverChanged($0) }
        // Transient floating overlay; VoiceOver reaches the same jump
        // targets via the group header's own accessibility actions
        // (Task 5), so the card stays out of the a11y tree — same
        // reasoning as SidebarSessionPeekCard.
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.hue)
                .frame(width: 8, height: 8)

            Text(group.name)
                .awFont(AwFont.UI.label)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text("\(items.count)")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text2)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var rowList: some View {
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Button {
                    onSelectSession(item.id)
                } label: {
                    SessionPeekRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }

        if items.count > SidebarPeekMetrics.maxVisibleRows {
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                }
                .frame(maxHeight: CGFloat(SidebarPeekMetrics.maxVisibleRows) * SidebarPeekMetrics.rowHeight)
                .onAppear { scrollToActive(proxy) }
                .onChange(of: items.first(where: \.isActive)?.id) { _, _ in
                    scrollToActive(proxy)
                }
            }
        } else {
            rows
        }
    }

    private func scrollToActive(_ proxy: ScrollViewProxy) {
        guard let activeID = items.first(where: \.isActive)?.id else { return }
        proxy.scrollTo(activeID, anchor: .center)
    }
}

private struct SessionPeekRow: View {
    let item: SessionPeekItem

    var body: some View {
        HStack(spacing: 8) {
            AgentTile(agent: item.agent, state: item.state, size: 20)

            Text(item.title)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)

            if item.isRemote {
                Image(systemName: "network")
                    .awFont(AwFont.Mono.meta)
                    .foregroundStyle(Color.aw.text2)
            }

            Spacer(minLength: 6)

            if item.unread > 0 {
                AwPill(
                    "\(item.unread)",
                    state: .needs,
                    baseSurface: pillBaseSurface
                )
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            item.isActive
                ? Color.aw.surface.hover
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }

    private var pillBaseSurface: Color {
        guard item.isActive else { return Color.aw.surface.elevated }
        return Color.aw.composited(
            Color.aw.surface.hover,
            over: Color.aw.surface.elevated
        )
    }
}
```

No automated test for this step — `SidebarSessionPeekCard` (the pattern this mirrors) has none either; this codebase tests the data/reducer layer (Task 1, Task 2) and leaves pure-rendering SwiftUI views to manual/visual verification (Task 6).

- [ ] Run: `swift build`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/awesoMux/Views/SidebarGroupPeekCard.swift Sources/awesoMux/Views/ContentView.swift Sources/awesoMux/Views/SidebarSessionPeekCard.swift
git commit -m "feat(sidebar): add SidebarGroupPeekCard, share peek-card row metrics"
```

---

## Task 4: Wire the shared overlay to render either card type

**Files:**
- Modify: `Sources/awesoMux/Views/ContentView.swift`

**Interfaces:**
- Consumes: `SidebarPeekModel.group`/`.groupSessionItems` (Task 2), `SidebarGroupPeekCard` (Task 3).
- Produces: `SidebarPeekCardOverlay` renders `SidebarGroupPeekCard` when `model.group != nil`, `SidebarSessionPeekCard` when `model.session != nil` (unchanged path), nothing when neither. `wirePeekSelection()` also wires `model.onSelectGroupSession`.

- [ ] **Step 1: Extend `wirePeekSelection` to route group-roster clicks**

In `Sources/awesoMux/Views/ContentView.swift`, immediately after the existing `peekModel.onSelectPane = { ... }` assignment inside `wirePeekSelection()`, add:

```swift
        peekModel.onSelectGroupSession = { [weak peekModel] sessionID in
            guard let live = sessionStore.session(id: sessionID) else {
                peekModel?.hideGroup(for: sessionID)
                return
            }
            sessionStore.selectedSessionID = sessionID
            sessionStore.acknowledgeSession(id: sessionID)
            if let groupID = peekModel?.group?.id {
                peekModel?.hideGroup(for: groupID)
            }
        }
```

(This mirrors `onSelectPane`'s shape: re-resolve the live session, guard against it having disappeared while the card was open, select + acknowledge, then hide. There is no per-pane focus step here — jumping to a *different workspace* is the whole action, unlike jumping to a pane *within* the same workspace.)

- [ ] **Step 2: Update `SidebarPeekCardOverlay.body` to branch on content kind**

Replace the `if let session = model.session, ... { SidebarSessionPeekCard(...) ... }` block's condition and body in `SidebarPeekCardOverlay` (the `private struct` near the bottom of `ContentView.swift`) with a branch that also handles the group case. The existing session branch and its `.frame`/`.position`/`.transition` modifiers are UNCHANGED; only the outer `if` becomes an `if/else if`, and a new `else if` branch is added:

```swift
    var body: some View {
        GeometryReader { proxy in
            if let session = model.session,
               let location = model.location,
               let tint = model.tint {
                let overlayOrigin = proxy.frame(in: .global).origin
                let interactive = session.layout.paneCount > 1
                SidebarSessionPeekCard(
                    session: session,
                    location: location,
                    tint: tint,
                    paneItems: model.paneItems,
                    onSelectPane: { paneID in model.onSelectPane?(session.id, paneID) },
                    onHoverChanged: { over in model.setPointerOverCard(over, for: session.id) }
                )
                    .frame(width: SidebarPeekMetrics.cardWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .position(
                        x: model.anchorX - overlayOrigin.x + SidebarPeekMetrics.cardGap + SidebarPeekMetrics.cardWidth / 2,
                        y: clampedCenterY(containerHeight: proxy.size.height, overlayOriginY: overlayOrigin.y)
                    )
                    .allowsHitTesting(interactive)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .leading))
                    )
            } else if let group = model.group,
                      let tint = model.tint {
                let overlayOrigin = proxy.frame(in: .global).origin
                SidebarGroupPeekCard(
                    group: group,
                    tint: tint,
                    items: model.groupSessionItems,
                    onSelectSession: { sessionID in model.onSelectGroupSession?(sessionID) },
                    onHoverChanged: { over in model.setPointerOverGroupCard(over, for: group.id) }
                )
                    // Always hittable — every row jumps, unlike the
                    // session card's single-pane summary variant.
                    .frame(width: SidebarPeekMetrics.cardWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .position(
                        x: model.anchorX - overlayOrigin.x + SidebarPeekMetrics.cardGap + SidebarPeekMetrics.cardWidth / 2,
                        y: clampedCenterY(containerHeight: proxy.size.height, overlayOriginY: overlayOrigin.y)
                    )
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .leading))
                    )
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.session?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.group?.id)
    }
```

Note the second `.animation(...)` line added after the existing one — the existing one only keys off `model.session?.id`, so without this addition a group-peek appear/disappear would not animate.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/awesoMux/Views/ContentView.swift
git commit -m "feat(sidebar): render the group roster peek card from the shared overlay"
```

---

## Task 5: Wire the collapsed group header — trigger, hit-area, accessibility

**Files:**
- Modify: `Sources/awesoMux/Views/SidebarGroupHeaderView.swift`

**Interfaces:**
- Consumes: `SidebarPeekModel` (Task 2, via `@Environment`), `entries: [SidebarSessionEntry]` (existing property), `selectedSessionID: TerminalSession.ID?` (existing property).
- Produces: nothing new consumed by later tasks — this is the last wiring point.

- [ ] **Step 1: Add the peek-trigger state and environment read**

In `Sources/awesoMux/Views/SidebarGroupHeaderView.swift`, inside `struct SidebarGroupHeaderRow`, add alongside the existing `@State private var isHeaderHovered = false`:

```swift
    @State private var isHeaderHovered = false
    @State private var isPeekVisible = false
    @State private var peekTask: Task<Void, Never>?
    /// This header's box in the sidebar pane's `.global` space — handed to
    /// `SidebarPeekModel` so `ContentView` can draw the peek card aligned
    /// with the header, above the split. Mirrors `SidebarSessionTile.tileFrame`.
    @State private var headerFrame: CGRect = .zero
    @Environment(SidebarPeekModel.self) private var peekModel
```

- [ ] **Step 2: Gate the trigger to collapsed mode, mirror the tile's debounce**

Add these private helpers to `SidebarGroupHeaderRow` (near the existing `sessions` computed property):

```swift
    /// Only the collapsed rail's header shows the group roster — the
    /// expanded header already lists every workspace inline, and hovering
    /// an individual tile keeps showing the existing single-session peek
    /// (mutually exclusive by construction: this trigger and the tile's
    /// trigger call different `SidebarPeekModel` methods).
    private var canPeek: Bool {
        displayMode == .collapsed
    }

    private func updatePeekVisibility() {
        guard canPeek, isHeaderHovered else {
            cancelPeek()
            return
        }
        guard !isPeekVisible else { return }

        peekTask?.cancel()
        peekTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            isPeekVisible = true
        }
    }

    private func cancelPeek() {
        peekTask?.cancel()
        peekTask = nil
        guard isPeekVisible else { return }
        isPeekVisible = false
    }
```

(This mirrors `SidebarSessionTile.updatePeekVisibility`/`cancelPeek` exactly, minus the reduce-motion animation branch — the header's own appear/disappear animation already lives in `SidebarPeekCardOverlay`, same as the tile's.)

- [ ] **Step 3: Wire show/hide into the model, and track frame + content refresh**

In `SidebarGroupHeaderRow.body`, find the existing `.onHover { hovering in isHeaderHovered = hovering; ... }` block and add a peek-visibility call:

```swift
        .onHover { hovering in
            isHeaderHovered = hovering
            if hovering {
                isKeyboardNavigating = false
            }
            updatePeekVisibility()
        }
```

Immediately after the existing `.onDisappear { isHeaderHovered = false }`, change it to also tear down the peek:

```swift
        .onDisappear {
            isHeaderHovered = false
            cancelPeek()
            peekModel.hideGroup(for: group.id)
        }
```

Add a frame-measuring background right after the existing `.overlay(alignment: .trailing) { groupCloseButton }` (before the `.onHover` block), matching `SidebarSessionTile`'s exact pattern — plain `.global`, gated on `canPeek` so expanded mode skips the measurement entirely:

```swift
        .background {
            if canPeek {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { headerFrame = $0 }
            }
        }
```

Add new `.onChange` modifiers right after the existing `.onChange(of: isFiltering) { _, _ in isHeaderHovered = false }` block:

```swift
        .onChange(of: isPeekVisible) { _, visible in
            if visible {
                peekModel.showGroup(
                    group: group,
                    tint: tint,
                    sessions: sessions,
                    activeSessionID: selectedSessionID,
                    frame: headerFrame
                )
            } else {
                // Always hittable (every row jumps), so always request the
                // graced hide — never the immediate one — matching the
                // multi-pane tile's card, not the single-pane summary path.
                peekModel.requestHideGroup(for: group.id)
            }
        }
        .onChange(of: headerFrame) { _, frame in
            peekModel.updateGroupFrame(for: group.id, frame: frame)
        }
        .onChange(of: entries) { _, _ in
            peekModel.refreshGroup(
                group: group,
                tint: tint,
                sessions: sessions,
                activeSessionID: selectedSessionID
            )
        }
        .onChange(of: displayMode) { _, _ in
            // Re-evaluate on a ⌘\ toggle even when the pointer never moves
            // — expanding the rail must dismiss a showing group peek
            // (`canPeek` gates it off), matching the tile's own
            // displayMode re-check.
            updatePeekVisibility()
        }
```

- [ ] **Step 4: Raise the collapsed header's hit area**

In the same file, find `groupHeader(isHighContrast:groupTintMarkerSize:)`'s collapsed branch:

```swift
            .frame(width: 40)
            .frame(minHeight: 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .help(group.name)
```

Change `minHeight: 14` to `minHeight: 26`, and remove the now-redundant `.help(group.name)` (the peek card replaces it — a lingering native tooltip on the same region would show underneath/alongside the peek, which reads as a bug, not a feature):

```swift
            .frame(width: 40)
            .frame(minHeight: 26)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
```

- [ ] **Step 5: Add VoiceOver jump actions (accessibility parity with the per-pane pattern)**

Not explicitly required by the approved spec, but this codebase pairs every mouse-only peek card with named accessibility actions reaching the same destinations (see `SidebarSessionTile`'s per-pane `ForEach(PanePeekItem.items(for: session))` actions) — the group roster is the only interactive-content peek in the app that would otherwise have no non-mouse path. Flag this to eD for confirmation, but include the code since it's a direct, low-risk mirror of an established pattern.

Find `.accessibilityActions { groupAccessibilityActionsContent }` and extend `groupAccessibilityActionsContent` (search for `private var groupAccessibilityActionsContent` in this file) by adding, inside its `some View` body, before its closing brace:

```swift
            if isCollapsed, displayMode == .collapsed {
                ForEach(sessions) { session in
                    Button("Jump to \(session.title)") {
                        peekModel.onSelectGroupSession?(session.id)
                    }
                }
            }
```

(Gated on `isCollapsed` too, not just `displayMode == .collapsed`: an *expanded* group that's simply collapsed-shut already exposes each workspace as an ordinary focusable/actionable row once uncollapsed, and duplicate jump actions on a group that's already fully visible would be redundant. `isCollapsed` here is the "this group's own rows are hidden" flag, distinct from `displayMode`'s rail-width mode — see the file's existing doc comment distinguishing the two.)

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: PASS — no existing test touches `SidebarGroupHeaderRow`'s collapsed rendering path directly, but this confirms nothing else broke.

- [ ] **Step 8: Commit**

```bash
git add Sources/awesoMux/Views/SidebarGroupHeaderView.swift
git commit -m "feat(sidebar): trigger the group roster peek from the collapsed header"
```

---

## Task 6: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Build and launch**

Run: `./script/build_and_run.sh`

- [ ] **Step 2: Collapse the sidebar** (⌘\\ or the collapse control) and hover a group's header (the thin colored tint-bar + chevron row above its numbered tiles).

Expected:
- After ~180ms, a card appears listing every workspace in that group, in the same order the numbered tiles show them.
- Background reads as a subtle wash of the group's own color, not plain gray, not fully saturated.
- Hit area for triggering it covers noticeably more than just the thin colored bar — comfortable to land on without pixel-precision aiming.

- [ ] **Step 3: Click a row in the card.**

Expected: jumps directly to that workspace (it becomes selected/focused), the card dismisses.

- [ ] **Step 4: Move the pointer from the header into the card before it would auto-dismiss.**

Expected: card stays open (hover-handoff grace working), and a row click still works from there.

- [ ] **Step 5: Confirm the expanded sidebar is untouched** — expand the sidebar, hover the same group's header.

Expected: no card, no behavior change at all from before this feature existed.

- [ ] **Step 6: Confirm the background tint doesn't clash.**

Show this specifically to eD — the spec left the exact opacity (0.08–0.12) to visual confirmation; Task 3 used 0.10 as the starting value. Adjust `tint.hue.opacity(0.10)` in `SidebarGroupPeekCard.swift` if eD wants it lighter/heavier, then re-run Step 1–2.

- [ ] **Step 7: If VoiceOver is available, verify the Task 5 Step 5 jump actions** — focus a collapsed group header with VoiceOver on, open the rotor/actions menu, confirm a "Jump to <workspace title>" action exists per workspace and activates it.

---

## Plan self-review notes

- **Spec coverage:** architecture (Task 2), trigger scope/mutual exclusivity (Task 2 + Task 5 Step 2), hit-area (Task 5 Step 4), card content/click behavior (Task 1, Task 3, Task 4), background color (Task 3, confirmed in Task 6 Step 6), collapsed-only scope (Task 5's `canPeek` gate + Task 6 Step 5) — all covered.
- **Type consistency:** `SessionPeekItem`, `SidebarGroupPeekCard`'s initializer, and `SidebarPeekModel`'s new method names are used identically across Tasks 1, 3, 4, and 5. `headerFrame`'s coordinate space (plain `.global`) was verified directly against `SidebarSessionTile.tileFrame`'s own modifier rather than assumed.
- **Flagged beyond the literal spec:** Task 5 Step 5 (VoiceOver jump actions) isn't in the approved spec — it mirrors an existing app-wide pattern (every mouse-only peek pairs with named accessibility actions) but should get an explicit nod from eD before or during implementation, not silently.
