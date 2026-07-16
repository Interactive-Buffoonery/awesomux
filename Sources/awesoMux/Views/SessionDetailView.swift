import AwesoMuxConfig
import AwesoMuxCore
import AppKit
import DesignSystem
import SwiftUI

struct SessionDetailView: View {
    let session: TerminalSession?
    let sessionStore: SessionStore
    let ghosttyRuntime: GhosttyRuntime
    let onRenameWorkspace: (TerminalSession) -> Void
    let onManagedSSHWorkspaceOffer: (TerminalSession.ID, TerminalPane.ID) -> Void
    /// Announcing reopen handler shared with the menu / keyboard command so the
    /// on-screen button posts the same VoiceOver feedback on both success and
    /// nil (INT-166 review: the button used to call the store directly and
    /// silently no-op when reopen returned nil).
    let onReopenClosedWorkspace: () -> Void
    let onOpenSelectedWorkspaceInIDE: () -> Void
    let onOpenSelectedWorkspaceInIDEWithApp: (URL, InstalledIDE) -> Void
    let onFooterHeightChange: (CGFloat) -> Void
    let hasRecoveryWarning: Bool
    let edgeTabStyle: SidebarEdgeTabPolicy.Style?
    let edgeTabVisibilitySource: SidebarVisibilitySource
    let sidebarPosition: AppearanceConfig.SidebarPosition
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var presentedPathBarMenu: PathBarMenu?

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 0) {
                        if session.needsAcknowledgement {
                            // No transition/animation here — animating this in/out
                            // resizes the terminal grid continuously mid-transition
                            // (worse than one instant jump; see libghostty resize
                            // gotchas elsewhere in this codebase). Tried and reverted.
                            NeedsInputBar(
                                session: session,
                                onAcknowledge: {
                                    // Workspace-scoped, matching the ⌘⇧K action the
                                    // button advertises: the banner shows when ANY
                                    // pane needs input, so an active-pane-only ack
                                    // silently no-ops whenever the attention sits on
                                    // a sibling pane in a split.
                                    sessionStore.acknowledgeAllPanes(in: session.id)
                                }
                            )
                        }

                        // INT-698 D4: the remote-agent permission banner for the
                        // active pane, above the terminal. Self-gates on
                        // `activePrompt != nil`; only mounted when a live bridge
                        // generation for the active pane has a coordinator.
                        if let terminalSessionID = session.layout.pane(id: session.activePaneID)?.terminalSessionID,
                            let coordinator = ghosttyRuntime.bridgeCoordinatorStore.coordinator(for: terminalSessionID)
                        {
                            BridgePermissionPromptView(coordinator: coordinator)
                        }

                        TerminalPaneView(
                            session: session,
                            sessionStore: sessionStore,
                            ghosttyRuntime: ghosttyRuntime,
                            onManagedSSHWorkspaceOffer: onManagedSSHWorkspaceOffer
                        )
                        .overlay(alignment: sidebarPosition == .left ? .leading : .trailing) {
                            SidebarEdgeTab(
                                style: edgeTabStyle,
                                visibilitySource: edgeTabVisibilitySource,
                                position: sidebarPosition,
                                terminalBackground: Color(
                                    nsColor: ghosttyRuntime.terminalBackgroundColor
                                )
                            )
                        }
                    }

                    if presentedPathBarMenu != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                presentedPathBarMenu = nil
                            }
                    }
                }

                TerminalPathBarView(
                    session: session,
                    sendTextToActivePane: { text in
                        ghosttyRuntime.sendText(text, toPane: session.activePaneID)
                    },
                    sessionStore: sessionStore,
                    isCommandBridgeEnabled: appSettingsStore.terminal.value.commandBridgeEnabled,
                    openInIDE: onOpenSelectedWorkspaceInIDE,
                    openInIDEWithApp: onOpenSelectedWorkspaceInIDEWithApp,
                    isOpenInIDEEnabled: appSettingsStore.workspaces.value.openInIDEEnabled,
                    idePriority: appSettingsStore.workspaces.value.defaultIDEPriority,
                    presentedMenu: $presentedPathBarMenu
                )
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onFooterHeightChange(height)
                }
            }
            .background(Color.aw.surface.terminal)
        } else {
            EmptyWorkspaceView(
                mode: emptyStateMode,
                onNewWorkspace: {
                    sessionStore.addSession(
                        groupName: appSettingsStore.workspaces.value.defaultGroup
                    )
                },
                onOpenRecent: onReopenClosedWorkspace,
                canReopenWorkspace: sessionStore.canReopenClosedWorkspace
            )
            .foregroundStyle(Color.aw.text2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.aw.surface.terminal)
            .overlay(alignment: sidebarPosition == .left ? .leading : .trailing) {
                SidebarEdgeTab(
                    style: edgeTabStyle,
                    visibilitySource: edgeTabVisibilitySource,
                    position: sidebarPosition,
                    terminalBackground: Color.aw.surface.terminal
                )
            }
            .onAppear {
                onFooterHeightChange(0)
            }
        }
    }

    private var emptyStateMode: EmptyWorkspaceMode {
        if hasRecoveryWarning {
            return .recovered
        }
        // A truly empty tree is a genuine cold launch / all-closed state; a
        // non-empty tree with no selection is a returning user between
        // workspaces, so don't greet them as new (INT-166 review).
        return sessionStore.groups.isEmpty ? .firstLaunch : .noSelection
    }
}

enum EmptyWorkspaceMode {
    case firstLaunch
    case noSelection
    case recovered
}

@MainActor
struct EmptyWorkspaceView: View {
    let mode: EmptyWorkspaceMode
    let onNewWorkspace: () -> Void
    let onOpenRecent: () -> Void
    let canReopenWorkspace: Bool

    @Environment(\.awAccent) private var accentResolver
    @State private var initialAccessibilityFocusRequest: EmptyWorkspaceInitialAccessibilityFocusRequest

    init(
        mode: EmptyWorkspaceMode,
        onNewWorkspace: @escaping () -> Void,
        onOpenRecent: @escaping () -> Void,
        canReopenWorkspace: Bool,
        initialAccessibilityFocusRequest: EmptyWorkspaceInitialAccessibilityFocusRequest =
            EmptyWorkspaceInitialAccessibilityFocusRequest()
    ) {
        self.mode = mode
        self.onNewWorkspace = onNewWorkspace
        self.onOpenRecent = onOpenRecent
        self.canReopenWorkspace = canReopenWorkspace
        _initialAccessibilityFocusRequest = State(
            initialValue: initialAccessibilityFocusRequest)
    }

    private var heading: LocalizedStringResource {
        switch mode {
        case .firstLaunch:
            return LocalizedStringResource(
                "welcome to awesoMux",
                comment: "Heading shown when the app has no workspaces on first launch."
            )
        case .noSelection:
            return LocalizedStringResource(
                "no workspace selected",
                comment: "Heading shown when workspaces exist but none is selected."
            )
        case .recovered:
            return LocalizedStringResource(
                "session set aside safely",
                comment: "Heading shown after an invalid saved session was quarantined."
            )
        }
    }

    private var bodyText: LocalizedStringResource {
        switch mode {
        case .recovered:
            return LocalizedStringResource(
                "We found a problem with your saved session and set it aside safely. Create a workspace with Command-N to start fresh.",
                comment: "Recovery explanation shown after an invalid saved session was quarantined."
            )
        case .firstLaunch, .noSelection:
            // Reopen is offered as a button, not a shortcut, so the copy only
            // names Command-N to match the actual bound keys (INT-166 review:
            // the hint used to advertise Cmd-N for reopen, which nothing binds).
            if canReopenWorkspace {
                return LocalizedStringResource(
                    "Create a workspace with Command-N, or reopen the last one you closed.",
                    comment: "Empty-state guidance when a recently closed workspace can be reopened."
                )
            }
            return LocalizedStringResource(
                "Create a workspace with Command-N.",
                comment: "Empty-state guidance when no recently closed workspace can be reopened."
            )
        }
    }

    var body: some View {
        let accentColor = Color.aw.accent(accentResolver.accent)

        VStack(alignment: .leading, spacing: 16) {
            // Decorative — the heading below carries the product name, so hide
            // this from VoiceOver to avoid announcing "awesoMux" twice.
            Brandmark(size: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(heading)
                    .awFont(AwFont.Mono.kicker)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(accentColor)
                    .accessibilityAddTraits(.isHeader)

                Text(bodyText)
                    .awFont(AwFont.UI.body)
                    .foregroundStyle(Color.aw.text3)
            }

            // ViewThatFits drops to a vertical stack at large Dynamic Type or
            // narrow widths, so neither button gets clipped past the 460pt cap.
            ViewThatFits(in: .horizontal) {
                actionButtons(axis: .horizontal)
                actionButtons(axis: .vertical)
            }
        }
        .padding(32)
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Let the real children (heading, body, buttons) carry the spoken copy
        // rather than a container label/hint that can diverge from what's on
        // screen and be swallowed under `.contain` (INT-166 review).
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButtons(axis: Axis) -> some View {
        let primary = Button {
            onNewWorkspace()
        } label: {
            Label("New Workspace", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .help("Create a new workspace")
        // SwiftUI's `.focusable()` produces a private, unlabelled KeyViewProxy
        // while its accessibility identifier lives on a separate virtual node.
        // The AppKit overlay gives the same visible button one stable keyboard
        // and VoiceOver identity without intercepting pointer input.
        .focusable(false)
        .accessibilityHidden(true)
        .overlay {
            EmptyWorkspacePrimaryActionFocusTarget(
                initialAccessibilityFocusRequest: initialAccessibilityFocusRequest,
                onActivate: onNewWorkspace
            )
            // ViewThatFits owns two alternate placements. Keep their AppKit
            // targets distinct while the shared request owns the one-shot.
            .id(axis)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }

        // Hide (not disable) the reopen button when there's nothing to reopen:
        // a dimmed control's disabled-reason hint is unreliable under VoiceOver,
        // and the body copy already adapts to whether reopen is offered.
        switch axis {
        case .horizontal:
            HStack(spacing: 10) {
                primary
                if canReopenWorkspace { reopenButton }
            }
        case .vertical:
            VStack(alignment: .leading, spacing: 10) {
                primary
                if canReopenWorkspace { reopenButton }
            }
        }
    }

    private var reopenButton: some View {
        Button {
            onOpenRecent()
        } label: {
            Label("Reopen Closed Workspace", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.bordered)
        .help("Reopen the most recently closed workspace (kept for 24 hours)")
    }
}

@MainActor
final class EmptyWorkspaceInitialAccessibilityFocusRequest {
    private(set) var isConsumed = false
    fileprivate let applicationIsActive: () -> Bool
    private var isTransferPending = false
    private weak var focusedButton: EmptyWorkspacePrimaryActionFocusButton?

    init(applicationIsActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.applicationIsActive = applicationIsActive
    }

    fileprivate func consume(
        byFocusing button: EmptyWorkspacePrimaryActionFocusButton
    ) -> Bool {
        guard shouldAttemptFocus(for: button),
            button.isReadyForInitialAccessibilityFocus
        else {
            return false
        }
        let previousFocusedButton = focusedButton
        button.setAccessibilityFocused(true)
        guard button.isAccessibilityFocused() else { return false }
        if previousFocusedButton !== button {
            previousFocusedButton?.setAccessibilityFocused(false)
        }
        focusedButton = button
        isConsumed = true
        isTransferPending = false
        return true
    }

    fileprivate func shouldAttemptFocus(
        for button: EmptyWorkspacePrimaryActionFocusButton
    ) -> Bool {
        if !isConsumed || isTransferPending { return true }
        return focusedButton !== button
            && focusedButton?.isAccessibilityFocused() == true
    }

    fileprivate func transferFocus(
        from retiringButton: EmptyWorkspacePrimaryActionFocusButton,
        in root: NSView?
    ) {
        guard isConsumed, retiringButton.isAccessibilityFocused() else { return }
        isTransferPending = true
        DispatchQueue.main.async { [weak self, weak root, weak retiringButton] in
            guard let self, let root else { return }
            root.layoutSubtreeIfNeeded()
            guard
                let replacement = EmptyWorkspaceAccessibilityFocusHandoff.target(in: root)
                    as? EmptyWorkspacePrimaryActionFocusButton,
                replacement !== retiringButton
            else { return }
            _ = self.consume(byFocusing: replacement)
        }
    }
}

@MainActor
private struct EmptyWorkspacePrimaryActionFocusTarget: NSViewRepresentable {
    let initialAccessibilityFocusRequest: EmptyWorkspaceInitialAccessibilityFocusRequest
    let onActivate: () -> Void

    func makeNSView(context: Context) -> EmptyWorkspacePrimaryActionFocusButton {
        let button = EmptyWorkspacePrimaryActionFocusButton()
        update(button)
        return button
    }

    func updateNSView(
        _ nsView: EmptyWorkspacePrimaryActionFocusButton,
        context: Context
    ) {
        update(nsView)
    }

    static func dismantleNSView(
        _ nsView: EmptyWorkspacePrimaryActionFocusButton,
        coordinator: Void
    ) {
        nsView.dismantle()
    }

    private func update(_ button: EmptyWorkspacePrimaryActionFocusButton) {
        button.update(
            onActivate: onActivate,
            initialAccessibilityFocusRequest: initialAccessibilityFocusRequest)
    }
}

@MainActor
final class EmptyWorkspacePrimaryActionFocusButton: NSButton {
    @MainActor
    private final class ActionDispatcher: NSResponder {
        weak var owner: EmptyWorkspacePrimaryActionFocusButton?
        nonisolated(unsafe) private var advertisesAction = true

        init(owner: EmptyWorkspacePrimaryActionFocusButton) {
            self.owner = owner
            super.init()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == #selector(performAction(_:)) {
                return advertisesAction
            }
            return super.responds(to: aSelector)
        }

        @objc func performAction(_ sender: Any?) {
            _ = owner?.performActivation()
        }

        func invalidate() {
            advertisesAction = false
            owner = nil
        }
    }

    var onActivate: (() -> Void)? {
        didSet { synchronizeActionDispatch() }
    }
    var initialAccessibilityFocusRequest: EmptyWorkspaceInitialAccessibilityFocusRequest? {
        didSet { scheduleInitialAccessibilityFocusIfNeeded() }
    }

    private var accessibilityFocused = false
    private var isRetired = false
    private var actionDispatcher: ActionDispatcher?
    private var focusAttemptIsScheduled = false
    private var readinessObservers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isEnabled: Bool {
        didSet { synchronizeActionDispatch() }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isTransparent = true
        refusesFirstResponder = false
        focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let accessibilityLabel = String(
            localized: "New Workspace",
            comment: "Empty workspace primary action label.")
        let accessibilityHelp = String(
            localized: "Create a new workspace",
            comment: "Empty workspace primary action help and tooltip.")
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(accessibilityHelp)
        setAccessibilityIdentifier(
            EmptyWorkspaceAccessibilityFocusHandoff.targetIdentifier)
        toolTip = accessibilityHelp
        synchronizeActionDispatch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowReadiness()
        scheduleInitialAccessibilityFocusIfNeeded()
    }

    override func layout() {
        super.layout()
        scheduleInitialAccessibilityFocusIfNeeded()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        scheduleInitialAccessibilityFocusIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(
        onActivate: @escaping () -> Void,
        initialAccessibilityFocusRequest: EmptyWorkspaceInitialAccessibilityFocusRequest
    ) {
        guard !isRetired else { return }
        self.onActivate = onActivate
        self.initialAccessibilityFocusRequest = initialAccessibilityFocusRequest
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard !isRetired || !accessibilityFocused else {
            self.accessibilityFocused = false
            return
        }
        if accessibilityFocused {
            guard let window, window.isVisible, window.isKeyWindow else {
                self.accessibilityFocused = false
                return
            }
        }
        self.accessibilityFocused = accessibilityFocused
        if accessibilityFocused {
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    override func isAccessibilityFocused() -> Bool {
        !isRetired && accessibilityFocused
    }

    override func accessibilityPerformPress() -> Bool {
        performActivation()
    }

    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        if action == #selector(ActionDispatcher.performAction(_:)) {
            return performActivation()
        }
        return super.tryToPerform(action, with: object)
    }

    @discardableResult
    private func performActivation() -> Bool {
        guard isActionable, let onActivate else { return false }
        onActivate()
        return true
    }

    private var isActionable: Bool {
        !isRetired && isEnabled && onActivate != nil
    }

    private func synchronizeActionDispatch() {
        guard isActionable else {
            target = nil
            action = nil
            actionDispatcher?.invalidate()
            actionDispatcher = nil
            return
        }
        let dispatcher = actionDispatcher ?? ActionDispatcher(owner: self)
        dispatcher.owner = self
        actionDispatcher = dispatcher
        target = dispatcher
        action = #selector(ActionDispatcher.performAction(_:))
    }

    func dismantle() {
        let focusRequest = initialAccessibilityFocusRequest
        focusRequest?.transferFocus(from: self, in: window?.contentView)
        isRetired = true
        onActivate = nil
        initialAccessibilityFocusRequest = nil
        stopObservingWindowReadiness()
        accessibilityFocused = false
        synchronizeActionDispatch()
    }

    fileprivate var isReadyForInitialAccessibilityFocus: Bool {
        guard
            let initialAccessibilityFocusRequest,
            !isRetired,
            initialAccessibilityFocusRequest.applicationIsActive(),
            let window,
            window.isVisible,
            window.isKeyWindow,
            window.occlusionState.contains(.visible),
            let root = window.contentView,
            let target = EmptyWorkspaceAccessibilityFocusHandoff.target(in: root)
        else { return false }
        return (target as AnyObject) === self
    }

    private func observeWindowReadiness() {
        stopObservingWindowReadiness()
        guard let window else { return }
        readinessObservers = [
            observeReadinessTransition(
                NSApplication.didBecomeActiveNotification,
                object: NSApp),
            observeReadinessTransition(
                NSWindow.didBecomeKeyNotification,
                object: window),
            observeReadinessTransition(
                NSWindow.didChangeOcclusionStateNotification,
                object: window),
            observeReadinessTransition(
                NSWindow.didResizeNotification,
                object: window),
        ]
    }

    private func observeReadinessTransition(
        _ name: Notification.Name,
        object: AnyObject
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleInitialAccessibilityFocusIfNeeded(
                    recheckVisibleTargetAfterLayout: true)
            }
        }
    }

    private func stopObservingWindowReadiness() {
        for observer in readinessObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        readinessObservers.removeAll()
    }

    private func scheduleInitialAccessibilityFocusIfNeeded(
        recheckVisibleTargetAfterLayout: Bool = false
    ) {
        guard let initialAccessibilityFocusRequest,
            !focusAttemptIsScheduled
        else { return }
        if !recheckVisibleTargetAfterLayout {
            guard initialAccessibilityFocusRequest.shouldAttemptFocus(for: self) else { return }
        }
        focusAttemptIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusAttemptIsScheduled = false
            guard let root = self.window?.contentView else { return }
            root.layoutSubtreeIfNeeded()
            guard
                let visibleTarget = EmptyWorkspaceAccessibilityFocusHandoff.target(in: root)
                    as? EmptyWorkspacePrimaryActionFocusButton
            else { return }
            _ = self.initialAccessibilityFocusRequest?.consume(byFocusing: visibleTarget)
        }
    }
}

private struct NeedsInputBar: View {
    let session: TerminalSession
    let onAcknowledge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(.needs)

            Text("permission needed")
                .awFont(AwFont.Mono.kicker)
                .tracking(1.1)
                .textCase(.uppercase)
                .foregroundStyle(Color.aw.status.needs)
                .lineLimit(1)
                .layoutPriority(0)

            Text(session.title)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
                .layoutPriority(0)

            Spacer(minLength: 12)

            Button {
                onAcknowledge()
            } label: {
                Text("Acknowledge")
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.status.onLoud)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.aw.status.needs, in: RoundedRectangle(cornerRadius: AwRadius.pill))
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help("\(KeyboardShortcutCatalog.acknowledgeWorkspace.action) (\(KeyboardShortcutCatalog.acknowledgeWorkspace.displaySymbol))")
            .accessibilityLabel(
                "\(KeyboardShortcutCatalog.acknowledgeWorkspace.action), \(KeyboardShortcutCatalog.acknowledgeWorkspace.spokenForm)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(minHeight: 46)
        .background {
            LinearGradient(
                colors: [
                    Color.aw.status.needs.opacity(0.22),
                    Color.aw.status.needs.opacity(0.08),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .overlay(alignment: .leading) { edgeAccent }
        .overlay(alignment: .trailing) { edgeAccent }
        .overlay(alignment: .top) { horizontalAccent }
        .overlay(alignment: .bottom) { horizontalAccent }
    }

    private var edgeAccent: some View { accentBar(width: 3) }
    private var horizontalAccent: some View { accentBar(height: 3) }

    // Decorative; state is already carried by StatusDot + the "permission
    // needed" text, same rationale as StatusDot's own accessibilityHidden use.
    private func accentBar(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        Rectangle()
            .fill(Color.aw.status.needs)
            .frame(width: width, height: height)
            .awGlow(color: Color.aw.status.needs.opacity(0.7), radius: 7)
            .accessibilityHidden(true)
    }
}

private struct SidebarEdgeTab: View {
    let style: SidebarEdgeTabPolicy.Style?
    let visibilitySource: SidebarVisibilitySource
    let position: AppearanceConfig.SidebarPosition
    let terminalBackground: Color
    @Environment(\.awAccent) private var accentResolver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color =
            if style == .attention {
                Color.aw.contrastTuned(
                    Color.aw.status.needs,
                    terminalBackground: terminalBackground
                )
            } else {
                Color.aw.focusAccent(
                    accentResolver.accent,
                    terminalBackground: terminalBackground
                )
            }
        let hiddenOffset: CGFloat = position == .left ? -10 : 10
        return ZStack(alignment: position == .left ? .leading : .trailing) {
            Rectangle()
                .fill(color)
                .frame(width: 7)
            if style == .cue {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color)
                    .frame(width: 28, height: 52)
                    .overlay {
                        if position == .left {
                            Image(systemName: "chevron.right")
                        } else {
                            Image(systemName: "chevron.left")
                        }
                    }
                    .foregroundStyle(
                        Color.aw.backgroundIsDark(color) ? Color.white : Color.black
                    )
            }
        }
        .frame(width: 28, alignment: position == .left ? .leading : .trailing)
        .frame(maxHeight: .infinity, alignment: position == .left ? .leading : .trailing)
        .opacity(style == nil ? 0 : 1)
        .offset(x: style == nil && !reduceMotion ? hiddenOffset : 0)
        .animation(
            SidebarEdgeTabTransitionPolicy.shouldAnimate(
                source: visibilitySource,
                reduceMotion: reduceMotion)
                ? .easeOut(duration: 0.12)
                : nil,
            value: style
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
