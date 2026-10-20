# Test audit (October 2026)

This audit covers every Swift Testing suite under `Tests/`. It follows the
[testing guide](../testing.md) and the earlier culls in #832 and #833. Each
suite gets one verdict:

- **keep**: guards a real past regression, a security or parsing boundary, or
  behavior no E2E journey covers.
- **delete**: restates the implementation, is a trivial getter, a dead seam, a
  self-test of a helper, or has no consumers.
- **merge**: overlaps another case closely enough to fold into it.
- **review**: a borderline call left for a maintainer.

`(done)` marks a change this audit made. Rows marked `keep` with no other note
were unchanged.

## Summary

| Outcome | Suites |
| --- | --- |
| keep | 230 |
| keep, with cases merged (done) | 6 |
| keep, with a case or helper deleted (done) | 3 |
| delete (done) | 4 |
| review | 8 |

Changes made:

- Deleted `TestData.swift` (no consumers), `WorkspaceLeafOperationsTests`
  (trivial lookup), `SessionManagerPresentationTests` (copies the
  `DaemonRow.primaryAction` switch), and `AmxBackendAttachCommandStatusTests`
  (the executable `status` row of `attachCommandPreservesShellArguments`
  already checks the same thing through a real shell).
- Removed the unused `TerminalSession.staleAgentActivityThreshold` alias and
  `RenderRecorder.beganAndCount()`, one duplicate `URLClassifierTests` row, and
  `AgentHookCommandTests.missingEventFileEnvironmentWritesNothing` (covered by
  `AgentHookHealthCheckTests.diagnosticFailure(kind: "hook")`).
- Merged overlapping cases in `BridgeFrameReaderTests`,
  `BridgePendingRequestMapTests`, `ManagedSSHObservationLivenessTests`,
  `PlanAnnotationMarkerTests`, `SessionRestoreReducerTests`, and
  `SessionStoreWorkspaceGroupTests`. Every assertion from a merged case
  survives in its new home.

No suite named in the `script/test.sh` shard patterns was emptied.

## Review items

- `GhosttyConfigEnvironmentTests.logFieldsContainsNoPII`: checks copied
  formatting and paths the instance never received. Decide whether the log
  field names are a supported diagnostics contract before deleting.
- `BranchChangesIdentityTests.longSharedPrefixesStayDistinct`: the
  `hashValue` inequality assertion isn't a `Hashable` guarantee. Keep the
  identity and display assertions.
- `PaneChangeClassificationTests.classificationCoversEveryAssignedField`:
  matches source text rather than behavior. Remove once publication coverage
  is confirmed elsewhere.
- `AgentRuntimeEventBridgeTests.denseTrailingNewlinesUseBoundedTailScan`:
  asserts only the final phase, not that the scan is bounded.
- `BranchChangesCompletionTests.obsoleteCompletion(.supersededFailureRegistersNothing)`:
  the registry assertion uses a URL that is never passed to `apply`, so it
  can't fail.
- `MarkdownTableA11yTests`: `exposedCellsHaveFrames` could fold into
  `clientAttachingAfterRender`, keeping the empty-row fixture.
- `RemoteMarkdownTypedPathOpenTests`: `openFetchesAndAppliesRemoteTab` could
  fold into `openAnnouncesLoadingBeforeFetch`.
- `SessionPersistenceLoadTests.pathStateAtAcknowledgement`: three branches
  repeat their whole bodies and could share one table.
- `WorkspaceLayoutPresetTests` decoder-depth cases: keep for stack safety, but
  they share the large-stack thread pattern flagged below.
- Test-only seams kept because live tests use them:
  `SecureFileReader.read(afterOpen:)`,
  `AgentRuntimeEventBridge.drainRuntimeEventsForTesting`, the
  `GhosttySurfaceContainerView` `*ForTesting` hooks,
  `GhosttyRuntime.pendingClipboardWriteTextForTesting`, and
  `MarkdownSelfWriteRegistry.entryCountForTesting`.

## Hang risks

No test in `Tests/` sets `.timeLimit`, so one stuck wait parks the whole shard
until the job's 120-minute timeout. A time limit alone won't free a thread
blocked in a semaphore or a main-queue drain. Those waits also need deadlines.

### High risk, nontiming shard

| Where | Why it can hang |
| --- | --- |
| `AsyncGate.wait`, `TestScheduler.wait` (`AwesoMuxTestSupport`) | Continuations ignore cancellation and have no deadline. A missed `open()` parks the test forever. |
| `drainMainQueue` (`Wait.swift:44`, `SidebarHostedTestHarness.swift:118`) | Waits for the main queue with no deadline. Blocks if the main thread is stuck in AppKit work. `PrimaryContentFocusRouterTests` reaches the sidebar harness copy from nontiming. |
| `TerminalPanelWindowTests.mouseInputIsForwardedWithoutReadingKeyboardFields` (line 65) | Sends `leftMouseDown` with no matching `mouseUp`. AppKit can enter a mouse-tracking loop that never returns on a runner with no real input. Prime suspect for the hosted-runner hang. |
| `TerminalPaneLayoutDecodeDepthTests.runOnLargeStack` (lines 55-60) | `done.wait()` on a semaphore with no timeout. |
| `SessionPersistenceLoadTests` quit-during-replacement cases (lines 1557-1677) | Several semaphore waits; `9545f192` bounded only one. |
| `AgentTranscriptStoreTests.commitGateIsEvaluatedUnderTheCacheLock` (line 171) | Semaphore wait with no timeout. |
| `MarkdownTableA11yTests.resizeNotificationRewrapsProse` (line 161) | Resumes through `RunLoop.main.perform`. Hangs if the main run loop never turns in the right mode. |
| `GhosttyEventLoopWatchdogTests` (`SuspendedFaultSource`, lines 145 and 150) | Fake source continuations with no deadline. Also see the logd XPC stall in the watchdog itself. |
| `GhosttyClipboardBridgeTests` | Prompt continuations with no deadline, and it uses the real `NSPasteboard`. |
| `CommandBridgeEnactorTests`, `GhosttyRuntimeRecentLinkTests`, `SurfaceRemountOnSplitCollapseTests`, `WorkspaceEmojiFieldTests` | Main-queue pumps and drains with no deadline; `GhosttyRuntimeRecentLinkTests` also waits on `AsyncGate`. |
| `RemoteMarkdownReferenceTests` (`RemoteMarkdownSnapshotFetcherTests.swift`) | Coalescing and prune gates wait for a fourth fetch with no deadline. |
| `SessionPersistenceCheckpointTests`, `AgentTranscriptLiveRefreshTests`, `AnnotationSaveRecoveryTests` | Scheduler gates and `task.value` joins with no deadline. |
| `BridgeAttachTeardownWiringTests`, `BridgePreflightLifecycleTests` | `AsyncFlag`, stage, and recorder continuations with no deadline. `BridgePreflightLifecycleTests` also calls `orderFrontRegardless` on real windows. |
| `BridgePermissionCoordinatorTests.promptDisappearanceRestoresTerminalResponder` | Real `NSWindow` responder changes. |

### Medium risk

- About ten nontiming suites build a real `GhosttyRuntime` or `NSWindow`.
  They need a window server session, which hosted runners provide
  inconsistently.
- `FontRegistrationTests` and `SidebarTintContrastTests` (DesignSystemTests)
  touch the font and color services.
- Several suites spawn real `git`, `bash`, `node`, `claude`, or `codex`
  processes with synchronous 30-second waits:
  `ClaudeCodexPluginTemplateTests`, `AgentIntegrationTemplateTests`,
  `RuntimeProfileScriptTests`, `PublicSeedSourceScriptTests`,
  `LocalGitRepositoryLocatorTests`, `BuildAndRunScriptTests`,
  `AmxBackendTests`, and `BranchChangesOpenerTests`. These are bounded, but
  slow on a cold runner.
- `LineDiffCountTests` runs a 2,000-line full-rewrite case.

### Other shards

The timing and announcement shards have the same gate pattern in
`HelperConnectionTests`, `UnixSocketClient`, `CommandRunnerTests`,
`ProcessCommandRunnerCompletionTests`, `BridgeAttachPreflightTests`,
`BridgeGenerationRegistryTests`, `AgentTranscriptLiveRefreshWatchTests`, the
`Sidebar*` drains, and the `RemoteMarkdownTypedPathOpen` and `TabRefresh`
gates. `LocalAPIE2E` is excluded from the test target; it drains pipes before
its waits begin and has an unbounded paging loop.

### Suggested fix

1. Add `.timeLimit(.minutes(1))` to the nontiming suites so a hang fails one
   test with a name instead of stalling the job.
2. Give `AsyncGate`, `TestScheduler`, and `drainMainQueue` a deadline that
   records an issue and returns.
3. Replace bare `DispatchSemaphore.wait()` with `wait(timeout:)` plus an
   `Issue.record`.
4. Pair the `TerminalPanelWindowTests` mouse-down with a mouse-up, or post the
   event without going through `NSApp` event tracking.

## Per-suite verdicts

| File | Suite | Verdict | Reason |
| --- | --- | --- | --- |
| AgentHookCommandTests.swift | AgentHookCommandTests | keep; case deleted (done) | Preserves hostile-input, append integrity, privacy, and nested identity boundaries; nested identity fix `5b02fe09` (#602), touched paths #175. Delete `missingEventFileEnvironmentWritesNothing`: `AgentHookHealthCheckTests.diagnosticFailure(kind: "hook", ...)` already exercises the same missing-environment invocation and additionally checks silence/stdin routing. |
| AgentHookEventMapperTests.swift | AgentHookEventMapperTests | keep | Provider event semantics and legacy Grok compatibility are externally supplied contracts, including attention-only events that must not overwrite execution state. |
| AgentHookHealthCheckTests.swift | AgentHookHealthCheckTests | keep | Distinguishes operator diagnostics from silent hook behavior and checks protocol, owner, file-type, and stale-pane custody failures. |
| AgentHookInputReaderTests.swift | AgentHookInputReaderTests | keep | Exercises real idle-without-EOF and maximum-plus-one input boundaries; file-backed size case avoids pipe backpressure. |
| AgentIntegrationInstallerTests.swift | AgentIntegrationInstallerTests | keep | Real filesystem ownership, rollback, manifest compatibility, and private-directory failures protect user files; profile regression INT-882 appears in ce2daeca and permission fix in 8c2e96d9 (#566). |
| AgentIntegrationTemplateTests.swift | AgentIntegrationTemplateTests | keep | Executes shipped templates for root/child routing, payload privacy, and hung-helper termination rather than merely matching source strings. |
| AgentOutputDetectorTests.swift | AgentOutputDetectorTests | keep | Parses external terminal text and rejects prose/path false positives; the existing tables distinguish provider context and command completion. |
| AgentPluginTemplateRendererTests.swift | AgentPluginTemplateRendererTests | keep | Runs hostile helper paths and resolution fallbacks through real sh; provider-tree wiring and permission failure (#566, 8c2e96d9) are separate boundaries. |
| AgentProcessRecognitionTests.swift | AgentProcessRecognitionTests | keep | External process-name parsing distinguishes executable suffixes, versioned Claude names, and misleading prefixes. |
| AgentPromptGateTests.swift | AgentPromptGateTests | keep | Consent, foreground incarnation, and executable identity gate input delivery; positive and negative tables protect separate trust checks. |
| AgentRuntimeEventBridgeTests.swift | AgentRuntimeEventBridgeTests | review | Buffered lifecycle authority, inode/truncate races, symlink refusal, retry-window delivery, and background notifications have distinct observable contracts. Review denseTrailingNewlinesUseBoundedTailScan: it asserts only the resulting phase, so an implementation that scans/allocates the whole file would still pass; no allocation/read bound is measured. |
| AgentRuntimeEventFileTests.swift | AgentRuntimeEventFileTests | keep | Real symlink, owner, mode, inode-preserving truncation, and validated-descriptor reads exercise security boundaries rather than mocked file I/O. |
| AgentRuntimeEventKindProvenanceTests.swift | AgentRuntimeEventKindProvenanceTests | keep | Guards wrong persisted identity and foreign event takeover (419794d9, ca362d22, c9408b8c). |
| AgentRuntimeEventLineSplitterTests.swift | AgentRuntimeEventLineSplitterTests | keep | Byte framing covers split UTF-8, nonzero Data slices, empty reads, and exact reassembly. |
| AgentRuntimeEventProviderSessionIDTests.swift | AgentRuntimeEventProviderSessionIDTests | keep | Validates untrusted provider IDs and separates stale/nested ends, live latch, and last-ended transcript identity (af777539, 8bdcea1f). |
| AgentRuntimeEventReducerEdgeTests.swift | AgentRuntimeEventReducerEdgeTests | keep | Distinct attention/lifecycle races include parent prompt preservation, late hooks, restored waiting, and watermark poisoning (#524, #525, #526, #556; f4d7f017). |
| AgentRuntimeEventReducerTests.swift | AgentRuntimeEventReducerTests | keep | Pane-scoped replay/staleness, future clock input, malformed direct events, and cross-provider identity protect distinct event boundaries. |
| AgentRuntimeEventTests.swift | AgentRuntimeEventTests | keep | Wire decoding rejects hostile paths, oversized lines, unsupported fields, and nonauthoritative waiting assertions. |
| AgentStateTests.swift | AgentStateTests | keep | Display precedence is a user-visible attention contract; legacySessionState protects persisted schema decoding. |
| AgentTranscriptIdentityTests.swift | AgentTranscriptIdentityTests | keep | Constructor and persisted decode independently validate untrusted session IDs and unsupported providers. |
| AgentTranscriptIdentityTests.swift | AgentTranscriptProvenanceThreadingTests | keep | Real layout mutations preserve each transcript tab's session identity after the terminal moves on. |
| AgentTranscriptIdentityTests.swift | DocumentPaneTranscriptProvenanceTests | keep | Malformed provenance must discard only the field and preserve the user's tab. |
| AgentTranscriptImporterTests.swift | AgentTranscriptImporterTests | keep | Exact-session discovery, relocation preference, symlink/owner validation, append refresh, and inode replacement protect file identity. |
| AgentTranscriptLiveRefreshTests.swift | AgentTranscriptLiveRefreshTests | keep | Drives the real refresh loop under controlled interleavings, guarding stale cache writes, cancellation, security refusal, and recovery exhaustion outside the watcher journey. |
| AgentTranscriptLiveRefreshWatchTests.swift | AgentTranscriptLiveRefreshWatchTests | keep | Real vnode/directory watcher-to-cache delivery tests append, initial hierarchy creation, and source recreation; these are distinct failure paths (#521, e85bfc78). |
| AgentTranscriptOpenerTests.swift | AgentTranscriptOpenerTests | keep | Real importer-renderer-store wiring, exact-identity lookup, restored pruned slots, and forwarding the commit gate are not proved by isolated store or watcher tests. |
| AgentTranscriptRendererTests.swift | AgentTranscriptRendererTests | keep | Hostile Markdown containment, size amplification, branch selection, rotation, and never-empty windows guard parsing/data preservation (76831448, #601). |
| AgentTranscriptResumePolicyTests.swift | AgentTranscriptResumeCommandTests | keep | Validated identity and shell quoting protect staged commands; unsafe strings must never reach resume composition. |
| AgentTranscriptResumePolicyTests.swift | AgentTranscriptResumeVerdictTests | keep | Foreground evidence and real remote-layout resolution prevent staging resume into a running agent or remote terminal (ADR-0023). |
| AgentTranscriptStoreTests.swift | AgentTranscriptStoreTests | keep | Owner-only cache custody, symlink refusal, atomic ordering, and pruning of live/recently closed references protect private content and open documents. |
| AmxBackendTests.swift | AmxBackendAttachCommandStatusTests | delete (done) | Both status-injection and scrub/pin checks are already asserted through real shell execution by AmxBackendAttachCommandTests.attachCommandPreservesShellArguments(scenario: "status"). Delete injectsStatusEnv and preservesSecurityGuaranteesWithStatus; retain the executable status row and its captured-env assertion. |
| AmxBackendTests.swift | AmxBackendAttachCommandTests | keep | Real shell argv/env capture guards quoting and environment crossing (INT-561/570/572); existing-only attach forbids accidental creation or label mutation. |
| AmxBackendTests.swift | AmxBackendQueryCwdParsingTests | keep | Untrusted subprocess output rejects relative paths, NUL, bidi controls, and overlong paths with an explicit accepted-size boundary. |
| AmxBackendTests.swift | AmxBackendRemoteOwnedAttachCommandTests | keep | Real backend discovery and exit-status round trip cover #235/#237; remote commands must exclude local daemon/status/bridge state. |
| AmxBackendTests.swift | AmxBackendShellIntegrationInputsTests | keep | Resource admission is separate from command assembly; defaultProbeRejectsRegularFile exercises the real directory probe rather than the injected fileExists closure. |
| AmxBackendTests.swift | AmxBackendSshControlPathTests | keep | INT-766 documents the actual sockaddr_un overflow caused by OpenSSH's 17-byte temporary suffix; this is a platform size boundary. |
| AmxBackendTests.swift | AmxStatusChannelTests | keep | Verifies real precreation with mode 0600 before a watcher can arm, a security and delivery contract (INT-572). |
| AmxStatusEventTests.swift | AmxStatusEventTests | keep | JSONL framing/token checks and absent exit-code preservation protect protocol and safe close decisions (INT-769). |
| AnnotationSaveRecoveryTests.swift | AnnotationSaveRecoveryTests | keep | Annotation identity/payload rebinding, conflict retry, and reload invalidation protect drafts; 6f1edc4e explicitly hardens annotation save recovery. |
| AppSettingsStoreTests.swift | AppSettingsStoreTests | keep | Preserves unknown user data and invalid disk bytes, transactional save failures, and accepted schema state; related fixes `b06839d3`, `3ef8ffdd` (#605). |
| AppSettingsSymlinkWatchTests.swift | AppSettingsSymlinkWatchTests | keep | Real in-place/atomic edits, relative links, retargeting, and later saves guard symlink settings reload fix `9d7d7ff0` (#584). |
| AsyncGate.swift | AsyncGate helper | keep | Used directly by persistence, recovery metadata, and Ghostty link tests, and indirectly by TestScheduler. |
| AttentionScenarios.swift | runAttentionScenarios (journey helper) | keep | Used by the executable; verifies scoped authenticated cursors, retention, incarnation changes, revocation and restart over real sockets/helper calls. |
| AttributedMarkdownBuilderTests.swift | AttributedMarkdownBuilderTests | keep | Mapping precision, malformed mark binding, Unicode/CRLF tables, pipe containment, and indented fence ranges protect parsing and edit locations. |
| BoundedProcessRunnerTests.swift | BoundedProcessRunnerTests | keep | A real descendant retaining stdout targets pipe-EOF deadlock; 99ee2c0d fixes handoff findings and cf6a58da (#343) preserves controllable timeout behavior. |
| BoundedUTF8FileReaderTests.swift | BoundedUTF8FileReaderTests | keep | Real over-cap fixture protects helper input size admission; lower SecureFileReader coverage alone does not exercise this adapter. |
| BranchChangesCompletionTests.swift | BranchChangesCompletionTests | review | Protects stale-write registration, closed/moved panes, and refresh-in-place/disclosure fixes d2a0b949 and 7439d87d. Review obsoleteCompletion(.supersededFailureRegistersNothing): its random unwritten URL is never passed to apply, so the registry assertion cannot detect an erroneous registration; retain the meaningful no-alert contract. |
| BranchChangesIdentityTests.swift | BranchChangesIdentityTests | review | Sanitization, decode validation, raw cache identity, and read-only tabs are real contracts; unequal hash values are not a Hashable guarantee. Remove only the hashValue inequality assertion in longSharedPrefixesStayDistinct; retain unequal identity and equal clipped display assertions. |
| BranchChangesOpenerTests.swift | BranchChangesOpenerTests | keep | Repository admission, hostile/truncated refs, TOCTOU bookends, cache collisions/pruning, and actual git argv exercise independent trust and data-integrity boundaries. |
| BranchChangesRendererTests.swift | BranchChangesRendererTests | keep | Untrusted diff/path injection, fence containment, UTF-8 expansion, byte budgets, and truncation honesty protect the viewer boundary. |
| BridgeAttachAssemblyTests.swift | BridgeAttachAssemblyTests | keep | Secret transport, hostile quoting, owner-only stat dialects, stale-delete serialization, PID reuse, lease publication, and env crossing are security/concurrency boundaries (INT-698). |
| BridgeAttachPreflightTests.swift | BridgeAttachPreflightTests | keep | Real preflight ordering/rollback and committed-generation quit visibility remain observable with injected transport; stale-work invalidation is backed by 72a3ec6e (#171). |
| BridgeAttachTeardownWiringTests.swift | BridgeAttachTeardownWiringTests | keep | Exercises actual enactor entry points and runtime registry ownership; disposal/close/repoint must preserve or revoke different generations (INT-698; #171). |
| BridgeConnectionActorTests.swift | BridgeConnectionActorTests | keep | Real local sockets test private paths, handshake slot caps, direction allowlisting, replacement, and stale-generation writes (INT-698). |
| BridgeConnectionSupervisorTests.swift | BridgeConnectionSupervisorTests | keep | Real handshake authentication, protocol rejection ordering, promotion/ack, and loss callbacks protect an authority boundary. |
| BridgeDoctorSignalsTests.swift | BridgeDoctorSignalsTests | keep | Fail-closed protocol negotiation accepts a supported line and rejects garbage; production RemoteHelperInstaller consumes compatibleProtocols at lines 100 and 420. |
| BridgeEnvelopeTests.swift | BridgeEnvelopeTests | keep | Untrusted JSON schema, Unicode hazards, session IDs, and per-type byte limits are protocol/security boundaries. |
| BridgeExecChannelTests.swift | BridgeExecChannelTests | keep | Uses real yes output and pipes to prove the output cap wins independently of the timeout, unlike BoundedProcessRunnerTests' descendant-EOF case. |
| BridgeFrameReaderTests.swift | BridgeFrameReaderTests | keep; cases merged (done) | Fragmentation, UTF-8 reassembly, authenticated routing, partial deadlines, and size caps are distinct protocol contracts. Merge `partialLineIsHeldUntilNewlineArrives` into `lineSplitAcrossTwoConsumesReassembles`, carrying its first-half tail bytes and startedAt assertions into that test. |
| BridgeGenerationRegistryTests.swift | BridgeGenerationRegistryTests | keep | Generation-scoped cleanup, successor preservation, captured-path deletion, and quit visibility protect live remote resources (#171, 72a3ec6e). |
| BridgeHelperCommandTests.swift | BridgeHelperCommandTests | keep | Checks command routing, bounded JSON, custody privacy, fail-silent emit, and protocol rejection before connecting. |
| BridgePendingRequestMapTests.swift | BridgePendingRequestMapTests | keep; cases merged (done) | First-terminal-event wins, expiry supremacy, duplicate target preservation, and bounded admission protect permission state. Merge `concurrentEntriesAdmitUpToCap` into `admissionBeyondCapOverflowsAndLeavesPendingUntouched`, retaining per-admission `.admitted(entry)`/ID checks in its fill loop. |
| BridgePermissionCoordinatorTests.swift | BridgePermissionCoordinatorTests | keep | Consent focus, deadline, cap, grant/generation binding, spoof warning, and responder restoration are security/UI contracts; fixes 7d6437b0 (#346) and 51ba4c9a (#626). |
| BridgePreflightLifecycleTests.swift | BridgePreflightLifecycleTests | keep | Real surface lifecycle integrates suspended preflight, stale acknowledgment, staged cleanup, and policy/target invalidation (#171, 72a3ec6e). |
| BridgeSessionEndPolicyTests.swift | BridgeSessionEndPolicyTests | keep | Remote missing/255 exit codes, reconnect, and capped respawn differ from ordinary shell-exit behavior; safe defaults protect sessions. |
| BridgeStateFileCustodyTests.swift | BridgeStateFileCustodyTests | keep | Real permissions, owner mismatch, symlink/FIFO rejection, and inclusive size boundary protect state-file credentials. |
| BridgeStateFileTests.swift | BridgeStateFileTests | keep | Parser size and unsafe-socket admission are separate from filesystem custody checks in the helper target. |
| BridgeSurfaceCommandPolicyTests.swift | BridgeSurfaceCommandPolicyTests | keep | ADR-0022 forbids SSH panes silently becoming local shells; persistence ownership and bridge availability are separate inputs. |
| BuildAndRunScriptTests.swift | BuildAndRunScriptTests | keep | Executes shipped shell functions against temporary bundles and controlled process trees; e6795bfb (#303, reproducing #281) fixes ancestor detection and refusal prevents terminating the hosting app. |
| ClaudeCodexPluginTemplateTests.swift | ClaudeCodexPluginTemplateTests | keep | Real provider CLI validation/install and manifest-to-mapper compatibility protect shipped marketplace resources (INT-518). |
| CodexAppServerClientTests.swift | ProcessCodexAppServerClientTests | keep | Exercises actual JSON-RPC decoding, unknown trust states, wrong-shape results, EOF and request-ID correlation through an immediate transport fixture. |
| CodexPermissionNotificationTests.swift | CodexPermissionNotificationTests | keep | Controlled-clock tests guard delayed transient permission alerts, cancellation, and immediate other attention (#644; a912c0c8). |
| CommandBridgeEnactorTests.swift | CommandBridgeEnactorTests | keep | Recovery admission, remote/local trust separation, stale callbacks and teardown ordering protect live sessions; diagnostic preservation fix `f8c3f33d` (#720). |
| CommandBridgeRuntimeDeathHealViewTests.swift | CommandBridgeRuntimeDeathHealViewTests | keep | Real cache/store integration guards split loss, recovery-record lifetime and command completion; mounted-surface fix `1ae0a01f`. |
| CommandRunnerTests.swift | ProcessCommandRunnerTests | keep | Exercises real cancellation, SIGKILL escalation, inherited pipe writers, withheld exit callbacks and output above pipe capacity; same deadline failure family as `f4d7d000` (#581). |
| CommentResolutionTrackerTests.swift | CommentResolutionTrackerTests | keep | Stateful zero-count/settle/confirmation sequences prevent duplicate resolution and preserve a pending confirmation across reloads. |
| ConfigFileStoreTests.swift | ConfigFileStoreTests | keep | Filesystem persistence, symlink write-through, ownership, oversize preservation, FIFO rejection, and surfaced errors protect user config. |
| ContextScenarios.swift | runContextScenarios (helpers) | keep | Used by the executable; exact-session disclosure, symlink refusal, consent, UTF-8 caps and mid-read revocation exercise production capture/reader paths. |
| DaemonGarbageCollectorTests.swift | DaemonGarbageCollectorTests | keep | Preserves logs/session state and fences destructive signals by profile, fresh process identity and incarnation; `8a57f25f` (#487), `84aa1538` (#510). |
| DaemonGCPlanTests.swift | DaemonGCPlanTests | keep | Destructive cleanup needs framing, ownership, age, missing evidence, and profile fences; concrete inherited-daemon incidents are #183 and INT-914. |
| DaemonReapGuardTests.swift | DaemonReapGuardTests | keep | Rechecks PID, creation epoch, lifecycle, and clients immediately before destructive reaping. |
| DaemonRecoveryMetadataSynchronizerTests.swift | DaemonRecoveryMetadataSynchronizerTests | keep | Deferred latest-value persistence and failure throttling protect recoverable metadata; `6c6b44de`, `755ee58a`. |
| DaemonRecoveryMetadataTests.swift | DaemonRecoveryMetadataTests | keep | Wire label round trip, URL-safe alphabet, independent malformed fields, and byte limits protect recovery input. |
| DaemonRecoveryReducerTests.swift | DaemonRecoveryReducerTests | keep | Prevents duplicate ownership and validates remote directories without treating remote paths as local files. |
| DaemonStateResolverTests.swift | DaemonStateResolverTests | keep | Ownership/restorability, in-use clients, idle evidence, caps, and pin precedence govern destructive lifecycle eligibility. |
| DocumentFileWatcherTests.swift | DocumentFileWatcherTests | keep | Real vnode re-arm, permanent deletion and leading-edge delivery are OS boundaries absent from the listed E2E journeys. |
| DocumentGroupMigrationTests.swift | DocumentGroupMigrationTests | keep | INT-748 migration preserves tabs, terminal association, tree shape, and duplicate-group-ID content. |
| DocumentLoaderTests.swift | DocumentLoaderTests | keep | Real file ingress checks include FIFO, ownership, byte caps, UTF-8, symlink resolution, and canonically equal but byte-different content. |
| DocumentOversizeBannerTests.swift | DocumentOversizePolicyTests | keep | Policy distinguishes retaining an existing render from applying errors and settling after recovery; mid-save growth fix `7f1a724e` (#491). |
| DocumentPaneTests.swift | DocumentGroupDecodingTests | keep | Malformed-tab salvage and empty-leaf collapse prevent corrupt document metadata losing a surviving terminal. |
| DocumentPaneTests.swift | DocumentPaneTests | keep | Schema-aware remote-origin decoding rejects malformed or local identities masquerading as remote snapshots. |
| DocumentRevisionMonitorTests.swift | DocumentRevisionMonitorTests | keep | Real file/watch integration covers baseline races, self-write suppression, selection reconciliation and announcement dedup without equivalent listed E2E coverage. |
| DocumentTabAssociationTests.swift | DocumentTabAssociationTests | keep | Send routing and read-only provenance protect live associations, remote caches, host identity, and nil-association facade opens (INT-748). |
| DomainTestSupport.swift | Active-pane snapshot/accessor helpers | keep; case deleted (done) | Snapshot factories are used by ShellActivityTests; active-pane accessors are used by reducer/heartbeat and other core tests. Delete unused `TerminalSession.staleAgentActivityThreshold`; all external threshold references use `TerminalPane.staleAgentActivityThreshold`. |
| EventRecorder.swift | EventRecorder helper | keep | Used by RemoteBrowserE2ETests, command-runner tests, bridge suites, and watcher tests across Tests/. |
| ExecutionIdentityTests.swift | ExecutionIdentityTests | keep | Malformed execution plans fail closed, legacy locations migrate, and retired #235 fields do not break persisted workspaces. |
| FakeCodexAppServerTransport.swift | FakeCodexAppServerTransport (helper) | keep | Used by six client fixture constructions; production client performs decoding/correlation, so this does not merely test a mock. |
| FileManagerOwnerOnlyTests.swift | FileManagerOwnerOnlyTests | keep | Production permission helpers protect private files and prevent writable-directory deletion attacks; these are not test-helper self-tests. |
| FontRegistrationTests.swift | FontRegistrationTests | keep | Verifies bundled files actually register and NSFontManager selects each weight; resource/weight resolution is observable behavior, not just copied names. |
| ForegroundProcessLivenessTests.swift | AgentLivenessPolicyTests | keep | INT-552 resets agent chrome only on proven local/remote idle or observed SSH entry; unknown/busy observations must preserve it. |
| ForegroundProcessLivenessTests.swift | ForegroundProcessLivenessTests | keep | Fail-safe classification distinguishes unknown evidence, busy shells, bridges, and live foreground commands. |
| FuzzyMatchTests.swift | FuzzyMatchTests | keep | Unicode expansion/accent index mapping and query-length rejection guard parsing/index boundaries; cases are already parameterized. |
| GhosttyActionPaneRecycleAtomicityTests.swift | GhosttyActionPaneRecycleAtomicityTests | keep | Guards cross-session title/progress corruption and deferred stale writes on cached-view reuse; `59551f3e`, `4c7a2985`. |
| GhosttyClipboardBridgeTests.swift | GhosttyClipboardBridgeTests | keep | Consent, concurrent prompt arbitration, malicious preview sanitization and teardown gate release are security boundaries. |
| GhosttyClipboardBridgeTests.swift | GhosttyClipboardConfirmPreviewTests | keep | Borrowed C payload decoding covers mixed MIME, invalid UTF-8, null data with nonzero length and empty input. |
| GhosttyClipboardBridgeTests.swift | GhosttyClipboardReadRoutingTests | keep | MIME delivery/list/refusal matrix guards upstream clipboard protocol compatibility rather than a getter. |
| GhosttyClipboardBridgeTests.swift | TerminalPasteboardSupportedContentTests | keep | Real pasteboard type advertisement controls Paste availability for text/files/images and unsupported formats; no matching listed E2E assertion established. |
| GhosttyConfigEnvironmentTests.swift | GhosttyConfigEnvironmentTests | review | `logFieldsContainsNoPII` asserts copied scalar formatting and absence of paths never supplied to this instance, but public-log privacy is an explicit source contract. Decide whether exact log-field names are a supported diagnostics contract before deleting the sole test; it does not exercise snapshot path resolution. |
| GhosttyConfigManagerTests.swift | GhosttyConfigManagerOverlayTests | keep | Feeds invalid configuration to linked libghostty and verifies diagnostics survive the embedding boundary. |
| GhosttyEventLoopWatchdogTests.swift | GhosttyEventLoopWatchdogTests | keep | Guards idle false positives, repeat recovery and stale in-flight fault results; `5de17b03` (#181), `7f91006c`. |
| GhosttyGeneratedConfigOverlayParseTests.swift | GhosttyGeneratedConfigOverlayParseTests | keep | Parses generated clipboard/appearance overlays with real libghostty, including escaped font names; does not snapshot generated strings. |
| GhosttyMarkdownClickProbeTests.swift | GhosttyMarkdownClickProbeTests | keep | Untrusted filename boundaries, Unicode cell offsets, clipping, stale surface identity and native-link precedence are distinct parsing/routing contracts. |
| GhosttyRuntimeConfigBuildTests.swift | GhosttyRuntimeConfigBuildTests | keep | Live configuration reload retains cached pane identity while updating background; direct appearance application exercises a separate entry point. |
| GhosttyRuntimeRecentLinkTests.swift | GhosttyRuntimeRecentLinkTests | keep | Captured-pane routing, unsafe schemes and remote/local separation guard trust boundaries; speech scoping fix `ee8ba65d`. |
| GhosttyRuntimeTerminalLinkFeedbackTests.swift | GhosttyRuntimeTerminalLinkFeedbackTests | keep | Tests failed-click feedback and successful-click silence through actual surface routing; `3aac44d9` (#467). |
| GitWorktreeCreatePolicyTests.swift | GitWorktreeCreatePolicyTests | keep | Filesystem overlap and main-versus-linked invocation cases guard actual create-form failures (00c2438c, f9c6b1b7, 25b5f023). |
| GitWorktreePorcelainParserTests.swift | GitWorktreePorcelainParserTests | keep | Double-NUL framing, malformed record salvage, invalid UTF-8, and unusual paths protect external git output parsing. |
| HandoffReceiverTests.swift | HandoffReceiverTests | keep | Path traversal, private-directory custody, wrong byte counts, and collision/concurrent publication protect received files from loss or overwrite. |
| HelperConnectionTests.swift | HelperConnectionTests | keep | Real handshake/permission flow and pre-expired request termination guard fail-closed behavior; pre-expiry regression explanation is in source, present since seed `cb3545b6`. |
| HelperPermissionRuntimeTests.swift | HelperPermissionRuntimeTests | keep | Target mismatch prevents confused-deputy authorization; disconnect drains pending requests fail-closed at the helper wrapper. |
| LayoutPresetStoreTests.swift | LayoutPresetStoreTests | keep | Real files guard traversal/symlinks, worktree anchoring, nesting/size limits and bounded enumeration; `2b03595d`, `12ffbd21`. |
| LineDiffCountTests.swift | LineDiffCountTests | keep | Byte/line caps and worst-case exact rewrite boundary prevent unbounded diff work while distinguishing self-writes. |
| LinuxProcessSnapshotReaderTests.swift | LinuxProcessSnapshotReaderTests | keep | Linux /proc stat parsing must handle spaces and embedded closing parentheses without corrupting process identity/liveness fields. |
| LocalGitRepositoryLocatorTests.swift | LocalGitRepositoryLocatorTests | keep | Real Git validates worktree identity, malformed nested metadata boundaries and environment scrubbing against executable shadowing; `4c4d5259`. |
| main.swift | LocalAPIE2E / E2EAgentRoster / E2ESlowClient / E2ECaptureGate / E2EAuthorization (executable and helpers) | keep | Actual socket/helper/Keychain journey covers identity/grants, endpoint ownership and partial-frame revocation; header accumulation fix `7bac3d99`. |
| ManagedSSHObservationLivenessTests.swift | ManagedSSHObservationLivenessTests | keep; cases merged (done) | Observed SSH target preservation is repeated with almost identical setup; input and second-observation variants must remain case rows. Merge shellNamedWrapperCannotReplaceObservedSSHTarget and optionedCommandCannotReplaceObservedSSHTarget into one observedSSHSubmissionPreservesTarget table (command, observeAgain); retain all assertions and other tests. |
| MarkdownDocumentWriterTests.swift | MarkdownDocumentWriterTests | keep | Real writes protect stale bytes/inodes, symlink retargets, metadata, private temp creation, and mid-save growth (#491; 7f1a724e). |
| MarkdownFileEnumeratorTests.swift | MarkdownFileEnumeratorTests | keep | Depth/count caps and at-cap/over-cap file flags protect resource and document-replacement boundaries; generated-directory exclusion avoids repository noise. |
| MarkdownFrontMatterTests.swift | MarkdownFrontMatterTests | keep | Parser and builder coverage differ; CRLF delimiter/body-byte/source-offset behavior guards 604fb823 (#617). |
| MarkdownLinkInterceptTests.swift | MarkdownLinkInterceptTests | keep | File-scheme, extension, traversal, controls, percent literals, line references and fragments are untrusted-input boundaries. |
| MarkdownSelfWriteRegistryTests.swift | MarkdownSelfWriteRegistryTests | keep | Retention sweep and expiry boundary are intentional memory/announcement regression checks (#251; cd57d99a), not disposable getter tests. |
| MarkdownTableA11yTests.swift | TableAXElementTreeTests | review | Live-frame traversal duplicates the window-backed client-attachment traversal; preserve the unique empty-row fixture. Merge `exposedCellsHaveFrames` into `TableAXLazyMaterializationTests.clientAttachingAfterRender`, parameterizing populated versus empty/ragged rows and retaining every-cell positive-frame checks. |
| MarkdownTableA11yTests.swift | TableAXGridTests | keep | Ragged/multi-run cells preserve accessible coordinates and the cap prevents hostile dense-grid allocation. |
| MarkdownTableA11yTests.swift | TableAXLazyMaterializationTests | keep | Late client attachment and content-change invalidation are real accessibility contracts, not snapshots. |
| MarkdownTableA11yTests.swift | WideTableOverflowTests | keep | Native TextKit checks actual wrapping, overflow, horizontal-scroll retention and resize notifications; no matching listed E2E assertion established. |
| NudgeComposerTests.swift | NudgeComposerTests | keep | Shell metacharacters, quoting, absolute paths, control/bidi rejection, and no submitted newline protect staged handoffs (#742; d6aa3671). |
| OpenCodeTranscriptDatabaseTests.swift | OpenCodeTranscriptDatabaseTests | keep | Real SQLite WAL/read-only behavior, exact session isolation, foreign part exclusion, symlink rejection, and cumulative budgets protect private transcript data. |
| PaletteSearchTests.swift | PaletteSearchTests | keep | Real executable fixture reproduces app-action disappearance beside quick-run discovery; `1c71bdb1` (#756). |
| PaneChangeClassificationTests.swift | PaneChangeClassificationTests | review | Runtime mutation table protects #311/#313 (71c5e036); source-string matching couples to assignment spelling rather than publication behavior. Review classificationCoversEveryAssignedField for removal only after confirming facade/publication coverage elsewhere; retain classifiesMutation, especially durable-plus-title and SSH fields. |
| PaneColorCodableTests.swift | PaneColorCodableTests | keep | Corrupt/future pane and group colors must degrade independently without dropping persisted sessions. |
| PaneLayoutReducerTests.swift | PaneLayoutReducerTests | keep | Split rollup reset and retained SSH identity are meaningful state-transition contracts; direct reducer coverage exercises a different boundary from store publication. |
| PaneTitleFreezeRuleTests.swift | PaneTitleFreezeRuleTests | keep | Protects user-authored names from OSC updates, reset, split, and recycle; restoration tests exercise a separate ingress. |
| PlanAnnotationMarkerTests.swift | PlanAnnotationMarkerTests | keep; cases merged (done) | Parsing and on-disk serialization are durable contracts; standalone serialization cases can join the existing exact round-trip table. Merge onDiskFormat's three rows into markerRoundTrips using its exact column; deduplicate the identical plain-note row without losing the other two exact spellings. |
| PlanAnnotationWriterTests.swift | PlanAnnotationWriterTests | keep | Real builder round trips protect annotation edits, legacy migration, duplicate-ID refusal, CRLF replies, Unicode offsets, and fenced examples. |
| PrimaryContentFocusRouterTests.swift | PrimaryContentFocusRouterTests | keep | Native focus destination, non-key-window refusal and reconnect-overlay focus exclusion lack equivalent listed E2E coverage; focus fix `e1780048` (#484). |
| ProcessBoundedWait.swift | Process wait/timeout helpers | keep | Many real-process callers rely on bounded waits; documented dropped Foundation termination event caused a 15+ hour hang (#207). |
| ProcessCommandRunnerCompletionTests.swift | ProcessCommandRunnerTests (extension) / WithheldTerminationNotification (helper) | keep | Missing callback cancellation/escalation and output-reader stop guard stalled process completion; `f4d7d000` (#581), helper also used by CommandRunnerTests.swift. |
| ProcessLivenessProbeTests.swift | ProcessLivenessProbeTests | keep | PID reuse and unknown process-tree evidence must fail closed before close/reap decisions; `a9d27d4d` (#513), `3de18fe4` (#197), source cites #190. |
| ProcessOutputCapture.swift | captureOutput / timeout helper | keep | Used by template tests and runtime/build/public-seed script tests; file capture avoids pipe-buffer/EOF deadlocks. |
| ProcessWaitBoundedGuardTests.swift | ProcessWaitBoundedGuardTests | keep | Whole-tree scan guards the demonstrated 15-hour wait hang (#207); `ffb963a4` (#213), while the script checks only changed lines. |
| PublicSeedSourceScriptTests.swift | PublicSeedSourceScriptTests | keep | Executes the real privacy guard against tracked/ignored/binary content, purged symlink paths and rg failures; filename-only reporting fix `d07cb3ff` (#591). |
| PullRequestDocumentFlowTests.swift | PullRequestDocumentFlowTests | keep | Real Git plus fixture CLI exercises inert hostile content, stale publication, cancelled writes and cache leases; controlled cancellation fix `6a93f7c1`. |
| QuitRiskPolicyTests.swift | QuitRiskPolicyTests | keep | Destructive-close/quit safety table includes pre-prompt idle evidence regression #190 and fail-conservative unknown liveness. |
| QuitRiskTests.swift | QuitRiskTests | keep | Real cache regressions INT-420 and foreign-store snapshot isolation INT-185; synthetic timestamps avoid elapsed-time waits. |
| RealSpawnTimeout.swift | realSpawnTimeout constant | keep | Used by RemoteHelperInstallerTests, RemoteHandoffTests, and RemoteHandoffRemediationTests; records hosted timer/output-cap race INT-819, run 30588368340. |
| RecentlyClosedWorkspaceReducerTests.swift | RecentlyClosedWorkspaceReducerTests | keep | Recovery/identity collision guards prevent daemon aliasing and lost recovery entries (INT-578); deleted remote-group recovery guards INT-773. |
| RecentlyClosedWorkspaceTests.swift | RecentlyClosedWorkspaceTests | keep | Tolerant snapshot decoding, transient privacy, expiry, close-origin persistence, and hostile-title sanitization cover distinct persistence boundaries. |
| RecentTerminalLinksTests.swift | RecentTerminalLinksTests | keep | UTF-8 byte cap and exclusion of token-bearing recent URLs from persistence are size/privacy boundaries. |
| RemoteBrowserE2ETests.swift | RemoteBrowserE2ETests / BrowserE2ESink / BrowserSSHFixture / BrowserHitReceiver (helpers) | keep | This is the real SSH/browser E2E invoked by the named harness, not redundant unit coverage; failed-step report fix `8fd561a6`. |
| RemoteForegroundCloseRiskTests.swift | RemoteForegroundCloseRiskTests | keep | Prevents stale/missing remote evidence or misleading local SSH process state from authorizing destructive close. |
| RemoteHandoffRemediationTests.swift | RemoteHandoffRemediationTests | keep | Exercises real staged install scripts, consent, authority invalidation, checksums, cancellation, unsafe directories and preservation of the previous helper; fix c30c2ec3 (#588). |
| RemoteHandoffTests.swift | RemoteHandoffTests | keep | Guards clipboard routing, unsafe source types/size caps, descriptor identity, private transfer, receipt containment and cancellation; fix c30c2ec3 (#588). |
| RemoteHelperChoiceTests.swift | RemoteHelperChoiceTests | keep | Real config round trips preserve host/user consent scope, revocation, failed-save rollback and legacy global policy; these are authorization boundaries. |
| RemoteHelperInstallerTests.swift | RemoteHelperInstallerTests | keep | Guards policy revalidation, artifact/filename binding, executable-source identity, private permissions, capability decoding and exact install receipts. |
| RemoteMarkdownDocumentLinkNavigationTests.swift | RemoteMarkdownAttributedDocumentLinkTests | keep | Verifies untrusted Markdown cannot create local-file or parent-escape links, while generated-document links remain disabled. |
| RemoteMarkdownDocumentLinkNavigationTests.swift | RemoteMarkdownDocumentLinkNavigationTests | keep | Tests production open/apply behavior, rejected-link fail-closed routing and truthful fragment announcements for closed/stale/failure tabs. |
| RemoteMarkdownSnapshotFetcherTests.swift | RemoteMarkdownReferenceTests | keep | Retains parsing/host authority, containment, argv injection, private cache, size caps, stale-byte preservation and prune/fetch races; stale-cache context references #254 in source. |
| RemoteMarkdownTabRefreshTests.swift | RemoteMarkdownTabRefreshTests | keep | Guards opt-in network access, background selection/association preservation, closed-tab races, fair restore admission and session/cohort announcement ownership; fix ee8ba65d scopes speech to sessions. |
| RemoteMarkdownTypedPathOpenTests.swift | RemoteMarkdownTypedPathOpenTests | review | Happy-path open and loading-order tests use the same production entry point and can assert both contracts in one journey; retain host/path and stale-authority boundaries. Merge openFetchesAndAppliesRemoteTab into openAnnouncesLoadingBeforeFetch; retain fetched-path, remote identity, read-only-tab and cache-URL assertions as well as loading/fetch/outcome order. |
| RemoteProcessLivenessClassifierTests.swift | RemoteProcessLivenessClassifierTests | keep | Missing/unreadable terminal evidence and nested foreground shells must remain indeterminate to avoid unsafe close decisions. |
| RemoteReconnectStateTests.swift | RemoteReconnectStateTests | keep | Error provenance and legacy healing guard INT-697; moving groups must preserve authoritative pane transport. |
| RemoteReconnectViewTests.swift | RemoteReconnectViewTests | keep | Covers remote reconnect latch/budget recovery and split-sibling isolation through runtime/view/enactor forwarding; stated contract INT-697. |
| RemoteSessionDetectorTests.swift | RemoteSessionDetectorTests | keep | Parses untrusted terminal titles with local-host discrimination, unsafe scalars, malformed hosts, and length limits. |
| RemoteSessionDetectorTests.swift | SessionStoreRemoteSessionTests | keep | Covers safe managed-conversion eligibility, alias retention, nested SSH, authoritative local cwd, and stale remote cwd identity checks. |
| RemoteSessionDetectorTests.swift | TerminalPaneRemoteHostPersistenceTests | keep | Runtime SSH observation must not survive persistence; epoch regeneration and remote-state exclusion are real lifecycle boundaries. |
| RemoteSessionNameTests.swift | RemoteSessionNameTests | keep | Remote socket/command component validation rejects traversal, option injection, shell metacharacters, Unicode controls, and malformed decoded values. |
| RemoteSSHCommandTargetTests.swift | RemoteSSHCommandTargetTests | keep | Conservative SSH parsing prevents options/remote commands from being misinterpreted as a safe managed-workspace offer. |
| RemoteTargetTests.swift | RemoteTargetTests | keep | Destination parsing and Codable validation reject dash-leading option injection and invisible routing scalars. |
| RichInputStagingTests.swift | RichInputStagingTests | keep | Strips bracketed-paste escape injection, terminal control bytes, and bidi formatting before terminal staging. |
| RuntimeProfileScriptTests.swift | RuntimeProfileScriptTests | keep | Runs actual shell functions and reaper argument/env selection, guarding namespace separation and malformed-profile rejection; amx-reap E2E covers ownership/failure cases instead. |
| SecureFileReaderTests.swift | SecureFileReaderTests | keep | Descriptor/path replacement, growth, ownership, symlinks, FIFO rejection, chunk integrity, and suffix windows protect untrusted reads and data integrity. |
| SelectionSourceMappingTests.swift | SelectionSourceMappingTests | keep | Byte/UTF-16 boundaries, surrogate rejection, markup overlap, and annotation insertion prevent edits targeting the wrong bytes (fac2dabd). |
| SessionGroupExecutionSummaryTests.swift | SessionGroupExecutionSummaryTests | keep | Mixed transport/ownership summaries and modal retarget detection govern destructive group operations; legacy migration is a separate boundary. |
| SessionManagerControllerTests.swift | SessionManagerControllerTests | keep | Guards sibling-confirmation cancellation and refusal to restore partially attached/missing daemon sets; fix 3735281e. |
| SessionManagerPresentationTests.swift | SessionManagerPresentationTests | delete (done) | primaryActions is an exact table copy of the five-branch DaemonRow.primaryAction getter at Sources/awesoMux/Views/SessionManagerPanel.swift:62. Delete primaryActions and its now-unused row fixture (entire file). |
| SessionPersistenceCheckpointTests.swift | SessionPersistenceCheckpointTests | keep | Continuous display-title changes must checkpoint structural edits; older writes must not overwrite newer checkpoints/quit flushes; fix 844b6215 (#583). |
| SessionPersistenceLoadTests.swift | SessionPersistenceLoadTests | review | Protects durable session bytes, unsafe files, schema/size/depth decoding, migration, recovery authorization and quit-write ordering; three path-state branches duplicate their entire bodies. In pathStateAtAcknowledgement, merge deletedSnapshotCanResumeSaving0/1/2 branches into one shared body parameterized by kind; preserve all three archivedSnapshot/snapshotConflict/sanitizedRestore cases and assertions. |
| SessionPersistenceLoadTests.swift | SessionPersistenceSerializationDomainTests | keep | Empty outer suite is the shared .serialized domain for nested load/checkpoint suites mutating process-wide persistence state. |
| SessionRecoveryConfirmationCenterTests.swift | SessionRecoveryConfirmationCenterTests | keep | Guards stale token/daemon rejection, cancellation/replacement ownership and pre-attach timeout retirement; fixes 191d6e74 and 3735281e. |
| SessionRestoreReducerTests.swift | SessionRestoreReducerTests | keep; cases merged (done) | Preserves data/transport through malformed identity graphs and restore; two duplicate-group-ID fixtures can share one richer scenario. Merge restoreReassignsDuplicateGroupIDsAfterNameMerging into duplicateGroupIDReassignmentPreservesRemoteTarget, retaining uniqueness and summary-count assertions. |
| SessionSnapshotMigrationTests.swift | SessionSnapshotMigrationTests | keep | Frozen v1/v2/v5 fixtures, corrupt inactive pane tolerance, and prompt retention guard backward-compatible recovery (INT-504). |
| SessionSnapshotTests.swift | SessionSnapshotTests | keep | Legacy daemon identity validity, future-schema rejection, and nested schema propagation prevent invalid recovery and lost document tabs. |
| SessionStoreAttentionStickyTests.swift | SessionStoreAttentionStickyTests | keep | Selection setter, pin suppression, explicit acknowledgement, and disable transitions protect stable Needs Input membership. |
| SessionStoreCloseGroupTests.swift | SessionStoreCloseGroupTests | keep | Last-group close guards INT-206; joiners/leavers during confirmation protect work outside the confirmed destructive scope. |
| SessionStoreFocusedCommandTests.swift | SessionStoreFocusedCommandTests | keep | Checks reducer decisions reaching the actual store and late permission-prompt ordering; reducer-only tests do not verify that wiring. |
| SessionStoreLiftedOrderTests.swift | SessionStoreLiftedOrderTests | keep | Parent/child provider-session identity, answer transitions, and pin/close ordering prevent unacknowledged work from disappearing or moving under the pointer. |
| SessionStoreLiveTitleChannelTests.swift | SessionStoreLiveTitleChannelTests | keep | Existing fine/coarse channels, save callback, cross-session coalescing, rollback, and writer refresh guard live-title regressions (#311; 39ac2182, #366). |
| SessionStoreMoveToWorkspaceTests.swift | SessionStoreMoveToWorkspaceTests | keep | Preserves moved pane identity, return geometry, pins, recovery origin, and stale-event isolation across restore and reopen. |
| SessionStoreRestoreSanitizationSummaryTests.swift | SessionStoreRestoreSanitizationSummaryTests | keep | Distinguishes recovery-archive requirements from visible warnings; corruption repair and benign normalization require different reporting. |
| SessionStoreSanitizationTests.swift | SessionStoreSanitizationTests | keep | Separate display/routing sanitization policies protect bidi, invisible, confusable, combining-mark, and length boundaries. |
| SessionStoreTests.swift | SessionStoreSiblingPaneExitErrorTests | keep | INT-504 record-before-removal regression must badge the exiting pane without contaminating its surviving sibling. |
| SessionStoreTests.swift | SessionStoreTerminalBackendMetadataTests | keep | Provisional recovery rollback, stale tokens, daemon collision, and unknown metadata fail-closed behavior prevent destructive recovery. |
| SessionStoreWorkspaceGroupTests.swift | SessionStoreWorkspaceGroupTests | keep; cases merged (done) | Retain pane-owned transport, conversion, name sanitization/routing, and INT-767 persistence; two small cases repeat richer scenarios. Merge renameGroupRejectsBlankOrDuplicateNames into namePolicy (matching rows already exist); merge addSSHSessionWithoutSessionNameStaysLocalAmx into addSSHSessionKeepsPaneOwnedIdentity by retaining the remoteOwnedExecution == nil assertion. |
| ShellActivityTests.swift | ShellActivityTests | keep | INT-333 shell chrome, per-pane prompt trust, recycle trust reset, and raw immediate quit risk are distinct from elapsed-time debounce presentation. |
| ShellWait.swift | ShellWait helper | keep | Used by PullRequestDocumentFlowTests and BridgeAttachAssemblyTests to bound fixture sentinel waits and quote paths. |
| SidebarGroupColorIdentityTests.swift | SidebarGroupColorIdentityTests | keep | Move/remove/override/undo/restore must preserve group color identity and malformed optional colors must not drop groups; fix 9eba82d8 (#778). |
| SidebarHostedTestHarness.swift | SidebarHostedTestHarness / SidebarHostedTestWindow (support) | keep | Used by SidebarSearchInteractionTests and PrimaryContentFocusRouterTests; hosts real responder/layout behavior rather than testing the helper itself. |
| SidebarHoverIntegrationTests.swift | SidebarHoverIntegrationTests | keep | Covers native host ownership, stale pane-drop identity, preserved running panes, and cyclic/large/deep accessibility searches. |
| SidebarNativeOutlineViewTests.swift | SidebarNativeOutlineViewTests | keep | Covers actual outline selection, hosted accessibility actions, expansion/collapse, node identity and drag cleanup/validation; fix 0874f0d6 (#769). |
| SidebarSearchInteractionTests.swift | SidebarSearchInteractionTests | keep | Drives AppKit search arrows/Return into mounted surfaces and nested scrolling; invalidation distinguishes display-only changes from meaningful chrome changes; fix 64bd54aa. |
| SidebarSplitControllerTests.swift | SidebarSplitControllerReclampTests | keep | Small boundary table distinguishes user-selected rail, active divider drag and restoration of prior expanded width; different contract from simple width clamping. |
| SidebarSplitControllerTests.swift | SidebarSplitControllerTests | keep | Covers native hidden geometry, focus handoff/rollback, delayed commands, divider hit testing and visible/key-window accessibility readiness. |
| SidebarTintContrastTests.swift | SidebarTintContrastTests | keep | Independently computes WCAG text/non-text ratios across standard/high-contrast appearances; moved from script gate in `15c0e65c` (#514). |
| SidebarWorkspaceDragSourceTests.swift | SidebarWorkspaceDragSourceTests | keep | Original drag callback must finish exactly once and ordinary clicks must not start a drag; fix 0874f0d6 (#769). |
| SidebarWorkspaceMoveIndexTests.swift | SidebarWorkspaceMoveIndexTests | keep | Visible-to-stored index translation preserves hidden/pinned rows and uses current order after removal; fix 0874f0d6 (#769). |
| SidebarWorkspaceReorderPreviewTests.swift | SidebarWorkspaceReorderPreviewTests | keep | Gap hysteresis keeps the destination stable while variable-height rows move; distinct from stored-order index translation; fix 0874f0d6 (#769). |
| SourceContract.swift | SourceContract helper | keep | Live consumer `PaneChangeClassificationTests` uses source loading and declaration extraction; deletion depends on that other chunk's verdict. |
| SourceOffsetMapperTests.swift | SourceOffsetMapperTests | keep | Parser source locations use UTF-8 columns; multibyte and out-of-line bounds are distinct from rendered UTF-16 selection mapping. |
| StableDataDigestTests.swift | StableDataDigestTests | keep | Missing snapshot must override digest deduplication or shutdown can leave no restore file; data-loss contract, not a hash self-test. |
| SubprocessSafetyTests.swift | SubprocessSafetyTests | keep | Executes real shell quoting with substitution/newline/quote payloads and verifies oversized stdout/stderr fails instead of returning partial data. |
| SurfaceRemountOnSplitCollapseTests.swift | SurfaceRemountOnSplitCollapseTests | keep | Explicit INT-600/INT-562 remount/focus contracts plus viewport/background fixes c225d773 (#577), dc30d29d (#643); lifecycle E2E does not assert layer/scrollbar/orphan-nudge details. |
| TemporaryDirectory.swift | TemporaryDirectory helper | keep | Widely used across core, app, helper, hook, and secure-file tests for isolated filesystem lifetime. |
| TerminalAppearancePreferencesTests.swift | TerminalAppearancePreferencesTests | keep | Font config injection, inherited parent-terminal contamination, nested session markers, and locale precedence guard terminal spawn boundaries (#602; INT-140). |
| TerminalDiagnosticsTests.swift | TerminalDiagnosticsTests | keep | Actual private/path/control-containing environment inputs exercise redaction and public-log privacy. |
| TerminalPaneLayoutDecodeDepthTests.swift | TerminalPaneLayoutDecodeDepthTests | keep | INT-524 untrusted recursive JSON rejection must happen before stack overflow; bare-layout and session-shaped paths are distinct. |
| TerminalPanelWindowTests.swift | TerminalPanelWindowTests | keep | Guards actual event dispatch, promotion suppression under sheets/modal/foreign windows and eviction re-key prevention; regression fix fd935912. |
| TerminalPaneTitleEditFlagTests.swift | TerminalPaneTitleEditFlagTests | keep | User-authored title flags must survive decode/remint/reopen and release sanitized-away pins; runtime title-update tests do not cover reconstruction. |
| TestClock.swift | TestClock helper | keep | Used by `BridgePermissionCoordinatorTests` for deterministic permission deadlines. |
| TestData.swift | TestData fixture factories | delete (done) | No `TestData` reference exists anywhere in Tests/ outside this declaration; its pane/session/workspace factories have no consumers. Delete entire file. |
| TestScheduler.swift | TestScheduler helper | keep | Used by AgentTranscriptLiveRefreshTests, SessionPersistenceCheckpointTests, and SessionPersistenceLoadTests. |
| TOMLConfigCodecTests.swift | TOMLConfigCodecTests | keep | Already table-consolidated parser limits, invalid types, quoted keys/headers, multiline preservation, and stable re-encoding protect user data; fix `b06839d3`. |
| TypedPaneSnapshotRoundTripTests.swift | TypedPaneSnapshotRoundTripTests | keep | Malformed SSH plans must throw rather than silently become local execution (INT-775). |
| UnicodeHygieneTests.swift | UnicodeHygieneTests | keep | Hostile scalar admission, routing invisibles, script spoofing, and pathological input caps are security/parsing boundaries; already consolidated in `eb9f654e`. |
| UnixSocketClient.swift | UnixSocketClient helper | keep | Used by BridgeConnectionActorTests and BridgeConnectionSupervisorTests for actual socket interactions. |
| URLClassifierTests.swift | URLClassifierTests | keep; case deleted (done) | Untrusted URL scheme, phishing, IDN, userinfo, and unsafe scalar policies are security boundaries. Delete one of the two identical blockedURLs rows for https://\\u{043E}.com/ with .nonAsciiHost and nil delimiter (source lines 63 and 72); keep all other rows. |
| VisibleTextAgentStateReducerTests.swift | VisibleTextAgentStateReducerTests | keep | Hook authority, background attention retention, semantic waiting, and provider correction guard distinct failures; scraped prompt guard cites INT-714. |
| Wait.swift | waitUntil / waitUntilEventually / drainMainQueue helpers | keep | Live users across config watcher, persistence, transcript, recovery, and process suites; bounded polling and queue draining serve different synchronization needs. |
| WorkingDirectoryCanonicalizationTests.swift | WorkingDirectoryCanonicalizationTests | keep | INT-498 symlinked-home regression is exercised through divergent canonical forms and duplicate notification contexts. |
| WorkingDirectoryValidatorTests.swift | WorkingDirectoryValidatorTests | keep | Separates display cwd from spawn ownership and rejects remote URLs, NULs, traversal, and symlink escapes. |
| WorkspaceAttentionReducerHeartbeatTests.swift | WorkspaceAttentionReducerHeartbeatTests | keep | Coarsened activity avoids repeated observable publishes while retaining real field changes and due freshness heartbeats. |
| WorkspaceAttentionReducerTests.swift | WorkspaceAttentionReducerTests | keep | Pending-prompt priority (INT-506), sibling isolation (PR #149), authoritative clear, and idempotent unread accounting protect actual attention state. |
| WorkspaceEmojiFieldTests.swift | WorkspaceEmojiFieldTests | keep | Exercises real text insertion, grapheme replacement, deferred picker readiness, repeated request suppression and field reattachment without launching the character palette. |
| WorkspaceEmojiSidebarTests.swift | WorkspaceEmojiSidebarTests | keep | Guards emoji inclusion in the real row equality gate and spoken live-title label; these distinct render/accessibility contracts are not getter initialization checks. |
| WorkspaceEmojiTests.swift | WorkspaceEmojiTests | keep | Rejects malformed Unicode emoji sequences/oversized clusters and tolerates invalid optional snapshot values. |
| WorkspaceLayoutIntentTests.swift | WorkspaceLayoutIntentTests | keep | Nonfinite fraction handling and exported key allowlist protect hostile preset decoding and accidental live-state disclosure. |
| WorkspaceLayoutPresetTests.swift | WorkspaceLayoutPresetTests | keep | Untrusted depth/count/version limits, fresh daemon identity, and hostile-title ingestion are security/resource boundaries. |
| WorkspaceLeafOperationsTests.swift | WorkspaceLeafOperationsTests | delete (done) | Single test exercises straightforward recursive ID lookup with one positive and one negative result; no regression history or deeper mutation contract found. Delete documentGroupLookupFindsOnlyItsOwnID and its file-private pane/group fixtures; retain production lookup used by document views. |
| WorkspaceNavigationOrderTests.swift | WorkspaceNavigationOrderTests | keep | Frozen traversal avoids b/a cycling after sticky release and skips closed workspaces; review-fix history 63e9c8ef (#308). |
| WorkspaceNotificationTrackerTests.swift | WorkspaceNotificationTrackerTests | keep | Mute/unmute baseline regression INT-598, focus-flap deduplication, per-pane priority, and subtitle sanitization are distinct notification contracts. |
| WorkspaceTreeReducerTests.swift | WorkspaceTreeReducerTests | keep | Duplicate identity rejection prevents ambiguous tree mutation; after-source insertion also checks missing-source refusal. |
| WorktreeWorkspaceProjectionTests.swift | WorktreeWorkspaceProjectionTests | keep | Component-aware paths, remote exclusion, stale directory exclusion, and deepest-worktree ownership prevent misrouting across workspace boundaries. |
