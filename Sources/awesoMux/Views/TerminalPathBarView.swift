import AppKit
import AwesoMuxCore
import DesignSystem
import SwiftUI

struct TerminalPathBarView: View {
    let session: TerminalSession
    /// Types text into the session's active pane (no trailing newline). Supplied
    /// by `SessionDetailView`, which holds the `GhosttyRuntime`. Used by the PR
    /// chip's ⌥-click checkout; the chip decides whether sending is safe first.
    var sendTextToActivePane: (String) -> Void = { _ in }
    /// Supplied by `SessionDetailView` so the bridge-cwd poll can write back
    /// fresh paths. Defaults to nil so existing callers (tests, previews) compile
    /// unchanged.
    var sessionStore: SessionStore? = nil
    /// Mirrors `appSettingsStore.terminal.value.commandBridgeEnabled` at the call
    /// site. Passed explicitly so this view stays environment-free and testable.
    var isCommandBridgeEnabled: Bool = false
    /// Requests that the active local workspace root open in a user-selected IDE.
    var openInIDE: (() -> Void)?
    var openInIDEWithApp: ((URL, InstalledIDE) -> Void)?
    var isOpenInIDEEnabled = false
    var idePriority: [String] = []
    @Binding var presentedMenu: PathBarMenu?

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.awAccent) private var accentResolver
    @State private var model: TerminalPathBarModel = .placeholder
    @State private var installedIDEs: [InstalledIDE] = []
    @State private var ideTargetURLForOpenMenu: URL?
    @State private var revealURLForOpenMenu: URL?
    @State private var copyPathForOpenMenu: String?
    @State private var hasResolved = false
    /// The active pane the current `model` was built for. Used to re-seed the cheap
    /// preview on a pane SWITCH (vs same-pane title churn), so a switch never paints
    /// the previous pane's stale path/branch/chips while `make()` resolves.
    @State private var resolvedPaneID: TerminalPane.ID?
    /// The make()-affecting inputs (cwd / pane / remote / focus) of the last resolve.
    /// Lets the resolve task tell a substantive re-fire from title-only churn so the
    /// latter is debounced instead of re-walking the repo on every OSC title tick
    /// (INT-523). nil until the first resolve completes.
    @State private var lastResolveInputs: TerminalPathBarResolvePolicy.ResolveInputs?
    /// Open-time SNAPSHOT of the branch menu's contents — see `toggleBranchMenu()`.
    @State private var branchesForMenu: [String]?
    @State private var currentBranchForMenu: String?
    /// Invalidation token for an in-flight `toggleBranchMenu()` git lookup.
    /// Bumped by the two `.onChange` handlers below on `content`, and once
    /// synchronously before the lookup starts — see `toggleBranchMenu()` for
    /// why a live re-read through `session` can't do this job instead.
    @State private var branchMenuGeneration = 0
    /// Escape-key monitor, active only while a foldout is presented — see the
    /// `.onChange(of: presentedMenu)` handler for why this exists instead of
    /// `.onExitCommand`, and the class itself for the deinit backstop that a
    /// raw `Any?` token could not provide.
    @State private var escapeMonitor = PathBarMenuEscapeMonitor()

    var body: some View {
        content
            .onChange(of: PathBarExecutionAnnouncementState(pane: session.activePane)) {
                previous, current in
                guard
                    let message = PathBarExecutionAnnouncement.message(
                        from: previous,
                        to: current
                    )
                else { return }
                TerminalAccessibilityAnnouncer.announce(message)
            }
            // The model walks the filesystem and reads git state. That work must
            // never run on the render path (it would beachball under a chatty
            // PTY on a slow/network volume), so it runs in a detached task keyed
            // on `resolveKey` (cwd + title + pane + remote + window active state).
            // An in-place `git checkout` in the focused pane (cwd unchanged) is
            // caught via the title change the new branch makes to the prompt — but
            // because a chatty agent TUI churns the title many Hz, the make() walk
            // is debounced to the title's settle (see the `.task` body and
            // TerminalPathBarResolvePolicy / INT-523), not run on every title tick.
            // Re-resolving on window-active also catches a checkout made while we
            // were in the background. Live HEAD watching remains a tracked follow-up.
            // Bridge-pane cwd poll — independent of `resolveKey`. Runs ONLY when
            // the command-bridge feature is on AND the active pane carries an
            // established bridge session. The key intentionally omits
            // `workingDirectory`: for a bridge pane that's the stale value (the
            // daemon shell never emits OSC 7), so keying on it would prevent the
            // poll from restarting after a cwd update writes back. Re-keying on
            // pane identity + focus is enough: a pane switch or feature-toggle
            // restarts the loop, and `.task(id:)` cancels the old loop on any key
            // change, stopping the poll when the view disappears or the pane
            // loses focus.
            .task(id: bridgePollKey) {
                guard let pane = session.activePane,
                    BridgeCwdRefreshPolicy.shouldRefreshCwdFromAmx(
                        bridgeEnabled: isCommandBridgeEnabled,
                        isBridgePane: pane.terminalBackendMetadata == AmxBackend.establishedSessionMetadata
                    )
                else { return }

                let sessionID = pane.terminalSessionID
                let paneID = pane.id
                let workspaceID = session.id

                // Immediate query on focus/activation, then poll every ~4 s while
                // selected. `try? Task.sleep` absorbs cancellation silently; the
                // `while !Task.isCancelled` guard ensures we stop cleanly when
                // `.task(id:)` tears this task down on a key change.
                while !Task.isCancelled {
                    // Read the LIVE pane from the store each iteration, NOT a
                    // value-type `session` snapshot frozen at `.task` start: that
                    // snapshot never advances after the first write-back, so
                    // `cwdUpdate` would re-issue the same `updatePane` every 4s
                    // (store churn + redundant SwiftUI invalidation). The store's
                    // current value reflects prior write-backs.
                    //
                    // Also RE-CHECK bridge-pane status here: when a daemon errors
                    // out or falls back to a local shell, terminalBackendMetadata
                    // is cleared to .empty — but bridgePollKey deliberately omits
                    // metadata, so this already-running loop is NOT cancelled by
                    // that change (only a NEW task instance would re-evaluate the
                    // start guard). Without this, the poll keeps spawning
                    // `amx cwd <dead-id>` every ~4s on a latched/exited pane for
                    // the view's whole lifetime. Stop when it's no longer a bridge.
                    guard
                        let livePane = sessionStore?.session(id: workspaceID)?
                            .layout.pane(id: paneID),
                        livePane.terminalBackendMetadata == AmxBackend.establishedSessionMetadata
                    else { break }
                    let current = livePane.workingDirectory
                    if let queried = await AmxBackend.queryCwd(sessionID),
                        let newCwd = BridgeCwdRefreshPolicy.cwdUpdate(current: current, queried: queried)
                    {
                        sessionStore?.updatePane(
                            sessionID: workspaceID,
                            paneID: paneID,
                            workingDirectory: newCwd
                        )
                    }
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .task(id: resolveKey) {
                let activePaneID = session.activePane?.id
                // Re-seed the cheap preview on first paint AND on a pane SWITCH (a
                // different active pane), so a switch never renders the PREVIOUS
                // pane's stale path/branch/chips/Reveal while `make()` resolves the
                // new one. NOT on same-pane title churn — that would blink the chips
                // (the carry-forward below preserves them there instead).
                if !hasResolved || activePaneID != resolvedPaneID {
                    model = .preview(session: session)
                }
                if resolvedPaneID != activePaneID { resolvedPaneID = activePaneID }

                // Reflect a known-remote active pane SYNCHRONOUSLY. Declared SSH
                // identity is authoritative even before title observation reports
                // a host. Without this, a local→remote transition keeps showing the stale local path,
                // chips, and Reveal/Copy through the async make() — clickable on a
                // pane that is no longer local. `content` gates on model.remoteHost,
                // so this flips to the remote indicator immediately. The model
                // helper guards each write on an ACTUAL change so a same-pane title
                // spinner (INT-523) doesn't re-invalidate the view on every OSC tick.
                let activeHost = session.activePane?.remotePresentationHost
                let activeExecutionPlan = session.activePane?.executionPlan ?? .local
                let activeHealth = session.activePane?.remoteConnectionHealth ?? .active
                model.synchronizeExecutionPresentation(with: session.activePane)

                // The inputs that drive make()'s OUTPUT (cwd / pane / remote / focus).
                // A re-fire that leaves these unchanged is title-only churn (see the
                // debounce below). Captured for BOTH the remote and local paths so a
                // remote→local transition reads as a change and resolves promptly
                // rather than being mistaken for title churn and debounced.
                let resolveInputs = TerminalPathBarResolvePolicy.ResolveInputs(
                    activePaneID: activePaneID,
                    workingDirectory: session.activePane?.workingDirectory
                        ?? session.workingDirectory,
                    executionPlan: activeExecutionPlan,
                    remoteHost: activeHost,
                    remoteConnectionHealth: activeHealth,
                    isActive: controlActiveState != .inactive
                )

                // Remote (SSH) pane: the local cwd/branch/git state is the STALE
                // LOCAL machine's, so `make()`'s filesystem walk + git reads would be
                // discarded — skip them entirely (title churn over SSH would repeat
                // the work). The remote indicator renders from model.remoteHost. Clear
                // chips only when set, for the same no-churn reason as the flip above.
                if activeExecutionPlan.remoteTarget != nil {
                    if model.pullRequest != nil { model.pullRequest = nil }
                    if model.gitStatus != nil { model.gitStatus = nil }
                    if model.ciStatus != nil { model.ciStatus = nil }
                    hasResolved = true
                    if lastResolveInputs != resolveInputs { lastResolveInputs = resolveInputs }
                    return
                }

                // INT-523: gate the uncached make() walk behind a title-settle
                // debounce. A high-frequency agent-TUI title spinner (Claude Code,
                // Codex) re-fires this task with cwd/pane/remote/focus all unchanged;
                // without the gate that re-walked the repo many times/sec (CPU heat,
                // scroll stutter). A substantive change resolves immediately; a
                // title-only re-fire waits for the title to settle — `.task(id:)`
                // cancels this pending walk on the next title tick, so make() runs at
                // most once per settle, while an in-place `git checkout` (cwd
                // unchanged, only the prompt-embedded title changes) still refreshes
                // the branch chip on settle.
                if TerminalPathBarResolvePolicy.classify(
                    previous: lastResolveInputs,
                    current: resolveInputs
                ) == .debounced {
                    do {
                        try await Task.sleep(for: TerminalPathBarResolvePolicy.titleSettleDelay)
                    } catch {
                        return  // a newer title tick cancelled us; its settle resolves
                    }
                }

                let session = session
                // Detached → does NOT inherit cancellation: this fs+git walk always
                // runs to completion even if a title tick cancels us mid-flight. The
                // `guard` below drops the stale result. Immediate-path bursts (rapid
                // cwd/pane changes) therefore each run one full walk — bounded and rare
                // versus the title churn this gates, so not worth threading a
                // cancellation checkpoint into the synchronous walk.
                let resolved = await Task.detached(priority: .utility) {
                    TerminalPathBarModel.make(session: session)
                }.value
                guard !Task.isCancelled else { return }

                // Advance the classifier baseline ONLY now that the walk has committed
                // (past the cancellation gate) — never before the await. If a title
                // tick cancels this task mid-walk, `lastResolveInputs` must stay at the
                // last RESOLVED inputs so the retry still classifies a substantive
                // change (e.g. a cwd change buried in agent title churn) as `.immediate`
                // and re-walks — instead of mistaking it for title-only churn and
                // debouncing the retry until the agent goes quiet (the path bar would
                // otherwise show the wrong repo/branch for the whole agent run).
                if lastResolveInputs != resolveInputs { lastResolveInputs = resolveInputs }

                // Carry the resolved PR + git status forward when the repo root AND
                // branch are unchanged so a mere title re-fire (which clears
                // `make`'s default-nil fields) doesn't flash the chips off and back
                // on. Both must match: comparing branch alone would carry repo A's
                // state into repo B when both sit on `main` during the lookup window.
                let previousPullRequest = model.pullRequest
                let previousGitStatus = model.gitStatus
                let previousCIStatus = model.ciStatus
                let previousRepoRoot = model.repoRootPath
                let previousBranch = model.gitBranch
                model = resolved
                if resolved.repoRootPath == previousRepoRoot,
                    resolved.gitBranch == previousBranch
                {
                    model.pullRequest = previousPullRequest
                    model.gitStatus = previousGitStatus
                    model.ciStatus = previousCIStatus
                }
                hasResolved = true

                // A pane that became remote between the sync check and now is caught
                // by the next resolve (remoteHost is in resolveKey); here we know the
                // active pane is local, so proceed to the local lookups.

                // Gate git/gh on the VALIDATED repo root — never run a subprocess
                // against a `.git` that failed the model's admin-dir validation.
                guard let repoRoot = resolved.validatedRepoRootPath else {
                    model.pullRequest = nil
                    model.gitStatus = nil
                    model.ciStatus = nil
                    return
                }

                // The PR and CI lookups need a real local branch: a `--branch ""`
                // would drop gh's filter and report some OTHER branch's state. A
                // detached HEAD has none, so those chips clear up front. The local
                // git status still resolves below (dirt is working-tree-wide, keyed
                // on "" when detached).
                if resolved.gitBranch == nil {
                    model.pullRequest = nil
                    model.ciStatus = nil
                }

                // Resolve the local git status AND the remote PR/CI lookups all
                // concurrently, painting each chip AS ITS OWN lookup completes, so
                // none holds the others hostage — a slow `gh` call can't delay the
                // fast local dirty/ahead-behind chips, and PR and CI don't block one
                // another. The git status key carries the branch (or "" when
                // detached) so an in-place switch refreshes ahead/behind. All three
                // resolvers are TTL-cached, so the frequent title-driven re-fires hit
                // cache instead of spawning. The group is torn down with this `.task`
                // when `resolveKey` changes.
                let statusBranch = resolved.gitBranch ?? ""
                await withTaskGroup(of: PathBarChipLookup.self) { group in
                    group.addTask {
                        .gitStatus(
                            await GitStatusResolver.shared.status(
                                repoRoot: repoRoot,
                                branch: statusBranch
                            ))
                    }
                    if let branch = resolved.gitBranch {
                        group.addTask {
                            .pullRequest(
                                await PullRequestResolver.shared.pullRequest(
                                    repoRoot: repoRoot,
                                    branch: branch
                                ))
                        }
                        group.addTask {
                            .ci(
                                await CIStatusResolver.shared.status(
                                    repoRoot: repoRoot,
                                    branch: branch
                                ))
                        }
                    }
                    for await lookup in group {
                        guard !Task.isCancelled else { break }
                        switch lookup {
                        case .gitStatus(let gitStatus):
                            model.gitStatus = gitStatus
                        case .pullRequest(let pullRequest):
                            model.pullRequest = pullRequest
                        case .ci(let ciStatus):
                            model.ciStatus = ciStatus
                        }
                    }
                }
            }
    }

    private var resolveKey: ResolveKey {
        let pane = session.activePane
        return ResolveKey(
            activePaneID: pane?.id,
            workingDirectory: pane?.workingDirectory ?? session.workingDirectory,
            paneTitle: pane?.title ?? session.title,
            fallbackProject: session.title,
            isActive: controlActiveState != .inactive,
            executionPlan: pane?.executionPlan ?? .local,
            remoteHost: pane?.remotePresentationHost,
            remoteConnectionHealth: pane?.remoteConnectionHealth ?? .active
        )
    }

    /// Inputs whose change invalidates an open foldout (pane switch, workspace
    /// switch, remote flip). Title churn is deliberately excluded — an agent TUI
    /// retitles many times a second and must not flicker the menu closed.
    private var menuDismissKey: MenuDismissKey {
        MenuDismissKey(
            activePaneID: session.activePane?.id,
            remoteHost: session.activePane?.remotePresentationHost,
            workingDirectory: session.activePane?.workingDirectory ?? session.workingDirectory
        )
    }

    /// Key for the bridge-pane cwd poll task.
    ///
    /// Deliberately omits `workingDirectory`: for a bridge pane that is always
    /// the stale OSC-7 value, so including it would cause the poll to restart on
    /// every write-back, spinning forever. Pane identity + feature flag + focus
    /// state is the correct minimal key: a pane switch, feature toggle, or window
    /// focus change restarts the poll; everything else lets it run uninterrupted.
    private var bridgePollKey: BridgePollKey {
        BridgePollKey(
            activePaneID: session.activePane?.id,
            isCommandBridgeEnabled: isCommandBridgeEnabled,
            isActive: controlActiveState != .inactive
        )
    }

    /// `↑N ↓M` suffix for the branch chip, omitting whichever side is zero; nil
    /// when in sync (or no upstream), so the hint self-suppresses.
    private var aheadBehindHint: String? {
        guard let status = model.gitStatus, status.ahead > 0 || status.behind > 0 else {
            return nil
        }
        // Cap the displayed magnitude (a just-fetched branch can be thousands
        // behind) so the chip can't blow out the chrome — matching the dirty
        // chip's `+999+` cap. The spoken label below keeps the exact counts.
        func capped(_ count: Int) -> String { count > 999 ? "999+" : "\(count)" }
        var parts: [String] = []
        if status.ahead > 0 { parts.append("↑\(capped(status.ahead))") }
        if status.behind > 0 { parts.append("↓\(capped(status.behind))") }
        return parts.joined(separator: " ")
    }

    /// Spoken counterpart to `aheadBehindHint` (arrows read poorly under VoiceOver).
    private var aheadBehindAccessibility: String? {
        guard let status = model.gitStatus, status.ahead > 0 || status.behind > 0 else {
            return nil
        }
        var parts: [String] = []
        if status.ahead > 0 { parts.append("\(status.ahead) ahead") }
        if status.behind > 0 { parts.append("\(status.behind) behind") }
        return parts.joined(separator: ", ")
    }

    private var canOpenInIDE: Bool {
        isOpenInIDEEnabled
            && ExecutionContext(plan: model.executionPlan)
                .capability(.inspectLocalFilesystem).isAllowed
            && model.revealURL != nil
    }

    private var content: some View {
        HStack(spacing: 8) {
            if let remoteHost = model.remoteHost {
                // Remote (SSH) session: the local cwd/git affordances would point
                // at the wrong machine, so show only a remote indicator.
                remoteIndicator(host: remoteHost)
                Spacer(minLength: 8)
            } else {
                localContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // minHeight (not a fixed height) so the row grows with Dynamic Type
        // instead of clipping the scaling path/branch text at large sizes; it
        // still reads as the shared bottom-chrome height at default sizes.
        .frame(minHeight: AwSpacing.footerChrome)
        .background {
            Color.aw.surface.chrome
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.aw.border2)
                        .frame(height: 0.5)
                }
        }
        .onChange(of: menuDismissKey) {
            presentedMenu = nil
            // A pane switch, workspace switch, or same-pane `cd` (all folded
            // into `menuDismissKey`, per its own doc comment) invalidates any
            // branch-menu lookup in flight against the OLD pane/repo.
            branchMenuGeneration += 1
        }
        .onChange(of: presentedMenu) { _, newValue in
            // Covers the menu-ABA case `toggleBranchMenu()`'s own guard can't
            // see: nil → open → nil (or a re-open) during the await. Any
            // change here — this menu's or the open-target menu's — means
            // the world the pending lookup was snapshotted against no longer
            // holds, so invalidate unconditionally.
            branchMenuGeneration += 1

            // Escape-to-dismiss via `PathBarMenuEscapeMonitor` (a local
            // NSEvent monitor), NOT `.onExitCommand`/`.onKeyPress`: the
            // foldouts never take key focus — the terminal NSView keeps first
            // responder by design (focus-stealing chrome has caused documented
            // surface-blanking bugs) — so focus-based Escape handling can
            // never fire. The monitor runs only while a menu is presented;
            // Esc typed into the terminal is untouched otherwise.
            if newValue != nil {
                escapeMonitor.start { presentedMenu = nil }
            } else {
                escapeMonitor.stop()
            }
        }
        .onDisappear {
            // Prompt teardown when the path bar unmounts with a menu open;
            // the monitor's `isolated deinit` is the backstop for teardowns
            // where SwiftUI skips this callback.
            escapeMonitor.stop()
        }
    }

    private func remoteIndicator(host: String) -> some View {
        let copy = Self.remoteIndicatorCopy(host: host, health: model.remoteConnectionHealth)
        return HStack(spacing: 6) {
            Image(systemName: copy.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copy.health == .possiblyStale ? Color.aw.yellow : Color.aw.text3)
                .accessibilityHidden(true)

            Text(host)
                .awFont(AwFont.Mono.meta).fontWeight(.semibold)
                .foregroundStyle(Color.aw.text2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .help(copy.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(copy.accessibilityLabel)
        .accessibilityHint(copy.accessibilityHint)
    }

    private nonisolated static func remoteIndicatorCopy(
        host: String,
        health: RemoteConnectionHealth
    ) -> RemoteIndicatorCopy {
        switch health {
        case .active:
            RemoteIndicatorCopy(
                health: health,
                icon: "network",
                help: "Remote session on \(host). Local Path Bar features (git, reveal, copy) are unavailable over SSH.",
                accessibilityLabel: "Remote session on \(host)",
                accessibilityHint: "Local path features are unavailable over SSH."
            )
        case .possiblyStale:
            RemoteIndicatorCopy(
                health: health,
                icon: "exclamationmark.triangle",
                help: "Network changed; this SSH session may be disconnected until SSH recovers or reports failure.",
                accessibilityLabel: "Possibly stale remote session on \(host)",
                accessibilityHint: "Network changed; this SSH session may be disconnected until SSH recovers or reports failure."
            )
        }
    }

    nonisolated static func remoteIndicatorCopySnapshot(
        host: String,
        health: RemoteConnectionHealth
    ) -> (
        health: RemoteConnectionHealth,
        icon: String,
        help: String,
        accessibilityLabel: String,
        accessibilityHint: String
    ) {
        let copy = remoteIndicatorCopy(host: host, health: health)
        return (
            health: copy.health,
            icon: copy.icon,
            help: copy.help,
            accessibilityLabel: copy.accessibilityLabel,
            accessibilityHint: copy.accessibilityHint
        )
    }

    @ViewBuilder
    private var localContent: some View {
        HStack(spacing: 8) {
            openTargetControls

            Spacer(minLength: 8)

            if let branch = model.branch {
                Button {
                    Task { await toggleBranchMenu() }
                } label: {
                    PathBarChip(
                        icon: "arrow.triangle.branch",
                        label: branch,
                        tone: Color.aw.peach,
                        hint: aheadBehindHint
                    )
                    .frame(minHeight: 24)
                    .contentShape(RoundedRectangle(cornerRadius: AwRadius.pill))
                }
                .buttonStyle(.plain)
                // Stays enabled even on detached HEAD / no repo: the right-click
                // Copy Branch action and the a11y action below must survive that
                // state. `toggleBranchMenu()` already no-ops via its own `guard
                // let` when `validatedRepoRootPath`/`gitBranch` are nil, so the
                // button is safely inert rather than actually disabled.
                .help(branchChipHelp(branch: branch))
                // Mirrors `PathBarPRChip`/`PathBarCIChip`: the Button carries
                // accessibility identity and the context menu; the label
                // (`PathBarChip`) is plain visuals only.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(branchChipAccessibilityLabel(branch: branch))
                .accessibilityHint(
                    // A promise of an action that won't fire is a lie to
                    // VoiceOver users — only advertise the foldout when
                    // `toggleBranchMenu()` can actually open it.
                    model.gitBranch != nil && model.validatedRepoRootPath != nil
                        ? "Opens the branch list."
                        : ""
                )
                .accessibilityAction(named: "Copy Branch") {
                    copyBranch(branch)
                }
                .contextMenu {
                    Button {
                        copyBranch(branch)
                    } label: {
                        Label("Copy Branch", systemImage: "doc.on.doc")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if presentedMenu == .branches {
                        // Same in-place foldout mechanism as the open-target menu:
                        // menu above the control, spacer providing the shared gap.
                        VStack(alignment: .trailing, spacing: 0) {
                            BranchListMenu(
                                // The open-time SNAPSHOT, not live model state: a title-churn
                                // re-resolve while the menu is open must not repin a branch
                                // the list wasn't computed against.
                                currentBranch: currentBranchForMenu,
                                otherBranches: branchesForMenu,
                                canInsertCheckout: session.activeAgentKind == .shell,
                                accent: Color.aw.accent(accentResolver.accent),
                                onSelect: { selected in
                                    presentedMenu = nil
                                    if session.activeAgentKind == .shell {
                                        sendTextToActivePane(
                                            BranchListMenuModel.checkoutCommand(branch: selected)
                                        )
                                    } else {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(selected, forType: .string)
                                    }
                                }
                            )

                            Color.clear.frame(height: 24 + AwSpacing.overlayGap)
                        }
                    }
                }
                .zIndex(1)
            }

            if let dirtyCount = model.gitStatus?.dirtyCount, dirtyCount > 0 {
                PathBarDirtyChip(count: dirtyCount)
            }

            if let pullRequest = model.pullRequest {
                PathBarPRChip(
                    pullRequest: pullRequest,
                    // Gate on a shell session so checkout is never injected into a
                    // Claude/Codex agent pane (which would corrupt the agent's
                    // input). agentKind is session-scoped, so this proves "not an
                    // agent session" — not "the active pane is at a prompt"; a
                    // shell session's pane could still be in a TUI. The no-newline
                    // payload (below) is the backstop there: the user sees the
                    // typed command and chooses whether to run it.
                    canCheckout: session.activeAgentKind == .shell,
                    onOpen: { openInBrowser(pullRequest.url) },
                    onCopyURL: { copyURL(pullRequest.url) },
                    onCheckout: { sendTextToActivePane("gh pr checkout \(pullRequest.number)") }
                )
            }

            if let ciStatus = model.ciStatus {
                PathBarCIChip(
                    ciStatus: ciStatus,
                    // Two gates: a shell session (never type into an agent pane), AND
                    // a validated repo slug (the inserted `gh run` command pins
                    // `--repo <slug>`; without it there's no safe command to insert,
                    // so the action must not be advertised). The no-newline payload
                    // is the backstop — the user sees the command before running it.
                    canRunInPane: session.activeAgentKind == .shell && ciStatus.repoSlug != nil,
                    onOpen: { openInBrowser(ciStatus.url) },
                    onCopyURL: { copyURL(ciStatus.url) },
                    onRunInPane: {
                        // Pin the command to the run's own repo with `--repo`: a run
                        // id is only meaningful within its repo, and the pane's shell
                        // may be cd'd elsewhere. Without a validated slug, degrade to
                        // copy rather than insert a repo-ambiguous command.
                        guard let slug = ciStatus.repoSlug else {
                            copyURL(ciStatus.url)
                            return
                        }
                        switch ciStatus.state {
                        case .running:
                            sendTextToActivePane("gh run watch \(ciStatus.runDatabaseID) --repo \(slug)")
                        case .failing:
                            sendTextToActivePane("gh run view \(ciStatus.runDatabaseID) --repo \(slug) --log-failed")
                        }
                    }
                )
            }
        }
    }

    private var pathButton: some View {
        Button {
            handleOpenTargetClick()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)

                Text(model.project)
                    .awFont(AwFont.Mono.meta).fontWeight(.semibold)
                    .foregroundStyle(Color.aw.text2)
                    .lineLimit(1)
                    .layoutPriority(1)

                if !model.path.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.aw.textFaint)
                        .accessibilityHidden(true)

                    Text(model.path)
                        .awFont(AwFont.Mono.meta)
                        .foregroundStyle(Color.aw.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                }

                Rectangle()
                    .fill(Color.aw.textFaint.opacity(0.65))
                    .frame(width: 0.5, height: 12)
                    .accessibilityHidden(true)

                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.aw.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: 24)
            .contentShape(RoundedRectangle(cornerRadius: AwRadius.pill))
        }
        .buttonStyle(TerminalPathButtonStyle())
        .help(
            model.revealURL == nil
                ? "Working directory unavailable"
                : "Open workspace options. Command-click to reveal in Finder."
        )
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(
            model.revealURL == nil
                ? "Working directory is unavailable."
                : "Opens workspace options. Command-click to reveal in Finder."
        )
        .disabled(model.revealURL == nil)
        // Copy lives in the context menu visually, but VoiceOver / keyboard
        // users can't reliably summon that — expose it as a first-class
        // accessibility action too.
        .accessibilityAction(named: "Copy Path") {
            copyPath()
        }
        .accessibilityAction(named: "Reveal in Finder") {
            revealInFinder()
        }
        .accessibilityActions {
            if let openInIDE, canOpenInIDE {
                Button("Open in IDE") {
                    openInIDE()
                }
            }
        }
        .contextMenu {
            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(model.revealURL == nil)

            Button {
                copyPath()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            if let openInIDE, canOpenInIDE {
                Button {
                    openInIDE()
                } label: {
                    Label("Open in IDE…", systemImage: "curlybraces.square")
                }
            }
        }
    }

    private var openTargetControls: some View {
        pathButton
            .overlay(alignment: .bottomLeading) {
                if presentedMenu == .openTarget {
                    // This is intentionally an in-place foldout, rather than a native
                    // popover: it sits above the path control with the shared overlay
                    // gap, without a speech-bubble arrow competing with the workspace name.
                    VStack(alignment: .leading, spacing: 0) {
                        OpenTargetMenu(
                            installedIDEs: orderedInstalledIDEs,
                            showsIDEOptions: ideTargetURLForOpenMenu != nil,
                            accent: Color.aw.accent(accentResolver.accent),
                            appIcon: { AnyView(appIcon(for: $0)) },
                            onOpenInIDEWithApp: { ide in
                                presentedMenu = nil
                                guard let targetURL = ideTargetURLForOpenMenu else { return }
                                openInIDEWithApp?(targetURL, ide)
                            },
                            onOpenInFinder: {
                                presentedMenu = nil
                                guard let revealURL = revealURLForOpenMenu else { return }
                                revealInFinder(revealURL)
                            },
                            onCopyPath: {
                                guard let capturedPath = copyPathForOpenMenu else { return }
                                copyPath(capturedPath)
                            }
                        )

                        // Align to the path controls' minimum touch height, plus
                        // the shared visual gap for elevated overlays.
                        Color.clear.frame(height: 24 + AwSpacing.overlayGap)
                    }
                    .zIndex(1)
                }
            }
    }

    private var orderedInstalledIDEs: [InstalledIDE] {
        IDEChoice.ordered(installed: installedIDEs, priority: idePriority)
    }

    private func handleOpenTargetClick() {
        switch PathBarOpenTargetAction.forClick(modifierFlags: NSEvent.modifierFlags) {
        case .showMenu:
            Task { await toggleOpenTargetMenu() }
        case .revealInFinder:
            revealInFinder()
        }
    }

    @MainActor
    private func toggleOpenTargetMenu() async {
        if presentedMenu == .openTarget {
            presentedMenu = nil
            return
        }
        await presentOpenTargetMenu()
    }

    @MainActor
    private func presentOpenTargetMenu() async {
        revealURLForOpenMenu = model.revealURL
        copyPathForOpenMenu = model.copyPath
        ideTargetURLForOpenMenu = nil
        guard canOpenInIDE else {
            installedIDEs = []
            presentedMenu = .openTarget
            return
        }

        let model = model
        let activeWorkingDirectory = session.activePane?.workingDirectory ?? session.workingDirectory
        let priority = idePriority
        let openTargets = await Task.detached(priority: .utility) {
            let targetURL = IDEOpenTarget.targetURL(
                from: model,
                activeWorkingDirectory: activeWorkingDirectory
            )
            let installedIDEs =
                targetURL.map { _ in
                    InstalledIDEDiscovery.installed(
                        extraBundleIdentifiers: priority,
                        resolveApplicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                        displayName: InstalledIDEDiscovery.bundleDisplayName
                    )
                } ?? []
            return (targetURL, installedIDEs)
        }.value

        guard let targetURL = openTargets.0 else {
            installedIDEs = []
            presentedMenu = .openTarget
            return
        }

        ideTargetURLForOpenMenu = targetURL
        installedIDEs = openTargets.1
        presentedMenu = .openTarget
    }

    @MainActor
    private func toggleBranchMenu() async {
        if presentedMenu == .branches {
            presentedMenu = nil
            return
        }
        // Snapshot before the await: the model can re-resolve and the active pane
        // can change while git runs; the menu must open against the repo/branch
        // the user clicked on — or not at all.
        guard let repoRoot = model.validatedRepoRootPath,
            let currentBranch = model.gitBranch
        else { return }
        branchMenuGeneration += 1
        let generation = branchMenuGeneration
        let branches = await BranchListResolver.shared.branches(repoRoot: repoRoot)
        // Drop a stale completion. Four things can invalidate this lookup
        // mid-flight: a pane switch, a workspace switch, a same-pane `cd`
        // (all three bump the token via `.onChange(of: menuDismissKey)`), or
        // the user opening/closing a menu during the await — the ABA case
        // where `presentedMenu` goes nil → open → nil and back
        // (`.onChange(of: presentedMenu)`). None of these can be read live
        // off `session`: it's a value-type property captured with this view
        // struct at `.task` start, so `session.activePane?.id` read here
        // after the await is the SAME frozen snapshot compared against
        // itself, never the live pane (the bridge-cwd poll's live-store-read
        // comment above is the identical lesson) — hence the counter.
        guard generation == branchMenuGeneration else { return }
        // The pinned row shows the SANITIZED display branch (`model.branch`),
        // never the raw `gitBranch` — a bidi-spoofed HEAD must not bypass the
        // chip's own defense just because it's rendered from the menu instead.
        currentBranchForMenu = model.branch
        // nil stays nil: the menu distinguishes "git failed" from "one branch".
        // `otherBranches` still dedupes against the RAW `currentBranch`: that
        // must match `for-each-ref`'s byte-for-byte output, not the sanitized
        // display string.
        branchesForMenu = branches.map {
            BranchListMenuModel.otherBranches(branches: $0, currentBranch: currentBranch)
        }
        presentedMenu = .branches
    }

    private func appIcon(for ide: InstalledIDE) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: ide.applicationURL.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    private func revealInFinder() {
        guard let revealURL = model.revealURL else {
            return
        }

        revealInFinder(revealURL)
    }

    private func revealInFinder(_ revealURL: URL) {
        guard
            ExecutionContext(plan: model.executionPlan)
                .capability(.revealInFinder).isAllowed
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
    }

    private func copyPath() {
        copyPath(model.copyPath)
    }

    private func copyPath(_ path: String) {
        guard
            ExecutionContext(plan: model.executionPlan)
                .capability(.copyLocalPath).isAllowed
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Visual tooltip for the branch chip: arrows, not spoken words — mirrors
    /// `PathBarChip`'s old internal `.help`, now that the label moved to the
    /// wrapping Button.
    private func branchChipHelp(branch: String) -> String {
        aheadBehindHint.map { "Git branch \(branch), \($0)" } ?? "Git branch \(branch)"
    }

    /// Spoken counterpart of `branchChipHelp` — `aheadBehindAccessibility`
    /// reads "N ahead, M behind" instead of arrow glyphs.
    private func branchChipAccessibilityLabel(branch: String) -> String {
        aheadBehindAccessibility.map { "Git branch \(branch), \($0)" } ?? "Git branch \(branch)"
    }

    private func copyBranch(_ branch: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(branch, forType: .string)
    }

    private func openInBrowser(_ url: URL) {
        // The URL is https-gated at parse time, but it originates from the repo's
        // git remote (a trust boundary), so route it through the same classifier
        // every terminal hyperlink uses — it block-confirms homograph hosts,
        // embedded userinfo, bidi-spoofed paths, and non-allowlisted schemes.
        GhosttyRuntime.openURL(url)
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}
