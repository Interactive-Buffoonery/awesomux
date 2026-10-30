# Current-project transcript browser (#387)

## Failure model recorded before implementation

The browser must not confuse a project directory with a provider session identity.
The explicit browser uses the active local terminal's exact canonical working
directory as its project scope. It does not merge sibling worktrees, parent
repositories, or descendant directories. Open Agent Transcript and Resume remain
exact-session commands (ADR-0033); neither gains a cwd fallback.

Failure modes and native E2E oracles:

- Other-project or slug-collision metadata: only entries whose probed cwd equals
  the selected directory appear. SSH and missing local directories refuse.
- Codex fork-family collision: two payload.id values sharing session_id remain
  two rows. Duplicate ThreadIds select conversation content, then larger size,
  then modification time. A newer metadata-only sidecar must lose.
- Child noise: Codex source.subagent / parent_thread_id and Claude sidechains
  must not appear as top-level rows.
- Hostile storage: final-file and enumerated-directory symlinks, wrong owners, malformed/oversize
  metadata and mismatched filename/session ids never produce openable rows.
- Traversal, reads, retained metadata and rendered content have independent caps.
  A capped/failed scan says it is incomplete, rather than claiming completeness.
- Cancel, refresh, pane close, directory change, execution-location change,
  integration-home change and selection change cannot land stale results.
- Files may vanish, rotate or change between listing and opening. Revalidate
  both source identity and project metadata before using the existing renderer.
- Browsing creates no rendered artifacts. Opening uses typed provenance,
  owner-only cache writes and the same complete-write/prune path on success,
  stale completion and failure to attach a tab.

## Coordinator-owned native acceptance (not yet run)

No native reproduction or test-first result is claimed: the prior handoff reports a locked console,
and the coordinator owns the sole heavy-validation queue. Do not unlock or change TCC.
Use the existing native menu/AX harness on an isolated linked-worktree build.
Keep launch, all interactions, screenshots/logs and cleanup within one coordinator
`build_slot.py` invocation. Never terminate another app instance.

1. Run `python3 script/project-transcripts-e2e/fixture.py /absolute/disposable/root`.
   This creates only synthetic transcripts and prints fixture paths. In the
   isolated profile set Claude Code and Codex Config home to the printed homes.
   Open a local terminal in the printed project directory. Save the fixture
   manifest and tested source hashes with the native report.
2. Before applying the overlay, record that Workspace and the palette have no
   Browse Project Transcripts command. After applying it, invoke the new command
   through both entry points. Capture the native list and accessibility tree.
3. Expect one Claude row and four Codex rows: the duplicate thread once and the
   two distinct family members, plus the large-first-record history. No other-project, child, symlink, or incomplete
   metadata row may appear. Rows show provider, exact id, and modification date;
   the list never displays prompt/tool content. Keyboard selection, Return/Open,
   Escape/Cancel, Refresh and VoiceOver list/status announcements must work.
4. Open the duplicate row. Capture the document containing
   `DUPLICATE_CONVERSATION_WINS`, exactly once, and no sidecar marker. Open the
   Claude row and both family rows, verifying their distinct synthetic markers.
   Keep the duplicate tab selected through its initial live refresh and an
   append. Add a smaller, newer conversation-bearing duplicate of the same id;
   the larger conversation must remain selected by exact-id rediscovery too.
   Existing rendered documents must remain read-only and retain exact Resume
   identity. Verify Resume only stages its exact command at a verified shell
   prompt; an unrelated pane without a session id still gets no cwd fallback.
5. List project B; its Claude duplicate and two Codex rows appear, as listed in
   the fixture manifest. Repeat from a sibling directory, a
   descendant directory, an SSH pane and a missing cwd. Change project or close
   the initiating pane while scanning/rendering; no old result/document appears
   in the replacement workspace. Change a configured provider home mid-scan.
6. While the list is open, remove a listed file or replace it with a symlink;
   Open must refuse, with no document/cache orphan. Refresh sees the new state.
   Refresh/cancel repeatedly during scanning. Add enough synthetic files to hit
   the entry/probe caps; capture the incomplete-results notice and responsive UI.
7. Capture cache modes (directory 0700, documents 0600), reference sets and prune
   results after opens, tab/workspace close, recently-closed retention, restore,
   and stale opens. Browsing alone must not add artifacts. Reopening the same
   identity and project constraint must reuse its cache slot; exact-id, A and B
   browser identities must have separate slots. Inspect no user transcript contents.
8. Capture normal/enlarged text and VoiceOver outcomes separately. Retain a
   recording or screenshots, AX tree, action log, source manifest, bundle/profile
   identity, process cleanup receipt, and exact expected/observed rows/markers.

Heavy phase: run changed-file formatting, catalog extraction/review, existing
appropriate suites and `./script/preflight.sh` under the serialized slot. The
source phase does not execute Swift, Zig, Xcode, preparation, formatting, tests,
preflight, app automation, or commit hooks. No unit tests are added.

## Source design and limits

Only Claude Code and Codex join this explicit browser. Claude traversal stays in
one slug directory; metadata cwd equality also rejects slug collisions. Codex
traversal stays under its configured `sessions` root and descends only three
numeric date directories. Per provider the scan visits at most 8,192 entries and
probes at most 1,024 files, each for at most 64 KiB (at most 128 MiB across both
providers). It retains at most 2,048 metadata entries before dedup/sort, and
returns at most 100. Date ordering applies to the inspected subset when a cap is
hit; the UI marks such results as limited. No index, polling, global project
walk, prompt preview, artifact generation during listing, or provider framework
is introduced. Missing/malformed cwd metadata never becomes project authority.

## Round 2 failure model and bounded repair plan (before production repair)

This section was saved before round 2 production edits. No runtime reproduction,
Swift check, fixture execution, or fail-before-fix test has run. The coordinator
owns all heavy/native work and a full fresh review of the provenance repair.

A. A Claude parent may contain inline sidechain records (the existing renderer's
tri-state fixture establishes this supported shape). Derive parent id, cwd and
conversation evidence only from primary records; ignore inline child metadata,
including a different child id/cwd. A child-only file remains excluded. Exercise
mixed parent/child records both before listing and appended before Open.

B. Browser provenance must remain live and project-scoped through first mount,
pinning, append, source rotation, rediscovery and restore. Plan: add one optional
canonical project-directory constraint to the existing typed transcript identity.
Only browser-created Claude/Codex identities set it. Missing key decodes as the
legacy exact-session identity; malformed/present-null constraints must not silently
become unconstrained identities. Existing tolerant DocumentPane decode may discard
invalid identity while retaining generated ownership/read-only state. Decode must
validate lexical local path shape without doing filesystem I/O or changing a
saved path when an alias later moves. Resume continues using provider/session id.

Use existing bounded browser metadata admission for constrained exact-id
rediscovery and every pinned-file reopen: same project, payload/filename id,
non-child status, descriptor owner/regular-file and inode rules. Initial discovery
may establish a pin again, but may never use the global exact-id candidate set.
A runtime-only seeded pin is insufficient. Source rotation to another valid file
for the same project/id stays supported; B/child replacements fail admission.

Cache identity must include this optional project constraint, with a distinct
length-prefixed domain/fields for browser artifacts. Generic exact Open/refresh
and project A/B browser tabs must never write one another's slot. Legacy exact
cache keys stay byte-for-byte unchanged. Multiple active/restored tabs of the
same constrained identity intentionally share the same live source selection;
they may render the same source at different instants, as exact tabs already do.
Keep existing cache locks/gates/leases and live/recently-closed URL references;
no new cache manager, provider framework or point-in-time snapshot policy.

C. Codex prefix evidence must follow the renderer's existing accepted record
contract, including its system/developer, unsupported-kind and harness-only user
exclusions. Reuse a small renderer-owned classifier rather than changing rendering
semantics. Both browser and exact importer use it; Claude/Pi classification stays
unchanged. Keep 64 KiB browser / 256 KiB importer caps. No accepted record in a
prefix means no positive evidence, not proof that the whole file is empty; retain
size ranking for ties. Fixture: metadata plus >256 KiB setup first record and real
history afterward versus small system/developer/unsupported/event-only sidecars.

D. Reuse the visible localized incomplete-results sentence in the single scan
completion announcement for empty and nonempty lists, preserving normal cues.
No duplicate status announcement or newly invented copy; actual VO remains queued.

E. The issue requires bounded project admission, not a new all-ancestor symlink
ban. Preserve deliberate configured-home/intermediate alias resolution inherited
from SecureFileReader. Reject observed final-root/final-file and enumerated
symlinks as currently implemented; canonical intermediate aliases are admitted
only with regular-file ownership, canonical project cwd and filename/id metadata.
This corrects the earlier overbroad recipe promise; it does not establish a
cross-UID exploit or descriptor-relative directory security guarantee. Add a
canonical intermediate alias fixture with both matching and wrong-project metadata.

### Additional synthetic native acceptance (unexecuted)

- Mixed Claude parent with inline child id/cwd B: parent appears and opens; only
  child-only id is hidden. Renderer still labels inline child text normally.
- Same provider/id in A and larger B: A's marker persists through initial mount,
  append, inactivity/reactivation, rename/replacement/recovery, close/reopen and
  process restore. Open exact id and browser B concurrently in separate active
  groups/windows as supported; record distinct cache URLs and no marker crossover.
  Repeat with restored/recently-closed tabs. Same-inode edits to cwd/id/child
  metadata must fail refresh admission. Valid A source rotation still recovers.
- Setup-only duplicate versus large-first-record history: real history wins
  initial browser open and exact importer; system/developer/unsupported/event-only
  sidecars never gain positive conversation evidence. Harness-only user records
  must also agree with the renderer. Capture prefix limits separately from the
  rendered tail; absence of prefix evidence is not full-file absence.
- Persisted legacy identity (no constraint) still follows exact-session behavior.
  Malformed/null/nonlocal/oversize browser constraint remains read-only with no
  unconstrained automatic refresh. No new snapshot version or migration scan.
- Canonical intermediate `projects` alias: matching A metadata admitted,
  wrong-project/id/child-only data excluded; final file/enumerated directory
  symlinks refused. Configured home alias remains supported. No all-ancestor
  refusal or race-proof directory claim.
- Nonempty capped and empty incomplete scans each speak their normal result cue
  followed by the visible limitation sentence in one completion announcement.
  Capture actual VoiceOver speech separately from AX and screenshots.
