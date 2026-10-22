# Recent scrollback verification

Issue #582 extends the existing Pane > Show Scrollback sheet, not a document,
provider transcript, export file, or history recorder. This recipe is written
before the production change. It has not been executed. Source-only work cannot
establish a failing native baseline, tests-first execution, or responsiveness.

## Failure model and independent oracles

- A full-history read followed by a suffix still scans/decompresses 64 MB.
  Inspect native page visits and decompressed backing bytes: traversal must start
  at the last page and stop at the admission limits without visiting older pages.
- Cached scrollbar rows can be stale during synchronized output. Admission and
  formatting must use one live terminal snapshot under the renderer mutex.
- Byte clipping can split UTF-8, a wide cell, a combining sequence, or a ZWJ
  grapheme. Compare the shown suffix to complete fixture rows; never decode a
  failed fixed writer's partial output. A single row beyond the output limit
  must fail explicitly rather than show its prefix as recent output.
- Compressed size understates decode cost. Charge full page backing capacity
  before formatting, including a partly selected page. Older excluded pages
  must remain compressed. Record storage states before and after opening.
- Dismissal, surface replacement, reload, and continuous output can race reads.
  Verify a dismissed/replaced request never updates another pane or a reopened
  sheet; frees/reloads must wait until the native worker has returned.
- Copy must use the immutable terminal text displayed by that request, including
  whitespace and newlines. Compare UTF-8 clipboard bytes with the actual text
  view's full string, not a second live terminal read. The omission notice is
  sheet chrome and is excluded from both text view and clipboard.
- Bound native work and text layout independently. Capture main-thread stalls,
  renderer-lock hold time, peak memory and steady state, not just worker time.
- A modal sheet must support Return, Escape, selection and copy; dismissal must
  restore focus to the originating terminal. VoiceOver must read the omission
  notice and selectable text, and announce completion/cancellation correctly.

## Serialized native run (coordinator owned)

Do not run while the console is locked (`IOConsoleLocked=true`). Do not unlock,
change TCC/settings, or drive an existing user app. Wrap the entire build,
isolated launch, interactions, artifact capture, and owned-process cleanup in
one coordinator build-slot job. The wrapper is external to this repository;
follow the assignment's current wrapper path. Never acquire it recursively.

Use the existing `script/build_and_run.sh` launch/staging workflow and its
worktree profile identity. Record the base/head, overlay hashes, binary hash,
bundle identifier, PID, config, dimensions and the exact pane/session IDs.
Preserve existing profile data and user processes. Use the existing launched-app
menu/AX harness when integrated; this source base has no #375 harness yet.
Use `AWESOMUX_AMX` and the explicit `ZMX_SESSION` only as documented in
[amx automation](../amx-automation.md) for fixture input in the isolated pane.
`amx history` is a different terminal and is not proof of the app's native read.

1. Baseline on the unchanged base: fill an 80-column pane using
   `python3 /absolute/checkout/script/recent-scrollback-e2e/fixture.py`.
   The fixture emits bounded synthetic output only. Its byte counter measures
   emitted UTF-8, not Ghostty backing capacity. Verify actual native retained
   backing is at the configured 64,000,000-byte history limit (allow normal
   page-boundary slack); record metadata under the renderer lock. Confirm the
   old Show Scrollback blocks, and retain the screenshot/log.
2. Repeat on the overlay. Open Show Scrollback without first opening Find.
   Require useful text containing the final fixture marker and an explicit
   older-output notice. Verify the old marker is absent. Record total retained
   rows/backing versus selected rows/cells/backing, output bytes, page visits,
   timings and screenshots. Output must not exceed 262,144 bytes, rows 8,192,
   cells 262,144, or admitted page backing 16 MiB. Capture Instruments/Time
   Profiler or equivalent main-thread/lock measurements and process memory
   before/during/after. Do not infer latency or RSS from those static limits.
3. Run `--kind unicode` with compression enabled and idle for an actual idle
   compression pass. Confirm at least one selected cold page is compressed
   before opening. Check combining, CJK, emoji/ZWJ text and wrapped lines;
   no replacement character or broken fixture grapheme may appear. Confirm
   excluded older compressed pages were not restored. Repeat compression off.
4. For exact byte edges, resize to a fixed column count and use `--kind ascii`
   and `--kind unicode`. Capture the actual formatter length for a bounded
   snapshot; exercise native capacities at that length and one byte less using
   the existing native diagnostic/debugger surface, without adding a unit suite.
   Exact fit succeeds; overflow retries a shorter suffix at row boundaries or
   rejects a single oversized row, never returns a partial prefix. Also seed a
   row with a large combining grapheme up to the native page cap and check an
   oversized last row fails safely. Retain debugger commands and output.
5. Run `--follow-seconds 60`. Open, copy, dismiss, reopen, and replace/close the
   originating pane while output changes. Capture UI and worker completion
   order. Exercise cancellation before scheduling, during lock wait and during
   extraction; check no late sheet, stale text or use-after-free. Retry while
   the old native read owns the surface: it may show the existing busy state.
6. Compare Copy's UTF-8 bytes against AX/debugger extraction of the text view's
   string, preserving trailing spaces/newlines; save both synthetic artifacts
   and their hashes. Change the live terminal after opening and copy again:
   clipboard must remain equal to the same immutable snapshot. Check empty and
   failed reads leave Copy disabled. Keep omission chrome outside the payload.
7. Verify Return/Escape, Tab order, text selection, Cmd-C, focus restoration,
   resize, enlarged text, primary window and floating panel. With actual
   VoiceOver speech, verify omission/completion/cancellation and text access;
   an AX tree alone is not speech proof. Keep terminal-history AX #523 separate.
8. Check local shell and authorized managed/unmanaged SSH panes without new
   fetches, transcript fallback, permissions or side-channel content. Inspect
   the explicit target pane in a split, not merely the selected workspace.
   Confirm the local-agent API still uses the original complete-read limits
   and consent/stale-target checks.
9. Run existing suites, native Ghostty regressions, catalog regeneration,
   changed-file formatting and full preflight in the coordinator's serialized
   queue. Capture nonzero executed test counts, raw exit statuses and artifacts.
   Stop only processes/daemons created by this run and restore owned fixtures.

Save a report with measured values and pass/fail per step. A prerequisite block
stays unverified. Fresh independent source review precedes readiness claims.
