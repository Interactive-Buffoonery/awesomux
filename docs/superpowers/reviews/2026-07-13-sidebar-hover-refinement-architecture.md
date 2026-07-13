## J'onn J'onzz — Architecture Review

**Proposal:** Sidebar Hover Refinement Implementation Plan
**Clarity rating:** CRYSTALLINE

The interaction is precise and proportionate. The revised plan now gives runtime visibility one owner, names the overlap arbitration rule, bypasses only the divider constraint that would corrupt animation, and closes the tracker lifecycle path end to end.

### Re-review Verdict — Commit `837558a`

All architecture blockers from the initial review are resolved in the plan:

| Initial blocker | Revised-plan resolution | Verdict |
|---|---|---|
| Dual runtime visibility enactors | `makeNSViewController` owns one-shot restoration; `SidebarSplitProxy.setVisibility` is the sole runtime route; `updateNSViewController` is forbidden from calling visibility setters and receives a structural regression test | Resolved |
| Rail/full dead-zone snapping during animation | `isHoverAnimating` bypasses only `constrainSplitPosition` snapping; targets remain clamped and min/max policy remains active; both sides receive tests | Resolved |
| Tracker/sidebar overlap arbitration | `sidebarPointerPresent` is authoritative; both event-order permutations are tested | Resolved |
| Silent entry | `mouseEntered` and `mouseMoved` share one coordinate-report helper and a synthetic entry test | Resolved |
| Incomplete availability-loss path | Callback is carried tracker → controller → representable → model/proxy; it invalidates both generations and immediately settles hidden | Resolved |
| Repeated/equal request churn | Same-intent in-flight requests no-op; equal current/target requests normalize synchronously; runner-count tests enforce both | Resolved |
| Insufficient real AppKit evidence | Live verification explicitly covers dead-zone traversal, both sides and widths, overlap, pass-through input, deactivation, reversal, and Reduce Motion | Resolved |

No unresolved blocker remains before implementation. The remaining uncertainties are deliberately classified as verification work rather than architectural ambiguity.

### System Diagram

```text
 Pointer in local 40pt edge band
              |
              v
 +---------------------------+       window/position/lifecycle
 | SidebarEdgeTrackingView   |--------------------+
 | - NSTrackingArea          |                    |
 | - hitTest always nil      |                    v
 | - reports local x,width   |      +-----------------------------+
 +-------------+-------------+      | SidebarPresentationModel    |
               |                    | persistent: userWantsHidden  |
               +------------------->| transient: proximityState    |
                                    | handoff: sidebarPointer      |
                                    | token: delayed-hide gen      |
                                    +--------------+--------------+
                                                   |
                       cue visibility              | visibility intent
                              +--------------------+-------------------+
                              v                                        v
                 +------------------------+             +-------------------------+
                 | SidebarProximityCue    |             | ContentView orchestrator|
                 | 4pt, no hit/AX/layout  |             | classifies source       |
                 +------------------------+             | pointer vs explicit     |
                                                        +------------+------------+
                                                                     |
                                                      proxy.setVisibility(intent,
                                                      transition, reduceMotion)
                                                                     |
                                                                     v
                                                       +--------------------------+
                                                       | SidebarSplitController   |
                                                       | sole runtime enactor     |
                                                       | semantic pane roles      |
                                                       | animation generation     |
                                                       | current -> latest target |
                                                       +------------+-------------+
                                                                    |
                                                                    v
                                                               NSSplitView
```

The runtime ownership rule must be explicit:

```text
initial construction/restoration -> SidebarSplitView.makeNSViewController (immediate)
runtime visibility changes       -> SidebarSplitProxy.setVisibility only
ordinary SwiftUI representable update -> callbacks, position, tracker; NOT visibility
```

Without that rule, a proximity change can produce both an immediate `updateNSViewController` collapse/reveal and a 140ms proxy animation. The result depends on SwiftUI scheduling rather than the requested interaction.

### State Diagram

```text
Persistent visible
  userWantsHidden = false
  proximity = dormant
        |
        | explicit Hide (instant; invalidate transient work)
        v
Hidden / Dormant  -- pointer distance <= 40 --> Hidden / Cue
      ^                                        |
      |                                        | distance < 16
      |                                        v
      +-- outside tracker after grace -- Hidden / Revealed
                                              |
                                              | pointer enters revealed sidebar
                                              v
                                  Revealed + sidebarPointerPresent
                                              |
                                              | leaves tracker and sidebar
                                              | -> generation-safe 220ms grace
                                              v
                                      Hidden / Dormant

Any state -- explicit Show --> Persistent visible (instant)
Any hidden state -- Command-Backslash --> same state, remembered width toggled
Any transient state -- position/lifecycle invalidation --> Hidden / Dormant (instant)
```

There is an overlap zone after reveal: the 40-point tracker lies above the revealed sidebar while the sidebar's SwiftUI hover also reports pointer presence. The model must define arbitration. `sidebarPointerPresent == true` must keep `.revealed` authoritative even if an edge movement reports a cue-distance coordinate. Otherwise the sidebar can begin collapsing while the pointer is visibly inside it.

### Failure Modes

| # | Failure | Trigger | User Impact | System State After | Handled? |
|---|---------|---------|-------------|-------------------|----------|
| 1 | Dual Visibility Enactors | `proximityState` rerenders `SidebarSplitView`; `updateNSViewController` applies `.immediate` while `.onChange` sends `.hover` | Hover reveal jumps or animation is cancelled nondeterministically | Model and split agree eventually, but transition semantics are lost | **No — blocker** |
| 2 | Rail-Snap Animation | Existing `constrainSplitPosition` snaps every intermediate width between collapsed and rail threshold | Reveal/hide jumps through the dead zone instead of moving smoothly | Final width may be correct; animation is visibly broken | **No — plan must bypass snapping while hover-animating** |
| 3 | Overlap-State Collapse | Tracker reports cue distance while sidebar hover reports present | Sidebar retreats beneath a pointer already inside it | Competing transient inputs; possible flicker/grace churn | **No — arbitration rule missing** |
| 4 | Silent Edge Entry | Pointer enters the tracking area without a subsequent `mouseMoved` delivery | No cue until the pointer moves again | Model remains dormant despite pointer in band | Partial — report coordinates from `mouseEntered` too |
| 5 | Stale Hide Completion | Pointer re-enters, command runs, resize occurs, or side changes during grace | Newly revealed sidebar collapses or old cue returns | Obsolete transient state wins | Yes — generation validation is specified |
| 6 | Stale Animation Completion | Rapid reversal or immediate command lands during a hover animation | Old reveal/hide wins after newer intent | Divider contradicts model | Yes — animation generation is specified |
| 7 | Hidden Width Persistence Leak | Intermediate/zero animation ticks reach width commit callback | Next launch restores zero or partial width | Durable preference corrupted | Yes — callbacks are suppressed; tests required |
| 8 | Responder Theft | Hosting/tracker changes or collapse alters first responder | Terminal typing stops or focus disappears unexpectedly | Focus sits in zero-width sidebar or nil | Mostly — preserve responder tests; explicit hide handoff remains required |
| 9 | Detached Tracker Residue | Window detaches/resigns key during cue/reveal | Cue remains or delayed work fires in inactive window | Stale proximity state | Yes — availability invalidation is specified |
| 10 | Narrow-Window Target Drift | Resize changes max width during animation | Partial sidebar or terminal below minimum | Current and target geometry diverge | Mostly — resize policy named; exact restart/settle rule should be asserted |
| 11 | Side-Change Ghost Cue | Position changes before old tracker/timer/animator clears | Cue or reveal appears on wrong edge | Old-edge work survives new geometry | Yes — ordering is specified |
| 12 | Reduce-Motion Race | accessibility preference changes between model event and enaction | One transition animates contrary to current preference | Correct final layout, wrong motion behavior | Yes if read exactly at proxy transition boundary |
| 13 | Tracker Input Interception | Overlay participates in hit testing or becomes a pane | Terminal edge clicks, drags, selections, or scrolls fail | Input diverted | Yes structurally, subject to live verification |

### Hidden Assumptions

| # | Assumption | Classification | Risk if Wrong |
|---|-----------|---------------|---------------|
| 1 | A pass-through sibling `NSView` with an `NSTrackingArea` continues receiving entered/moved/exited events despite `hitTest` returning `nil` | Verifiable | Core pointer interaction does not fire or is inconsistent |
| 2 | `NSSplitView.animator().setPosition` produces useful cancellable presentation geometry | Verifiable | Interruption restarts from model width rather than visual width and jumps |
| 3 | Existing delegate snapping will not affect programmatic animation | Hopeful | Intermediate widths snap; animation is not smooth |
| 4 | SwiftUI `.onChange` runs in an order compatible with representable updates | Hopeful and unwarranted | Immediate and animated requests race |
| 5 | Sidebar `.onHover` and edge-tracker events have a deterministic ordering in their 40-point overlap | Hopeful | Flicker or premature collapse |
| 6 | `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` reflects the current preference synchronously | Verifiable | Motion setting is stale for a transition |
| 7 | Tracker bounds always match the intended physical 40-point band after resize and side change | Verifiable | Wrong thresholds or wrong-edge cue |
| 8 | A 4-point accent at full opacity remains legible against all supported terminal/window backgrounds | Verifiable | Discoverability goal fails for some themes |
| 9 | Existing focus handoff can establish a visible terminal responder during an immediate explicit hide | Verified by current implementation/tests | Focus ends nil or remains in hidden sidebar |
| 10 | A closure animation seam can faithfully test mid-animation current width | Verifiable | Tests prove callback sequencing but not actual AppKit presentation behavior |

### Shadow Paths

#### Pointer geometry flow

- **Nil input:** There is no nullable coordinate in the public callback. Detachment/window loss must route through `onAvailabilityLost`, not fabricate a coordinate.
- **Empty input:** Zero-width or non-finite bounds remain dormant and invalidate transient work; they must never clamp into a false edge reveal.
- **Upstream failure:** If tracking is unavailable, remain persistently hidden and preserve keyboard/menu operation. Do not add a window-wide monitor fallback.

#### Proximity state to split visibility

- **Nil input:** A proxy closure can be absent during construction/teardown. The model remains authoritative; the next valid synchronization must settle immediately to current state.
- **Empty input:** Repeated requests for the already-requested visibility must be idempotent and must not restart 140ms animations indefinitely.
- **Upstream failure:** If AppKit cannot animate or geometry is invalid, cancel the animation generation and settle immediately to the newest requested state.

#### Width selection while hidden

- **Nil input:** If no expanded width has been stored, use the existing policy default—not zero and not a transient frame width.
- **Empty input:** A zero/non-finite stored width must pass through existing width-policy validation before becoming `pendingWidth`.
- **Upstream failure:** A persistence write failure should not reveal the sidebar or corrupt current transient state; the in-memory selected mode still governs this session.

#### Animation completion

- **Nil input:** A deallocated controller makes completion a no-op.
- **Empty input:** A start width already equal to target should normalize synchronously rather than schedule a cosmetic animation.
- **Upstream failure:** Interrupted or non-running AppKit animation must normalize via the current generation/request, never the captured original request.

### Unfinished Thoughts

1. **Runtime visibility ownership.** Task 3 says representable updates apply hidden values immediately; Task 4 also routes proximity changes through the proxy. These are mutually incompatible. The plan must name one runtime enactor.
2. **Delegate constraints during animation.** `isHoverAnimating` is said to suppress drag, reclamp, live-width, and commit behavior, but the existing `constrainSplitPosition` dead-zone snap is not named. It must return the proposed position unchanged during hover animation while min/max bounds remain enforced by the precomputed target.
3. **Pointer-source arbitration.** One enum is good, but the revealed sidebar and tracker overlap. The plan must state how `sidebarPointerPresent` modifies distance-driven transitions. A pointer inside the revealed sidebar should not be downgraded by the tracker.
4. **Entry semantics.** The tracker example implements `mouseMoved` and `mouseExited` but not `mouseEntered`. Initial entry must immediately classify current coordinates so the 40-point cue does not require a second movement.
5. **Tracker availability synchronization.** `onAvailabilityLost` appears in the shared interface but is not included in the controller callback wiring steps. It must route to `invalidateTransientState()` and an immediate split settlement.
6. **No-op/redundant animation policy.** The plan should state that equal current/target widths complete synchronously and repeated identical intent does not restart animation.
7. **Actual AppKit evidence.** The closure seam verifies state logic, not whether `NSSplitView` animates smoothly under its delegate. The live checklist is necessary and should explicitly observe intermediate widths across both rail and full targets.

### Boundary Cartography

| Boundary | What crosses it | Owner / guarantee |
|---|---|---|
| AppKit pointer -> model | local `x`, live tracker width, physical side | Tracker reports only; model classifies |
| Model -> SwiftUI cue | `isCueVisible` | Cue renders only; never affects hit testing/layout |
| Model -> split enactor | visible intent + explicit/pointer source + current Reduce Motion | `ContentView` classifies; proxy is sole runtime route |
| SwiftUI representable -> controller | construction/restoration, callbacks, tracker configuration, side | Make path may settle initial visibility; update path must not race runtime proxy |
| Controller -> persistence | settled user divider width only | Animation, hidden zero, and intermediate widths never cross |
| Sidebar hover -> model | pointer present/absent in revealed pane | Presence dominates edge-distance downgrade until both regions are absent |

### The Second System Check

The complexity is proportional. This is not merely a fade: it combines persistent preference, transient hover state, AppKit tracking, split geometry, interruption, accessibility motion policy, and terminal input preservation. A typed state machine and generation tokens are justified.

Two pieces flirt with unnecessary abstraction:

- `SidebarHoverTransitionPolicy` is useful only if it prevents source classification from spreading. Keep it small and internal.
- A general animation framework would be a second system. The proposed closure seam and one hover-specific animator are sufficient.

Do not add hysteresis, global event monitoring, configurable thresholds, or generalized transition engines in this change. The approved exact 40/16 policy and one grace timer are enough.

### Earth vs Sand

**Earth — load-bearing concrete**

- Persistent hidden preference remains separate from transient proximity.
- A single explicit `ProximityState` replaces view-derived booleans.
- Semantic sidebar/detail pane roles and position-aware divider math already exist.
- Generation invalidation for delayed hide and animation completion.
- Input-preserving AppKit tracking with keyboard/menu fallback.
- Immediate explicit commands and Reduce Motion policy.
- Hidden/intermediate widths excluded from persistence.

**Sand — now compacted by the revised plan; verify during implementation**

- Runtime visibility ownership is protected by an explicit construction/runtime boundary and a structural regression test.
- Dead-zone traversal and overlap arbitration are now named, implemented through narrow policies, and tested on both sides.
- `mouseEntered` and availability-loss plumbing are specified end to end.
- The closure seam remains intentionally incomplete evidence; the revised live checklist supplies the required real AppKit verification on both sides.

### Concrete Plan Revisions Applied in `837558a`

1. **Make `SidebarSplitController` the sole runtime visibility enactor via `SidebarSplitProxy.setVisibility`.** `makeNSViewController` applies cold-launch/restoration immediately. Remove ordinary runtime `setSidebarHidden(isHidden)` from `updateNSViewController`, or replace the input with an explicit versioned command that cannot race the proxy. Prefer removal because the proxy already exists.
2. **Add a test for the ownership rule.** A proximity state render/update must not invoke an immediate visibility setter; exactly one pointer transition reaches the controller and retains `.hover(0.140)`.
3. **During `isHoverAnimating`, bypass `constrainSplitPosition` dead-zone snapping** by returning the proposed position. Keep target clamping before animation and retain terminal minimum enforcement. Add a test whose animation passes through widths between collapsed width and rail threshold.
4. **Define overlap arbitration in Task 1:** when `sidebarPointerPresent` is true, distance reports cannot downgrade `.revealed`; collapse grace begins only after both the tracker/reveal zone and revealed sidebar are absent. Add event-order permutation tests.
5. **Handle `mouseEntered` identically to `mouseMoved`** using one coordinate-report helper. Test entry produces cue/reveal without a second movement.
6. **Wire `onAvailabilityLost` end to end** through controller and representable to `invalidateTransientState()`, cancel animation, and settle hidden immediately.
7. **Specify idempotence:** same visibility intent during an active matching animation does not restart it; current width equal to target settles synchronously.
8. **Extend live verification** to confirm smooth traversal through the rail/full dead zone, both left and right, and verify no terminal edge click/drag/scroll loss while the pass-through tracker is active.

### J'onn's Recommendation

The plan is ready to implement. I no longer sense two competing truths at the SwiftUI/AppKit boundary: construction restores once, the proxy enacts runtime intent, and the controller alone moves the divider. The revised tests make that boundary falsifiable rather than aspirational.

Proceed task by task with the specified red-green discipline. Treat the real AppKit checks as release evidence, not optional polish: the pass-through tracker and animated divider still depend on framework behavior that pure seams cannot prove. If those live checks expose different event ordering or presentation geometry, preserve the plan's ownership invariants and adjust the narrow adapter—not the state model.

There are no architecture questions that must be answered before writing code.
