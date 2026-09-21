# Session Manager Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every amx-backed row human-identifiable and let awesoMux open, restore, or recover the surviving terminal without requiring UUID commands.

**Architecture:** Keep `TerminalSessionID` as the immutable backend identity. Add an atomic `amx attach --existing` mode so recovery can never recreate a vanished daemon, encode a small `DaemonRecoveryMetadata` value into existing zmx labels, merge it with live workspace and recently-closed data in the existing resolver, and add one guarded `SessionStore` recovery mutation for abandoned daemons. The existing verbose `amx list`, recently-closed reducer, and Session Manager lifecycle groups remain the seams; no registry or new dependency is added.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing, SwiftPM, bundled Zig `amx` label protocol.

**Spec:** `docs/superpowers/specs/2026-09-21-session-manager-recovery-design.md`

## Global Constraints

- macOS 15+; preserve the native single-window workspace model.
- UUID daemon IDs remain immutable and remain the `amx attach` CLI argument.
- Extend the existing zmx attach command only with `--existing`; reuse `--labels`, `set`, `get`, and verbose `list`; do not add a dependency or parallel recovery registry.
- zmx labels accept only `[a-zA-Z0-9._-]`; encode user text as bounded, unpadded URL-safe Base64.
- `amx list --short` must remain ID-only and all existing tolerant/strict parser safety properties must remain intact.
- A disappeared or newly owned daemon fails recovery closed; recovery never starts a replacement shell under the old identity.
- A pre-label daemon is automatically recoverable only when its cwd proves a local execution plan; remote or ambiguous execution stays UUID-attachable but is not reconstructed with invented routing.
- Only stable user/synthetic titles become durable labels; live OSC title churn does not trigger label writes.
- Use literal-as-key `String(localized:)`; preserve icon-plus-text accessibility for lifecycle and actions.
- Modify only the zmx fork for the atomic attach contract; do not modify Ghostty.

## Review Focus

- A label decodes to oversized or malformed UTF-8: ignore only that field and keep the row/recovery usable.
- A metadata field changes from present to absent: emit `key=` for that known key so zmx removes the stale value.
- A daemon changes lifecycle between display and activation: re-list and refuse duplicate ownership or fresh-shell creation.
- A daemon vanishes after activation revalidation but before attach: `amx attach --existing` fails atomically and the provisional workspace is rolled back.
- A strict attach fails after a Detached snapshot produced a provisional workspace: rollback preserves the untouched snapshot, group, layout, and position.
- Two panes share the same workspace title and directory: append stable pane identity only where needed to distinguish rows.
- An original group ID exists but its name or remote target has changed: use the live group as authoritative rather than overwriting it from stale labels.
- Two asynchronous metadata snapshots finish out of order: serialize writes so the newest workspace state wins.
- The app starts with already-running pre-label daemons: show cwd/UUID fallbacks; recover proven-local daemons and refuse to invent remote routing.

## Recovery Flow

```text
amx list + SessionStore + reopen snapshots
                  |
                  v
       resolve current lifecycle and row
                  |
     +------------+-------------+
     |            |             |
   Owned       Detached    Abandoned/Expired
 exact pane   snapshot copy   one-pane candidate
                  \             /
                   v           v
               provisional workspace
                       |
              amx attach --existing
                 /             \
          attached event      failure/timeout
                |                    |
       drain entries by daemon   remove provisional
       establish/select/dismiss  preserve snapshot
```

---

### Task 1: Atomic attach-existing support in the zmx fork

**Files:**
- Modify: `vendor/zmx/src/main.zig`
- Modify: `vendor/zmx/src/loop.zig` only if the current `ensureSession` API cannot express no-create without duplicating socket probing
- Modify: `vendor/zmx/README.md`
- Test: existing Zig tests beside the changed parser/session code

**Interfaces:**
- Produces: `amx attach --existing <name>`, which attaches only to a responsive existing daemon and exits nonzero without creating or cleaning/replacing a socket when the daemon is absent or unresponsive.
- Consumes: the existing attach parser, session socket probe, and client loop.

- [ ] **Step 1: Write failing Zig tests for `--existing`**

Pin parsing before the session name and these behaviors: live daemon attaches; absent socket returns `SessionNotFound`; refused/stale socket returns an error without unlinking or forking; `--existing --labels` is rejected so recovery cannot become a competing metadata writer; ordinary `attach` retains create-or-replace behavior.

- [ ] **Step 2: Run the zmx tests and confirm they fail**

Run: `./script/test.sh zmx`

Expected: non-zero exit from missing `--existing` behavior.

- [ ] **Step 3: Implement the smallest no-create branch**

Add `existing_only: bool` to `AttachArgs`. The existing-only arm must never call `ensureSession`: probe the named socket once; on any missing/unresponsive result, print a bounded diagnostic and return nonzero without calling stale-socket cleanup or `run()`. When live, go directly to `sessionConnect` and the client loop. Keep normal attach unchanged.

- [ ] **Step 4: Run the zmx suite**

Run: `./script/test.sh zmx`

Expected: PASS.

- [ ] **Step 5: Commit and publish the fork change, then update the parent gitlink**

Commit the zmx change in the owned fork with `feat: add existing-only attach`, push its feature branch, and update only `vendor/zmx` in the parent repository. Because the currently supplied checkout already has unrelated submodule modifications, execution must begin from an isolated worktree with a clean initialized zmx submodule; never overwrite or absorb the user's present submodule state.

### Task 2: Recovery metadata and list parsing

**Files:**
- Create: `Sources/AwesoMuxCore/Models/DaemonRecoveryMetadata.swift`
- Modify: `Sources/AwesoMuxCore/Models/LiveDaemon.swift`
- Modify: `Sources/AwesoMuxCore/Models/DaemonRow.swift`
- Modify: `Sources/AwesoMuxCore/Services/DaemonGCPlan.swift`
- Modify: `Sources/AwesoMuxCore/Services/DaemonStateResolver.swift`
- Create: `Tests/AwesoMuxCoreTests/DaemonRecoveryMetadataTests.swift`
- Modify: `Tests/AwesoMuxCoreTests/DaemonGCPlanTests.swift`
- Modify: `Tests/AwesoMuxCoreTests/DaemonStateResolverTests.swift`

**Interfaces:**
- Produces: `DaemonRecoveryMetadata`, `DaemonRecoveryMetadata.encodedLabelAssignments`, `DaemonRecoveryMetadata.decode(fields:)`, `LiveDaemon.cwd`, `LiveDaemon.recoveryMetadata`, and the display fields on `DaemonRow`.
- Consumes: `TerminalSessionID`, `RemoteTarget`, `AgentKind`, and current tab-separated `amx list` fields.

- [ ] **Step 1: Add failing codec tests**

Cover Unicode titles, spaces, an optional remote target, deterministic unpadded URL-safe Base64, an invalid field beside valid fields, decoded values over the chosen 4 KiB per-field ceiling, and empty strings. `encodedLabelAssignments` must include every known key, using an empty value as zmx's removal tombstone for absent fields. Pin these signatures:

```swift
public struct DaemonRecoveryMetadata: Hashable, Sendable {
    public static let labelPrefix = "awesomux."
    public static let maximumDecodedFieldBytes = 4 * 1024

    public let workspaceTitle: String?
    public let paneTitle: String?
    public let groupID: UUID?
    public let groupName: String?
    public let groupRemote: RemoteTarget?
    public let agentKind: AgentKind?

    public var encodedLabelAssignments: [String: String] { get }
    public static func decode(fields: [String: String]) -> Self
}
```

- [ ] **Step 2: Run the codec test and confirm it fails**

Run: `./script/swift-test.sh --filter DaemonRecoveryMetadataTests`

Expected: non-zero exit because `DaemonRecoveryMetadata` does not exist; confirm the output reports at least one selected test rather than a zero-test success.

- [ ] **Step 3: Implement the bounded codec**

Use `Data.base64EncodedString()`, convert `+` to `-`, `/` to `_`, strip `=`, restore padding on decode, then require decoded byte count `<= maximumDecodedFieldBytes` and valid UTF-8. Encode `RemoteTarget` with a sorted-key `JSONEncoder`; decode through `JSONDecoder` so its existing typed validation remains the boundary. Do not introduce a generic serialization framework.

- [ ] **Step 4: Add failing parser and resolver tests**

First add a zmx `writeSessionLine` test that pins the live verbose grammar: current builds emit `cwd=`, older builds emitted `start_dir=`, and labels are tab-separated `key=value` fields. Then extend Swift fixtures with lines shaped like:

```text
name=<uuid>\tpid=123\tclients=0\tcreated=10\tcwd=/Users/eD/Development/awesomux\tawesomux.workspace-title=<encoded>\tawesomux.group-id=<encoded>\tdaemon_pid=99
```

Assert tolerant parsing retains a daemon with one malformed recovery label, strict parsing still rejects malformed built-in fields, older lines produce `nil` metadata, `cwd` is preferred while legacy `start_dir` remains a fallback, a missing directory field never drops a row, and row resolution prefers live owner data over snapshot data over daemon metadata over UUID fallback.

- [ ] **Step 5: Run the parser/resolver tests and confirm they fail**

Run: `./script/swift-test.sh --filter 'DaemonGCPlanTests|DaemonStateResolverTests'`

Expected: non-zero exit from missing `cwd`, metadata, or display fields; confirm a non-zero selected-test count.

- [ ] **Step 6: Extend the existing models and parser minimally**

Add:

```swift
public let cwd: String?
public let recoveryMetadata: DaemonRecoveryMetadata?
```

to `LiveDaemon`, with defaulted initializer parameters to avoid mechanical fixture churn. Add `label`, `directory`, `groupName`, `agentKind`, and `shortID` inputs to `DaemonRow`. In `DaemonGCPlan.parseAmxList`, keep the existing built-in-field gates, collect only `awesomux.` fields for the codec, and never let recovery-label failure drop a daemon. Update `DaemonStateResolver.Input` with live/snapshot presentation maps and apply the documented precedence.

- [ ] **Step 7: Run focused Core tests**

Run: `./script/swift-test.sh --filter 'DaemonRecoveryMetadataTests|DaemonGCPlanTests|DaemonStateResolverTests'`

Expected: PASS with non-zero counts for all three suites.

- [ ] **Step 8: Commit Task 2**

```bash
git add Sources/AwesoMuxCore/Models/DaemonRecoveryMetadata.swift Sources/AwesoMuxCore/Models/LiveDaemon.swift Sources/AwesoMuxCore/Models/DaemonRow.swift Sources/AwesoMuxCore/Services/DaemonGCPlan.swift Sources/AwesoMuxCore/Services/DaemonStateResolver.swift Tests/AwesoMuxCoreTests/DaemonRecoveryMetadataTests.swift Tests/AwesoMuxCoreTests/DaemonGCPlanTests.swift Tests/AwesoMuxCoreTests/DaemonStateResolverTests.swift
git commit -m "feat(session-manager): decode daemon recovery metadata"
```

### Task 3: Attach-time labels and mutation synchronization

**Files:**
- Modify: `Sources/AwesoMuxCore/Models/TerminalBackendMetadata.swift`
- Modify: `Tests/AwesoMuxCoreTests/TerminalBackendMetadataTests.swift`
- Modify: `Sources/awesoMux/Services/AmxBackend.swift`
- Modify: `Sources/awesoMux/Views/GhosttySurface/CommandBridgeEnactor.swift`
- Create: `Sources/awesoMux/Services/DaemonRecoveryMetadataSynchronizer.swift`
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift`
- Modify: `Tests/awesoMuxTests/AmxBackendTests.swift`
- Modify: `Tests/awesoMuxTests/CommandBridgeEnactorTests.swift`
- Create: `Tests/awesoMuxTests/DaemonRecoveryMetadataSynchronizerTests.swift`

**Interfaces:**
- Consumes: `DaemonRecoveryMetadata.encodedLabelAssignments` from Task 2 and the current `SessionStore.groups` snapshot.
- Produces: `AmxBackend.attachCommand(..., mode:)`, `AmxBackend.setRecoveryMetadata(_:for:)`, and `DaemonRecoveryMetadataSynchronizer.synchronize(groups:)`.

- [ ] **Step 1: Add failing attach-command tests**

Assert a create-capable local command places every known label assignment before the session name, quotes one joined `key=value` argument, preserves all environment scrubbing, and applies labels to the local outer daemon for an SSH-backed pane. Assert an existing-only command uses `attach --existing <uuid>` with no labels:

```swift
AmxBackend.attachCommand(
    executablePath: "/App/amx",
    sessionID: id,
    socketDirectory: "/tmp/amx",
    mode: .createOrAttach(metadata: metadata)
)

AmxBackend.attachCommand(
    executablePath: "/App/amx",
    sessionID: id,
    socketDirectory: "/tmp/amx",
    mode: .existingOnly
)
```

Expected create ordering: `amx attach --labels '<sorted pairs, including key= tombstones>' '<uuid>'`. Expected recovery ordering: `amx attach --existing '<uuid>'`.

- [ ] **Step 2: Run attach tests and confirm they fail**

Run: `./script/swift-test.sh --filter AmxBackendTests`

Expected: compile failure for the missing `recoveryMetadata` parameter; confirm the selected suite is non-zero.

- [ ] **Step 3: Thread metadata through the existing attach seam**

Add `AmxAttachMode` (`createOrAttach(metadata:)` / `existingOnly`) as a required input to both testable and bundle-resolving `attachCommand` overloads and to `CommandBridgeEnactor.prepareAttach`. The availability probe and real launch must use the same mode. A genuinely new or healed pane uses create-or-attach with current labels; a restore/recovery pane carries a typed existing-only marker in validated `TerminalBackendMetadata` and emits no labels from the attach process. Keep remote-owned sessions excluded because no local amx daemon exists for them. Give the marker an explicit raw wire value alongside legacy `amx:v1:established`: legacy established decodes as established, existing-only decodes distinctly, and unknown amx metadata fails closed to existing-only rather than authorizing creation. Transition one-shot existing-only to established only after the status channel confirms attachment, and test the existing death/heal path for both states. Ambiguous pre-label remote recovery is refused rather than assigned a durable back door.

- [ ] **Step 4: Add failing synchronizer tests**

Inject an async writer closure and verify:

```swift
@MainActor
final class DaemonRecoveryMetadataSynchronizer {
    init(write: @escaping @Sendable (TerminalSessionID, DaemonRecoveryMetadata) async -> Bool)
    func synchronize(groups: [SessionGroup]) async
}
```

Test first snapshot writes every local or local-amx-SSH daemon, per-ID successful-value cache hits write nothing, rename/move/group-retarget writes only affected daemons, remote-to-local retarget sends an empty `awesomux.group-remote=` assignment, removed panes do not clear daemon labels, remote-owned panes are skipped by `persistenceOwner` rather than by `remoteTarget`, a failed write is retried on the next synchronization, a delayed older write cannot overwrite a newer snapshot, and successful A → invalidate ID for a new incarnation → synchronize identical A writes again.

- [ ] **Step 5: Implement the amx writer and diff-aware synchronizer**

`AmxBackend.setRecoveryMetadata` must use `BoundedCommandRunner`, the profile-scoped environment, arguments `set <uuid> <sorted key=value pairs>`, the existing two-second timeout, and no shell. Send all known keys on each write so empty assignments remove stale values without touching unrelated user labels. Serialize snapshot application inside the synchronizer; coalesce pending snapshots to the newest generation rather than starting overlapping writers. Skipping is only a per-ID successful-value cache hit, never whole-snapshot equality. Cache only successful values by `TerminalSessionID`; remove absent IDs from the in-memory cache without clearing their daemon labels. Invalidating an ID increments its generation so the replacement write cannot merge into a pre-invalidation in-flight write; immediately synchronize current store metadata on every new daemon incarnation/confirmed create attach, so heal-created daemons cannot remain unlabeled after an identical workspace snapshot.

- [ ] **Step 6: Wire synchronization to the existing store-change chokepoint**

In `AwesoMuxApp`'s existing `.onChange(of: sessionStore.groups)`, submit an immutable group snapshot to one app-owned synchronizer. Also perform one initial synchronization after restore/launch so already-running owned daemons are upgraded. Do not add calls to every rename/move method and do not synchronize display-only live-title writes that deliberately bypass `groups` publication.

- [ ] **Step 7: Run transport and synchronization tests**

Run: `./script/swift-test.sh --filter 'AmxBackendTests|CommandBridgeEnactorTests|DaemonRecoveryMetadataSynchronizerTests'`

Expected: PASS with non-zero counts.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/AwesoMuxCore/Models/TerminalBackendMetadata.swift Tests/AwesoMuxCoreTests/TerminalBackendMetadataTests.swift Sources/awesoMux/Services/AmxBackend.swift Sources/awesoMux/Views/GhosttySurface/CommandBridgeEnactor.swift Sources/awesoMux/Services/DaemonRecoveryMetadataSynchronizer.swift Sources/awesoMux/App/AwesoMuxApp.swift Tests/awesoMuxTests/AmxBackendTests.swift Tests/awesoMuxTests/CommandBridgeEnactorTests.swift Tests/awesoMuxTests/DaemonRecoveryMetadataSynchronizerTests.swift
git commit -m "feat(amx): persist session recovery labels"
```

### Task 4: Guarded restore and abandoned recovery

**Files:**
- Modify: `Sources/AwesoMuxCore/Stores/SessionStore.swift`
- Modify: `Sources/AwesoMuxCore/Stores/SessionStore+Facade.swift`
- Create: `Sources/AwesoMuxCore/Stores/DaemonRecoveryReducer.swift`
- Create: `Tests/AwesoMuxCoreTests/DaemonRecoveryReducerTests.swift`
- Modify: `Tests/AwesoMuxCoreTests/SessionStoreTests.swift`
- Modify: `Sources/awesoMux/Services/SessionManagerModel.swift`
- Modify: `Sources/awesoMux/Views/GhosttySurface/CommandBridgeEnactor.swift`
- Create: `Tests/awesoMuxTests/SessionManagerModelRecoveryTests.swift`

**Interfaces:**
- Consumes: revalidated `LiveDaemon`, `DaemonRecoveryMetadata`, cwd, and existing `RecentlyClosedWorkspace` entries.
- Produces: `SessionStore.recentlyClosedWorkspace(containing:)`, `SessionStore.recoverDaemon(id:metadata:cwd:)`, and `SessionManagerModel.activate(_:)`.

- [ ] **Step 1: Add failing pure-reducer tests**

Pin the recovery input and result:

```swift
struct DaemonRecoveryRequest: Sendable {
    let id: TerminalSessionID
    let metadata: DaemonRecoveryMetadata
    let cwd: String?
}

enum DaemonRecoveryReducer {
    static func recover(
        _ request: DaemonRecoveryRequest,
        into groups: inout [SessionGroup]
    ) -> TerminalSession.ID?
}
```

Test insertion into the matching live group, recreation of a missing group with the stored ID/name/remote target, live-group authority when stale metadata disagrees, disambiguation when the missing group's old name now belongs to another group, `Recovered Sessions` fallback, cwd-derived naming for unlabeled local daemons, refusal for unlabeled remote or ambiguous cwd values, preservation of the exact `TerminalSessionID`, and refusal when that daemon ID is already owned by any pane.

- [ ] **Step 2: Run reducer tests and confirm they fail**

Run: `./script/swift-test.sh --filter DaemonRecoveryReducerTests`

Expected: non-zero exit because the reducer does not exist.

- [ ] **Step 3: Implement the one-pane recovery reducer**

Reuse current `SessionGroup`, `TerminalSession`, `TerminalPane`, `PaneExecutionPlan`, and synthetic-title constructors. Construct `TerminalPane(terminalSessionID: request.id, ...)` directly; `addSession` and `addSSHSession` are forbidden on recovery because they mint a different daemon ID. Reconstruct a local-amx-SSH plan from validated `groupRemote` with no `remoteSessionName`; remote-owned panes have no local daemon row and are never recovered here. For a pre-label local candidate, require the bounded path to pass the same filesystem validation as `WorkingDirectoryValidator.validatedStartupDirectory`; an absolute path that does not exist locally is ambiguous and not auto-recovered. Keep directory fields optional in list parsing. A missing group ID plus colliding name uses the existing reopen disambiguation rule rather than folding into the namesake. Check all panes for an existing terminal ID before mutation and build candidate groups without touching either reopen tier; the store transaction owns provisional publication and later drain.

- [ ] **Step 4: Add failing store and model activation tests**

Test targeted lookup of a recently-closed entry containing a daemon; provisional Detached activation that leaves its reopen entry intact until confirmation; Abandoned/Expired activation after a fresh list still reports the same PID/creation epoch and `clients == 0`; lifecycle redirection when a stale Abandoned row is now Owned, Detached, or Elsewhere; refusal when the daemon vanished, incarnation changed, gained an unowned client, or lacks enough execution metadata; successful attach draining every reopen entry containing the daemon; failed attach removing the provisional workspace without capturing a new entry and preserving the original snapshot; recovery followed by Reopen Closed Workspace remaining a no-op; and successful recovery selecting the resulting workspace and exact pane.

Use one result enum so the UI does not infer errors from booleans:

```swift
enum SessionManagerActivationResult: Equatable {
    case opened(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
    case restored(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
    case recovered(sessionID: TerminalSession.ID, paneID: TerminalPane.ID)
    case unavailable
    case changed
}

struct SessionRecoveryToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case restore, recover }
    let kind: Kind
    let daemonID: TerminalSessionID
    let sessionID: TerminalSession.ID
    let paneID: TerminalPane.ID
}

func activate(_ row: DaemonRow) async -> SessionManagerActivationResult
```

- [ ] **Step 5: Implement store façades and fresh activation guard**

Re-list and recompute reachability, then derive the lifecycle again instead of trusting the clicked row: Owned opens the exact owning pane; Detached builds a provisional workspace from the exact `RecentlyClosedWorkspace` without draining it; Abandoned/Expired compare ID, shell PID, daemon PID when known, creation epoch, and `clients` before building a provisional one-pane workspace; Elsewhere returns `.changed`. Restore/Recover mark every target terminal pane existing-only and create an internal `SessionRecoveryToken` containing daemon ID, provisional session/pane IDs, kind, and source entry identity when present. `activate` awaits the existing status channel's confirmed `attached` event or a bounded timeout; the token is an internal coordinator/test handle, never a UI-facing result. Confirmation atomically drains both reopen tiers by daemon ID, transitions backend metadata to established, and returns `.restored` or `.recovered`; failure or timeout removes the provisional workspace with `captureRecentlyClosed: false`, keeps the original tiers untouched, and returns `.unavailable`. Never call `forgetRecentlyClosed` with the new workspace UUID.

- [ ] **Step 6: Run recovery tests**

Run: `./script/swift-test.sh --filter 'DaemonRecoveryReducerTests|SessionStoreTests|SessionManagerModelRecoveryTests'`

Expected: PASS with non-zero counts.

- [ ] **Step 7: Commit Task 4**

```bash
git add Sources/AwesoMuxCore/Stores/DaemonRecoveryReducer.swift Sources/AwesoMuxCore/Stores/SessionStore.swift Sources/AwesoMuxCore/Stores/SessionStore+Facade.swift Sources/awesoMux/Services/SessionManagerModel.swift Sources/awesoMux/Views/GhosttySurface/CommandBridgeEnactor.swift Tests/AwesoMuxCoreTests/DaemonRecoveryReducerTests.swift Tests/AwesoMuxCoreTests/SessionStoreTests.swift Tests/awesoMuxTests/SessionManagerModelRecoveryTests.swift
git commit -m "feat(session-manager): recover detached amx sessions"
```

### Task 5: Human-readable Session Manager rows

**Files:**
- Modify: `Sources/awesoMux/Views/SessionManagerPanel.swift`
- Modify: `Sources/awesoMux/Services/SessionManagerController.swift`
- Modify: `Sources/awesoMux/App/AwesoMuxApp.swift`
- Create: `Tests/awesoMuxTests/SessionManagerPresentationTests.swift`
- Modify: `Tests/awesoMuxTests/SessionManagerControllerTests.swift`

**Interfaces:**
- Consumes: enriched `DaemonRow` and `SessionManagerModel.activate(_:)` from Tasks 2 and 4.
- Produces: lifecycle-specific Open/Restore/Recover actions, search/filter, and accessible row presentation.

- [ ] **Step 1: Add failing presentation tests**

Extract only pure presentation decisions, not a view-model hierarchy:

```swift
enum SessionManagerPrimaryAction: Equatable {
    case open, restore, recover
}

extension DaemonRow {
    var primaryAction: SessionManagerPrimaryAction? { get }
    func matches(query: String) -> Bool
    var accessibilitySummary: String { get }
}
```

Test every lifecycle, case/diacritic-insensitive matching across label/group/cwd/agent/full UUID, duplicate workspace labels distinguished by pane title, pre-label UUID/cwd fallback, and complete accessibility copy.

- [ ] **Step 2: Run presentation tests and confirm they fail**

Run: `./script/swift-test.sh --filter SessionManagerPresentationTests`

Expected: compile failure for missing presentation properties.

- [ ] **Step 3: Replace UUID-first rows with the approved hierarchy**

Render Activity, Session Label, Directory, Age, Clients, Actions. Keep the short UUID as subdued secondary detail or row help rather than the main column. Add a native search field only when there are rows; filtering never changes lifecycle classification. Preserve the existing lifecycle headers, pin control, confirmation surfaces, footer, colors, and panel chrome.

- [ ] **Step 4: Wire lifecycle actions and feedback**

Owned invokes Open, Detached invokes Restore, Abandoned/Expired invoke Recover, and Elsewhere has no primary action. Return triggers the row's available primary action. Thread `TerminalPane.ID` through `jumpTarget`, controller callbacks, and app selection; call the existing active-pane selection path before requesting focus. Success selects the exact pane/workspace, dismisses, and posts a specific VoiceOver announcement. `.unavailable` and `.changed` leave the panel open, refresh rows, retain focus when the row survives, and show localized inline status rather than silently doing nothing.

- [ ] **Step 5: Add controller tests for dismissal and failure retention**

Verify success dismisses only after the selection callback, failure does not dismiss, and repeated activation is ignored while one activation task is in flight.

- [ ] **Step 6: Format changed Swift files and run UI-focused tests**

```bash
./script/format.sh Sources/awesoMux/Views/SessionManagerPanel.swift Sources/awesoMux/Services/SessionManagerController.swift Sources/awesoMux/App/AwesoMuxApp.swift
./script/swift-test.sh --filter 'SessionManagerPresentationTests|SessionManagerControllerTests|SessionManagerModelRecoveryTests'
```

Expected: formatter succeeds; every selected suite reports a non-zero count and PASS.

- [ ] **Step 7: Commit Task 5**

```bash
git add Sources/awesoMux/Views/SessionManagerPanel.swift Sources/awesoMux/Services/SessionManagerController.swift Sources/awesoMux/App/AwesoMuxApp.swift Tests/awesoMuxTests/SessionManagerPresentationTests.swift Tests/awesoMuxTests/SessionManagerControllerTests.swift
git commit -m "feat(session-manager): identify and recover sessions"
```

### Task 6: Documentation and end-to-end verification

**Files:**
- Modify: `docs/amx-automation.md`
- Modify: `docs/architecture.md`
- Modify: `docs/testing/command-bridge-default-on-smoke.md`

**Interfaces:**
- Consumes: final shipped commands and UI behavior from Tasks 1-5.
- Produces: accurate CLI and manual recovery documentation.

- [ ] **Step 1: Document the verbose list and recovery contract**

Add a concise example showing `name`, `cwd`, and `awesomux.*` labels; state that values are app-encoded recovery metadata, `amx get` is the inspection surface, and `--short` remains ID-only. Document Open/Restore/Recover and the one-pane ceiling for abandoned sessions.

- [ ] **Step 2: Extend the command-bridge smoke checklist**

Add manual cases for duplicate workspace names, multiple panes, user/group rename, move between groups, deleted-group recreation, pre-label daemon fallback, vanished-daemon race, another-client race, preserved scrollback, keyboard Return, VoiceOver row/action announcements, and long Unicode titles/paths.

- [ ] **Step 3: Run focused and full local validation**

```bash
./script/format.sh --lint
./script/test.sh all
./script/preflight.sh
```

Expected: all commands exit 0. Run `preflight.sh` directly, never through a pipe, and report any paid native CI as not run; do not trigger it.

- [ ] **Step 4: Run one bounded manual macOS pass**

Build and run with `./script/build_and_run.sh`. Create two same-folder workspaces and one split; rename and move one; close one into Detached; manufacture one Abandoned daemon using the documented development-profile CLI; verify labels/cwd in verbose `amx list`; Open, Restore, and Recover; confirm exact daemon ID and scrollback survive. Exercise keyboard and VoiceOver, capture one final screenshot, fix findings in one batch, and perform at most one confirmation pass.

- [ ] **Step 5: Run the required review gates on the final contribution scope**

Run full specialist-panel coverage and an independent adversarial review with explicit adapter/model identities. Because Claude is currently unavailable, use Cursor CLI with an explicit available model for the reciprocal adversarial lane. Fix blocking findings, rerun affected tests, and refresh every review lane whose assumptions or files changed. Preserve the reports and commit-bound evidence required by `hooks/pr-review-gate.md`; do not trigger paid native CI.

- [ ] **Step 6: Commit Task 6**

```bash
git add docs/amx-automation.md docs/architecture.md docs/testing/command-bridge-default-on-smoke.md
git commit -m "docs(session-manager): document daemon recovery"
```

- [ ] **Step 7: Inspect final scope**

Run `git diff --check <base>...HEAD`, inspect `git diff --stat <base>...HEAD`, then read the exact diff. Confirm the zmx gitlink changed only to the reviewed Task 1 fork commit, the Ghostty gitlink did not change, and no unrelated file is staged.
