## J'onn J'onzz — Architecture Review

**Proposal:** Persistent sidebar hide/show with hover reveal, left/right placement, and Markdown toggle alignment.
**Clarity rating:** CRYSTALLINE after revision (initial draft: FORMING)

### System Diagram

```text
Appearance TOML ── position ────────────────────┐
                                                v
Explicit commands ── durable intent ──> Presentation model
Pointer hover ────── temporary intent ─────────┤
                                                v
                                      ContentView boundary
                                         │           │
                               position/visibility  peek edge
                                         │           │
                                         v           v
                                  NSSplitView      Overlay

UserDefaults owns hidden intent; the width store never receives zero.
```

### Failure Modes

| # | Failure | Trigger | User Impact | System State After | Handled? |
|---|---|---|---|---|---|
| 1 | Divider-thickness drift | Right-side width subtracts from total bounds | Sidebar is offset or slowly changes width | Layout and stored width disagree | Yes: pane-extent math includes divider thickness. |
| 2 | First-responder loss | Runtime side swap removes/recreates a hosting view | Terminal keyboard input disappears | Visible UI with wrong responder | Yes: reorder attached views in place and preserve responder. |
| 3 | Wrong-role drag commit | Drag tracker treats the leading view as sidebar | Right-side drag persists terminal width | Corrupt sidebar width preference | Yes: semantic sidebar-width provider. |
| 4 | Hidden-width corruption | Zero-width callback reaches persistence | Show restores a rail or invalid width | Hidden state contaminates width state | Yes: hidden callbacks are suppressed. |
| 5 | Stale hover hide | Old grace task fires after re-entry or side change | Sidebar vanishes under pointer | Persistent intent remains hidden | Yes: cancellation plus generation guard. |
| 6 | Hidden resize expansion | Reclamp runs while hidden | Sidebar reappears during window resize | UI contradicts hidden preference | Yes: hidden layout bypasses reclamp. |
| 7 | Peek orphan | Position changes while card uses old anchor | Card appears off-window | Stale overlay geometry | Yes: clear peek state before side change. |
| 8 | Edge handoff flicker | Edge exit precedes sidebar-enter event | Reveal collapses before pointer reaches it | Returns to hidden | Yes: shared 220ms grace. |

### Hidden Assumptions

| # | Assumption | Classification | Risk if Wrong |
|---|---|---|---|
| 1 | awesoMux has one primary window, so hidden intent is app-wide | Verified by current architecture | Per-window storage would add unused complexity. |
| 2 | Existing hosting views can be reordered without recreating terminal surfaces | Verifiable through identity and responder tests | A rebuild could interrupt terminal rendering/input. |
| 3 | `NSSplitView` divider thickness participates in trailing width | Verified from AppKit geometry | Omitting it creates asymmetric layout. |
| 4 | A 220ms grace covers edge-to-sidebar pointer handoff | Verifiable in the running app | Too short flickers; too long feels sticky. |
| 5 | Menu/palette/shortcut provide the accessible hide/show surface | Verified by existing command architecture | The invisible pointer trigger must not become a mystery focus target. |

### Shadow Paths

- **Nil input:** No selected session leaves titlebar content in its existing empty state; sidebar presentation remains independent.
- **Empty input:** No workspaces or peek rows does not affect split roles, hidden state, or edge reveal.
- **Upstream failure:** Invalid present TOML values fail closed through config decoding; missing values default left. UserDefaults absence defaults visible. A stale async hover task is cancelled and generation-gated.

### Unfinished Thoughts Resolved

- The original right-side conversion ignored divider thickness.
- The original drag tracker still read `subviews.first`, contradicting semantic role ownership.
- The original position-change flow did not name first-responder preservation or stale peek cleanup.
- The original hidden store copied unused per-window width-store complexity into a single-window feature.
- The original hidden resize path did not explicitly suppress restore-on-grow.

### The Second System Check

The revised plan is proportional. A focused state model and two pure geometry helpers are warranted by async hover handoff and bidirectional split math. Per-window hidden keys, a floating overlay sidebar, and a third persisted width are rejected as unnecessary second systems.

### Earth vs Sand

- **Earth:** Existing shortcut routing, UserDefaults profile isolation, TOML defaults, width policy, and cancellable peek-task pattern.
- **New concrete:** Semantic split roles, pane-extent conversion, explicit hidden endpoints, generation-guarded presentation state.
- **Requires live validation:** AppKit responder preservation during side swap and the subjective 220ms pointer grace.
- **Deliberately visual-only validation:** The 2pt Markdown offset; the metric is unit-tested, while actual optical centering requires the running app.

### J'onn's Recommendation

The plan may proceed. I sensed several unspoken beliefs in the first draft: that the divider had no thickness, that leading always meant sidebar, and that AppKit would preserve terminal focus through any rearrangement. Those beliefs are now replaced by explicit invariants and tests. No architectural question remains unanswered before code; the two platform-sensitive claims are named as mandatory live-verification gates rather than assumed truths.
