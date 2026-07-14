## J'onn J'onzz — Architecture Review

**Proposal:** Sidebar Hover Refinement Implementation Plan
**Clarity rating:** FORMING

The interaction remains precise and proportionate. The overlay rewrite at `51bc1ff` correctly rejects divider animation and chooses one live sidebar host, but it introduces new AppKit ownership boundaries that are not yet fully specified. The plan must close hit testing during partial transforms, redirect every semantic split operation to the stable pane container, and define an atomic overlay-to-split transaction before implementation.

### Overlay Rewrite Verdict — Plan `51bc1ff`, Spec `3723e33`

**Status:** Needs targeted revision before implementation.

The single-host direction is correct. Reparenting `sidebarChild.view`—while keeping its `NSHostingController` and SwiftUI root identity alive—is the smallest architecture that can provide a truly interactive overlay without duplicating sidebar state. The plan also correctly keeps runtime presentation out of `updateNSViewController` and adds strong zero-Ghostty-geometry evidence.

Three blockers remain:

1. The full-width `overlayClipView` is hittable across its final frame even while `overlayContentView` is partially or fully translated away. `masksToBounds` clips pixels, not AppKit hit testing. Without a presentation-aware hit-test boundary, the invisible portion steals terminal clicks, drags, scrolls, and contextual clicks.
2. Current semantic split logic identifies and measures `sidebarChild.view`. Once that view moves into the overlay, it is no longer a split pane and its width is the overlay width. Every split-order, width, divider, responder, and drag provider path must instead use the stable `sidebarPaneContainer`; stating the invariant without enumerating these migrations leaves a mixed-identity failure path.
3. Overlay-to-persistent handoff is described as sequential view mutations but promised as atomic. The plan must specify one no-animation/layout transaction, focus preservation, ordering, and a settled layout before returning. Otherwise the one host can spend a display pass in a hidden zero-width pane or the overlay can disappear before the persistent pane is drawable.

The remaining gaps—explicit layer backing, constraint/autoresizing cleanup, detach behavior, and presentation-aware width changes—are concrete revisions rather than a reason to reject the architecture.

### Overlay Component Diagram

```text
SwiftUI ContentView
  persistent + proximity intent
             |
             v
 SidebarSplitProxy (runtime commands only)
             |
             v
+-------------------------------------------------------------+
| SidebarSplitController root                                 |
|                                                             |
|  +------------------------- NSSplitView ------------------+  |
|  | stable pane A                 stable pane B            |  |
|  | sidebarPaneContainer          detailChild.view         |  |
|  | width 0 when hidden           Ghostty/full detail      |  |
|  +---------------------------------------------------------+  |
|                                                             |
|  + overlayClipView (final edge frame; clips pixels) -------+ |
|  | overlayContentView (layer transform only)               | |
|  |   `-- sidebarChild.view (the ONE live host)              | |
|  +----------------------------------------------------------+ |
|                                                             |
|  edgeTrackingView (40pt, hit-test pass-through, topmost)     |
+-------------------------------------------------------------+

Sidebar host ownership (exactly one parent at all times):

  hidden/persistent                       hover overlay
  sidebarPaneContainer  <----reparent----> overlayContentView

Never:
  - add sidebarChild.view directly as an NSSplitView pane again
  - construct a second NSHostingController
  - evaluate `sidebar()` to create an overlay tree
  - use sidebarChild.view.frame.width as real split width in overlay mode
```

### Overlay State and Handoff Diagram

```text
PERSISTENT(width)
 host=split container; divider=width; overlay hidden
       |
       | explicit Hide (focus handoff, one split collapse)
       v
HIDDEN
 host=split container; divider=0; overlay hidden
       |
       | proximity reveal
       | reparent once, clip visible, content transform = +/-width
       v
OVERLAY_REVEALING ---- reversal ----> OVERLAY_HIDING
 host=overlay for both directions       host remains overlay
 transform -> 0                         transform -> +/-width
       |                                      |
       | winning completion                   | winning completion
       v                                      v
OVERLAY_PRESENTED                         HIDDEN
 host=overlay; divider=0                 reparent after offscreen
       |
       | explicit persistent Show
       v
[ATOMIC HANDOFF]
  cancel compositor + invalidate completion
  preserve responder/AX target identity
  reparent same host to stable split container
  reveal divider once with implicit actions disabled
  force settled layout before transaction returns
       |
       v
PERSISTENT(width)

Any state -- side change/window detach --> cancel generation, clear transform,
                                             hidden stable ownership; no stale resurrection
```

### Overlay Failure Modes

| # | Failure | Trigger | User Impact | State After | Handled? |
|---|---|---|---|---|---|
| O1 | Invisible Hit Shield | Clip keeps its final full width while content layer is translated | Terminal edge input fails in visually empty overlay area | Visual state looks correct; responder routing is wrong | **No — blocker** |
| O2 | Split Identity Substitution | Existing order/width/delegate code still references `sidebarChild.view` | Wrong pane ordering, hidden width reads as overlay width, divider constraints/drag callbacks corrupt | Host mode and split geometry disagree | **No — blocker** |
| O3 | Handoff Blank Frame | Overlay is hidden/reparented before real split is laid out | Flash of no sidebar during explicit show | Final persistent state may be correct | **No — blocker** |
| O4 | Handoff Double Surface | Persistent split becomes visible before overlay presentation is removed | One-frame duplicate-looking sidebar/composited residue | One host, two visual presentations via stale layer | Partial; requires atomic transaction and transform cleanup |
| O5 | Nil Animation Layer | `overlayContentView` is not explicitly layer-backed | Animator receives nil/no transform; reveal fails or crashes through force assumptions | Host sits in overlay but remains offscreen/undefined | **No — explicit `wantsLayer` required** |
| O6 | Constraint Residue | Reparented host carries destination-incompatible constraints or ambiguous autoresizing state | Sidebar frame is zero, stale, or constraint warnings appear | One host in wrong geometry | Partial; frame/autoresizing named, cleanup invariant missing |
| O7 | Root Update Split Brain | Representable update creates another host or updates only the currently visible container | Sidebar state stops updating in one mode | Single-host invariant violated or stale SwiftUI tree | Yes conceptually; add both-mode root update test |
| O8 | Stale Hide Reparent | Old animation completion fires after reversal/show/side change | Live host is pulled out from under current UI | Host parent contradicts requested mode | Yes via generation, if controller validates same generation/mode |
| O9 | Resize Transform Drift | Width changes while layer uses old presentation translation | Overlay jumps, exposes a gap, or finishes partly onscreen | Frame/transform targets disagree | Partial; restart policy needs exact normalization |
| O10 | Window Detach Orphan | Window resigns/detaches during focus/menu/animation | Invisible overlay retains focus or stale completion reparents later | Host/monitor observers outlive valid window | Mostly specified; controller teardown test needed |
| O11 | AX Parent Staleness | Host reparents while accessibility focus is inside it | VoiceOver focus drops or points to detached hierarchy | UI visible, AX navigation broken | Partial; live check plus ancestry test required |
| O12 | Menu-Origin Misattribution | Global menu notification occurs while unrelated app menu tracks | Overlay is retained indefinitely or dismissed under its contextual menu | Interaction signal stale | Partial; attribution and detach tests specified |
| O13 | Peek Coordinate Drift | Existing ContentView-level peek overlay consumes anchors from reparented sidebar coordinate space | Rail peek card appears on wrong side/offset | Sidebar works; auxiliary overlay misplaced | Live coverage only; add coordinate assertion if feasible |
| O14 | Ghostty Resize Leakage | Hover path calls divider/layout API or causes detail frame mutation indirectly | Terminal reflows/jitters—the rejected behavior returns | Hover visually works but violates core goal | Strongly handled by Task 6, after mutation boundaries are complete |
| O15 | Titlebar/Body Divergence | Temporary titlebar width changes independently from overlay host mode or stale proximity completion | Title lockup appears with no overlay or wrong rail/full mode | Chrome contradicts body | Partial; routing matrix should assert mode/width parity |

### Overlay Hidden Assumptions

| # | Assumption | Classification | Risk if Wrong |
|---|---|---|---|
| O1 | Reparenting an `NSHostingController.view` inside one parent controller preserves SwiftUI state and input identity | Verifiable | Search/scroll/focus state resets or view lifecycle churns |
| O2 | `removeFromSuperview`/`addSubview` preserves first responder when source and destination share a window | Verifiable | Explicit overlay-to-persistent show loses focused sidebar control |
| O3 | A layer transform changes AppKit hit testing to match presentation pixels | **Hopeful and false by default** | Invisible clip steals terminal input |
| O4 | Layer clipping also clips accessibility exposure | Hopeful | Offscreen sidebar elements remain AX reachable during hide animation |
| O5 | `overlayContentView.layer` exists because its parent is layer-backed | Hopeful | Animator has no layer; behavior differs across hosting hierarchy |
| O6 | All existing semantic split code can transparently substitute a container for the child host | Verifiable | Left/right, drag, constraints, and persistence regress |
| O7 | One `setPosition` call produces one meaningful Ghostty resize | Verifiable but framework-dependent | Exact frame-callback count is brittle; intent count and settled sizes diverge |
| O8 | Updating the existing hosting controller's `rootView` preserves state identity across reparent modes | Verifiable | Sidebar state resets on unrelated SwiftUI updates |
| O9 | A 32-hop AX-parent limit covers the actual sidebar hierarchy and menu ownership | Verifiable | Active AX interaction fails retention |
| O10 | AppKit window-update notifications arrive for every focus/AX transition that matters | Verifiable | Overlay dismisses while active input remains inside |
| O11 | Existing `SidebarWidthPolicy` max derived from terminal minimum is the intended overlay clamp | Verified by approved spec's “existing width policy” | Overlay width differs from persistent selection in narrow windows |
| O12 | Titlebar may reflect selected overlay width without changing terminal/body split geometry | Verified by approved titlebar addition | Temporary lockup/body modes diverge |

### Overlay Shadow Paths

#### Single-host reparenting

- **Nil input:** If either destination is unavailable or the controller view is not loaded, do not detach the current host. Record requested mode and settle after valid layout.
- **Empty input:** A zero-sized destination/window must leave the host in a stable hidden container; never expose or animate a zero-width overlay.
- **Upstream failure:** If reparent/layout cannot establish the destination frame, roll back to hidden split-container ownership, clear interaction/focus retention, and keep explicit commands usable.

#### Representable root updates

- **Nil input:** A failed generic cast must not silently leave one mode stale. The existing stable-concrete-type contract should remain documented and receive a host-identity/root-update test in both persistent and overlay modes.
- **Empty input:** Reassigning an equivalent root must not construct another hosting controller or trigger a presentation transition.
- **Upstream failure:** Ordinary SwiftUI updates never enact host mode, divider geometry, or overlay visibility; the runtime proxy remains the only enactor.

#### Overlay animation

- **Nil input:** If no backing layer or presentation layer exists, use the model transform and settle safely; do not force unwrap.
- **Empty input:** Equal source/target transforms complete synchronously without adding an animation or changing parentage.
- **Upstream failure:** If Core Animation completion is lost, a newer command/resize/lifecycle event must cancel and normalize from current model/presentation state.

#### Overlay-to-split handoff

- **Nil input:** If no valid window/responder exists, perform the same ownership/geometry transaction without focus restoration rather than leaving overlay mode half-active.
- **Empty input:** Repeating persistent show/hide in its settled mode performs no reparent, divider mutation, or titlebar change.
- **Upstream failure:** If selected width is invalid, clamp before transaction; if layout cannot settle, end in hidden stable ownership rather than a visible overlay plus persistent intent.

#### Interaction retention

- **Nil input:** No focused AX element and no first responder means pointer/menu state alone determines retention.
- **Empty input:** A menu begin unrelated to the sidebar must not activate retention.
- **Upstream failure:** Window detach removes observers, clears active interaction exactly once, invalidates grace/animation generations, and reparents hidden.

#### Geometry isolation proof

- **Nil input:** Missing frame notifications cannot be treated as proof. The `GeometryRecordingView.setFrameSize` seam is the authoritative negative evidence.
- **Empty input:** No-op same-size assignments are excluded; tests compare changed submitted sizes and split mutation intent separately.
- **Upstream failure:** Any hover matrix case recording a changed detail size is a release blocker, even if screenshots look smooth.

### Overlay Unfinished Thoughts

1. **Presentation-aware hit testing.** The plan asserts input only inside the visible overlay, but the proposed standard clip view does not implement that guarantee. Add a dedicated `SidebarOverlayClipView` (or equivalent controller override) whose `hitTest` intersects the event point with the overlay content's current presentation-layer visible rect. Fully hidden returns `nil`; partially revealed accepts only the visible sliver; fully presented accepts the final sidebar frame. Add click/scroll/contextual hit tests at covered and uncovered points during held animation.
2. **Stable semantic pane migration.** Name every current reference that must switch from `sidebarChild.view` to `sidebarPaneContainer`: `SidebarSubviewOrder`, `sidebarPaneWidth`, `shouldAdjustSizeOfSubview`, responder containment for persistent pane focus, drag width provider, direct split-subview assertions, and position sorting. Keep sidebar interaction/focus ancestry checks rooted at `sidebarChild.view`. Add a test that reparenting cannot change `splitView.subviews` identity/order/count.
3. **Atomic handoff mechanics.** Define one `performAtomicHostHandoff` helper using disabled implicit layer actions and suppressed intermediate callbacks. Reparent, set host frame/autoresizing, set `isSidebarHidden`/mode coherently, apply the single divider target, call layout to settle, clear stale transform, and only then expose/hide appropriate containers. Preserve first responder when it belongs to the sidebar; hand off only for explicit hide. Test state/callback ordering with a held display transaction seam, not only final state.
4. **Layer creation and teardown.** Explicitly set `overlayContentView.wantsLayer = true`, require a non-nil layer before constructing the animator, remove animation keys during every reparent/detach, and reset model transform to identity/offscreen as appropriate.
5. **Constraint/autoresizing ownership.** Assert the sidebar host has no superview-owned constraints before removal. Use exactly one geometry system per destination (frame + autoresizing, or destination-owned constraints), and remove destination constraints before the next reparent. `overlayContentView` itself needs explicit frame/autoresizing or layout on every root resize.
6. **Resize during partial animation.** Specify whether the current visible fraction or absolute translation is preserved when width reclamps. Preserving fraction is usually less jumpy: sample presentation translation / old hidden translation, remove animation, reframe, map fraction to new width/side, then restart toward newest intent. Test both side and width changes.
7. **Width toggle while overlay is active.** The plan says the frame updates without Ghostty movement but not how a partially presented transform maps from old rail/full width to the new width. Use the same fraction-preserving normalization and assert no invisible hit shield.
8. **Accessibility during partial/hidden transforms.** A transform does not automatically remove offscreen descendants from AX navigation. Define whether overlay descendants are accessibility-hidden until fully revealed or expose only when presented; during hide, retain them while active AX focus requires the overlay, then clear AX exposure before final reparent. Test wrapper absence and offscreen-state exclusion.
9. **Titlebar parity source.** Derive temporary lockup visibility/width from the controller-authoritative host mode or the same routing state that commands it. Add routing assertions that cue/hide completion/side invalidation cannot leave a temporary lockup visible after overlay removal.
10. **Instrumentation completeness.** Route every divider setter, including hidden restore, position change, reclamp, and delegate normalization, through the counted helper. Frame-notification counts are secondary; the recording detail view is the stronger proof of zero Ghostty resize.

### Overlay Second-System Check

The overlay architecture is more complex than divider animation, but the rejected divider approach could not satisfy the core product requirement of zero Ghostty resize/reflow. A single reparented host, one narrow compositor animator, and one interaction reducer are proportional to a live interactive overlay.

Avoid expanding further:

- Do not introduce two SwiftUI trees, snapshots, a generalized presentation framework, or a global event monitor.
- Do not generalize host reparenting beyond this controller.
- Do not make AX/menu/focus sources separate presentation states; reduce them to the one interaction-retention signal as planned.
- Do not promise an exact number of internal AppKit frame callbacks as the primary contract. The production contract is zero changed detail sizes during hover and one explicit persistent geometry intent; use settled-size evidence for framework behavior.

### Overlay Earth vs Sand

**Earth — sound foundations**

- Approved overlay interaction and strict zero-split-geometry requirement.
- One `NSHostingController` and one live sidebar view across modes.
- Stable split pane containers rather than reparenting an `NSSplitView` direct child.
- Runtime commands flow ContentView → proxy → controller; representable updates do not present UI.
- Compositor-only transform with generation-based reversal/cancellation.
- Explicit pointer/focus/AX/menu retention collapsed to one model signal.
- Geometry-recording detail view plus mutation-boundary instrumentation.
- Existing proximity, persistence, width, titlebar, and semantic position policies remain reused.

**Sand — must be compacted before code**

- Default `NSView` hit testing does not match the transformed visible overlay.
- Current semantic split references still point at the soon-to-be-reparented host view unless exhaustively migrated.
- “Atomic” handoff lacks a defined AppKit transaction and ordering contract.
- Overlay content layer backing is assumed rather than established.
- Reparent constraint/autoresizing cleanup and partial-resize mapping are underspecified.
- AX exposure during offscreen/partial transforms is not defined.

### Overlay Plan Revisions Required

1. Add a presentation-aware overlay clip/hit-test view and automated covered/uncovered hit tests during held partial transforms.
2. Add a semantic-pane migration checklist and tests proving `NSSplitView` always contains exactly the stable container/detail views in correct position order, while split width/provider/delegate math reads the container.
3. Specify and test one atomic handoff helper with disabled implicit actions, coherent state ordering, responder preservation, one divider intent, settled layout, and transform cleanup.
4. Explicitly establish/tear down overlay layer backing and destination geometry ownership across every reparent.
5. Define fraction-preserving resize and rail/full-width changes during a partial animation, including mirrored left/right behavior.
6. Define AX exposure for offscreen, partial, presented, active-focus, and final-hide states.
7. Add same-host root-update tests in hidden, overlay, and persistent modes; prove ordinary representable updates neither reparent nor change geometry.
8. Strengthen titlebar routing tests so temporary lockup state cannot outlive controller overlay state.
9. Treat zero changed detail sizes as the Ghostty proof and one persistent divider mutation as the control; avoid making a brittle exact frame-notification count the sole acceptance criterion.

### Overlay Recommendation

The rewritten overlay direction should proceed after one focused plan revision. I do not need to read minds to see the attraction of the single-host design: it preserves the sidebar's lived state instead of manufacturing a convincing duplicate. That is the correct foundation.

But pixels and events inhabit different worlds in AppKit. A layer transform can move what the user sees without moving what AppKit believes is under the pointer. Until the plan binds those worlds with presentation-aware hit testing, the feature would solve terminal reflow by silently breaking terminal input. Likewise, the stable pane container must become the sole semantic sidebar identity for split geometry, not merely another wrapper.

Revise the nine items above. Once hit testing, semantic pane identity, and atomic handoff are explicit and tested—and the remaining lifecycle/layer/AX details are folded in—the architecture can return to CRYSTALLINE and implementation may begin.

### Historical Re-review Verdict — Divider Plan `837558a`

The following blockers were resolved in the earlier divider-animation plan. That implementation direction is superseded by overlay spec `3723e33`; this table remains as history and as a record of invariants the overlay must preserve:

| Initial blocker | Revised-plan resolution | Verdict |
|---|---|---|
| Dual runtime visibility enactors | `makeNSViewController` owns one-shot restoration; `SidebarSplitProxy.setVisibility` is the sole runtime route; `updateNSViewController` is forbidden from calling visibility setters and receives a structural regression test | Resolved |
| Rail/full dead-zone snapping during animation | `isHoverAnimating` bypasses only `constrainSplitPosition` snapping; targets remain clamped and min/max policy remains active; both sides receive tests | Resolved |
| Tracker/sidebar overlap arbitration | `sidebarPointerPresent` is authoritative; both event-order permutations are tested | Resolved |
| Silent entry | `mouseEntered` and `mouseMoved` share one coordinate-report helper and a synthetic entry test | Resolved |
| Incomplete availability-loss path | Callback is carried tracker → controller → representable → model/proxy; it invalidates both generations and immediately settles hidden | Resolved |
| Repeated/equal request churn | Same-intent in-flight requests no-op; equal current/target requests normalize synchronously; runner-count tests enforce both | Resolved |
| Insufficient real AppKit evidence | Live verification explicitly covers dead-zone traversal, both sides and widths, overlap, pass-through input, deactivation, reversal, and Reduce Motion | Resolved |
| Right-side title lockup alignment (`4e7239a`) | Position-only policy moves the complete unchanged `Brandmark` lockup to trailing alignment with the named existing 10-point inset; traffic-light column policy and content-column clearance remain untouched; hidden/rail suppression continues to derive from effective visible width and existing thresholds | Resolved |

At that stage no divider-plan blocker remained. The overlay rewrite creates the new blockers named above.

### Addendum — Right-Side Title Lockup Task (`4e7239a`)

The newly added Task 5 is architecturally compatible with the approved hover design and does not reopen runtime visibility ownership.

```text
Appearance.sidebarPosition
          |
          +---------------------------+
          |                           |
          v                           v
titlebarColumns / traffic lights   titlebarLockupAlignment
(existing policy, unchanged)       left -> leading
 left:  sidebar | detail           right -> trailing
 right: detail  | sidebar                    |
          |                                  v
          |                         whole existing Brandmark
          |                         [icon][awesoMux]
          v                                  |
physical-leading column keeps               v
trafficLightClearance              10pt physical outer inset

effective titlebar sidebar width
 visible -> sidebarLiveWidth.value -> existing full/icon/hidden thresholds
 hidden  -> 0                      -> no lockup remnant
```

The title task preserves the important boundaries:

- **Traffic-light behavior:** The right sidebar still places the detail column physically first, and the existing content-column path still applies `trafficLightClearance`. Task 5 changes only alignment inside the sidebar column. Existing `SidebarPresentationLayoutTests` assert `.right` maps traffic lights to `.detail`, and that suite is part of the focused run.
- **Hidden and rail behavior:** `AppTitlebarView` already derives its effective sidebar width as zero when hidden and uses the live pane width only while visible. Task 5 does not create presentation state or alter thresholds. The matrix and screenshot checks cover persistent/temporary rail and full states; hidden remains zero-width with no lockup. At the current rail width, the existing suppression remains intact.
- **Item order:** The whole `Brandmark` moves as one unit. Its internal `HStack` remains icon-before-text. The structural regression is modest but appropriate because the implementation is forbidden from editing `Brandmark.swift`, and live screenshots verify the rendered result.
- **Animation ownership:** Alignment is position-only. Hover animation changes the sidebar column width; it does not add a second title animation or another visibility enactor.
- **Padding:** Naming the existing literal as `AppTitlebarMetrics.lockupPadding == 10` consolidates an existing contract rather than introducing a new layout dependency.

Coverage is proportional and adequate: pure policy assertions protect side/alignment/padding and existing traffic-light mapping; the real lockup receives an order guard; focused regression suites cover hover/split integration; and the six-state screenshot matrix plus narrow/wide final checks verify clipping, suppression, and persistent/temporary parity. No additional architecture test is required before implementation.

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

### Historical Recommendation — Superseded by Overlay Review

The earlier divider plan was ready to implement, including the right-side title lockup task added in `4e7239a`. Its runtime ownership and titlebar conclusions remain valid, but its hover-divider recommendation is superseded by overlay spec `3723e33` and the current FORMING verdict above.

Proceed task by task with the specified red-green discipline. Treat the real AppKit checks as release evidence, not optional polish: the pass-through tracker and animated divider still depend on framework behavior that pure seams cannot prove. If those live checks expose different event ordering or presentation geometry, preserve the plan's ownership invariants and adjust the narrow adapter—not the state model.

The current architecture questions that must be answered before writing code are listed under **Overlay Plan Revisions Required**.
