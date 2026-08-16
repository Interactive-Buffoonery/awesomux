import AppKit
import SwiftUI

final class FloatingSwiftUIPanelWindow: NSPanel {
    static let swiftUIFloatingStyleMask: NSWindow.StyleMask = [
        .nonactivatingPanel,
        .titled,
        .resizable,
        .closable,
        .fullSizeContentView
    ]

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { canBecomeMainPanel }

    var canBecomeMainPanel = false
    var dismissesOnResignKey = true
    /// Opt-in native traffic lights for the window-family panels (About,
    /// Session Manager, Worktree Manager, cheatsheet). Defaults off because the
    /// command palette is transient and Escape-dismissed, where traffic lights
    /// would read as wrong.
    ///
    /// `didSet`, not a plain stored property: `configureFloatingPanelChrome()`
    /// runs during `init`, so a controller setting this afterwards would
    /// otherwise never reach the buttons.
    var showsStandardWindowButtons = false {
        didSet { applyStandardWindowButtonVisibility() }
    }
    var onDismiss: (() -> Void)?
    /// May run mid-sendEvent (pointer re-key). Flags only; reactions async.
    var onKeyStateChanged: ((Bool) -> Void)?
    var onModifierFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    var handlesKeyEvent: ((NSEvent) -> Bool)?

    convenience init(
        contentRect: NSRect,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.init(
            contentRect: contentRect,
            styleMask: Self.swiftUIFloatingStyleMask,
            backing: backingStoreType,
            defer: flag
        )
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: Self.swiftUIFloatingStyleMask,
            backing: backingStoreType,
            defer: flag
        )
        configureFloatingPanelChrome()
        setFixedContentSize(contentRect.size)
    }

    override func becomeKey() {
        super.becomeKey()
        onKeyStateChanged?(true)
    }

    override func resignKey() {
        super.resignKey()
        onKeyStateChanged?(false)
        // A SwiftUI `.sheet()` presented over this panel's content attaches an
        // actual child NSWindow, which resigns THIS window's key status the
        // moment it becomes key itself — that's the sheet opening normally,
        // not the user clicking away, so it must not order the parent out
        // from under its own modal child.
        if dismissesOnResignKey, attachedSheet == nil {
            onDismiss?()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            onModifierFlagsChanged?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }

        if event.type == .keyDown, handlesKeyEvent?(event) == true {
            return
        }

        if !isKeyWindow,
           FloatingPanelEventPolicy.isReclickActivation(type: event.type),
           !hasModalInputOwner {
            makeKeyForPointerEventIfNeeded()
        }

        super.sendEvent(event)
    }

    private var hasModalInputOwner: Bool {
        NSApp.modalWindow != nil
            || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    private func makeKeyForPointerEventIfNeeded() {
        guard !isKeyWindow else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Sync re-key; keep onKeyStateChanged flag-only on this stack.
        makeKey()
    }

    @discardableResult
    func hostSwiftUIContent<Content: View>(
        _ rootView: Content
    ) -> FloatingPanelHostingController {
        if let hosting = contentViewController as? FloatingPanelHostingController {
            hosting.rootView = AnyView(rootView.ignoresSafeArea())
            return hosting
        }

        let hosting = FloatingPanelHostingController(
            rootView: AnyView(rootView.ignoresSafeArea())
        )
        contentViewController = hosting
        return hosting
    }

    func activateAppIfNeeded() {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func presentAndFocus(focusHostedContent shouldFocusHostedContent: Bool = true) {
        activateAppIfNeeded()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        makeKey()
        if shouldFocusHostedContent {
            focusHostedContent()
        }
    }

    func focusHostedContent() {
        guard let target = contentViewController?.view ?? contentView else {
            return
        }
        if let firstResponder, firstResponder === target {
            return
        }
        if makeFirstResponder(target) {
            return
        }
        DispatchQueue.main.async { [weak self, weak target] in
            guard let self, isVisible, let target else { return }
            _ = makeFirstResponder(target)
        }
    }

    func setFixedContentSize(_ size: CGSize) {
        contentMinSize = size
        contentMaxSize = size
        setContentSize(size)
    }

    private func configureFloatingPanelChrome() {
        isFloatingPanel = true
        level = .floating
        // Stay on the active Space only; paired with `hidesOnDeactivate` below
        // this keeps the panel from floating over other apps / every Space.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        applyStandardWindowButtonVisibility()
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        becomesKeyOnlyIfNeeded = false
        // Hide when awesoMux is backgrounded so the panel never hangs over
        // other apps when it isn't the key window (the not-key case that
        // `dismissesOnResignKey` doesn't cover).
        hidesOnDeactivate = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    /// Unhides only — `styleMask` is deliberately untouched.
    /// `swiftUIFloatingStyleMask` omits `.miniaturizable`, which is exactly what
    /// makes the middle well render disabled-gray the way About This Mac does;
    /// `StandardWindowButtonVisibility.visible` unions `.miniaturizable` back
    /// in and would silently turn that into an enabled minimize.
    ///
    /// ponytail: no `reassertsOnBecomeKey` / forced titlebar relayout here.
    /// Settings needs both (`WindowChromeConfigurator.swift:107-118`,
    /// `:231-238`) because AppKit drops titlebar configuration across key
    /// changes, but a live spike showed these panels keep their lights without
    /// it. Add the same treatment if smoke ever shows the lights disappearing.
    private func applyStandardWindowButtonVisibility() {
        let isHidden = !showsStandardWindowButtons
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = isHidden
        }
    }

    /// The native close button (and any `⌘W` that reaches AppKit) targets
    /// `performClose(_:)`. It must land on the controller, not on `close()`:
    /// these panels are ordered out and reused (`isReleasedWhenClosed = false`)
    /// and each controller's `dismiss()` owns the real teardown — stopping the
    /// Session Manager's daemon polling, refusing to close during an in-flight
    /// `git worktree add`, and clearing `isVisible`, which a stale `true`
    /// would permanently trip in `refreshWorktreeRepositoryContext()`.
    /// Routing through `onDismiss` inherits those guards for free.
    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}

final class FloatingPanelHostingController: NSViewController {
    private let hostingView: FloatingPanelHostingView<AnyView>

    var rootView: AnyView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    init(rootView: AnyView) {
        self.hostingView = FloatingPanelHostingView(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = hostingView
    }
}

final class FloatingPanelHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
