import AppKit
import os
import SwiftUI

enum StandardWindowButtonVisibility {
    case visible
    case hidden
    /// Close button only — miniaturize and zoom hidden. Used by the About
    /// window, whose fixed size / non-restore are owned by the scene modifiers
    /// (`.windowResizability(.contentSize)` / `.restorationBehavior(.disabled)`).
    case closeOnly

    @MainActor
    func apply(to window: NSWindow) {
        switch self {
        case .visible:
            window.styleMask.formUnion([.closable, .miniaturizable, .resizable])
        case .closeOnly:
            // Truly close-only: drop the minimize capability too, so Cmd-M /
            // Window ▸ Minimize can't park the fixed-size About window while its
            // button is hidden. Resize stays owned by the scene modifier.
            window.styleMask.remove(.miniaturizable)
        case .hidden:
            break
        }

        window.standardWindowButton(.closeButton)?.isHidden = self == .hidden
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = self != .visible
        }
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    private let windowRole: AwesoMuxWindowRole?
    private let reassertsOnBecomeKey: Bool
    private let forcesTitlebarRelayout: Bool
    private let assertsNonMainCapable: Bool
    private let standardWindowButtonVisibility: StandardWindowButtonVisibility
    private let centersOnAttach: Bool

    init(
        windowRole: AwesoMuxWindowRole? = nil,
        reassertsOnBecomeKey: Bool = false,
        forcesTitlebarRelayout: Bool = false,
        assertsNonMainCapable: Bool = false,
        standardWindowButtonVisibility: StandardWindowButtonVisibility = .visible,
        centersOnAttach: Bool = false
    ) {
        self.windowRole = windowRole
        self.reassertsOnBecomeKey = reassertsOnBecomeKey
        self.forcesTitlebarRelayout = forcesTitlebarRelayout
        self.assertsNonMainCapable = assertsNonMainCapable
        self.standardWindowButtonVisibility = standardWindowButtonVisibility
        self.centersOnAttach = centersOnAttach
    }

    func makeNSView(context: Context) -> NSView {
        WindowChromeConfigView(
            windowRole: windowRole,
            reassertsOnBecomeKey: reassertsOnBecomeKey,
            forcesTitlebarRelayout: forcesTitlebarRelayout,
            assertsNonMainCapable: assertsNonMainCapable,
            standardWindowButtonVisibility: standardWindowButtonVisibility,
            centersOnAttach: centersOnAttach
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let configView = nsView as? WindowChromeConfigView else { return }
        configView.configureAttachedWindow()
    }
}

private final class WindowChromeConfigView: NSView {
    private static let logger = Logger(
        subsystem: "com.interactivebuffoonery.awesomux",
        category: "settings-chrome"
    )

    private let reassertsOnBecomeKey: Bool
    private let forcesTitlebarRelayout: Bool
    private let assertsNonMainCapable: Bool
    private let standardWindowButtonVisibility: StandardWindowButtonVisibility
    private let centersOnAttach: Bool
    private let windowRole: AwesoMuxWindowRole?
    private var keyObserver: NSObjectProtocol?
    private weak var roleWindow: NSWindow?
    /// Windows this view has already centered — attach-time only, so a user
    /// who drags the window and clicks back in is never yanked to center.
    private weak var centeredWindow: NSWindow?

    init(
        windowRole: AwesoMuxWindowRole?,
        reassertsOnBecomeKey: Bool,
        forcesTitlebarRelayout: Bool,
        assertsNonMainCapable: Bool,
        standardWindowButtonVisibility: StandardWindowButtonVisibility,
        centersOnAttach: Bool
    ) {
        self.windowRole = windowRole
        self.reassertsOnBecomeKey = reassertsOnBecomeKey
        self.forcesTitlebarRelayout = forcesTitlebarRelayout
        self.assertsNonMainCapable = assertsNonMainCapable
        self.standardWindowButtonVisibility = standardWindowButtonVisibility
        self.centersOnAttach = centersOnAttach
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        MainActor.assumeIsolated {
            removeKeyObserver()
            clearWindowRole()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        removeKeyObserver()
        clearWindowRole()

        guard let window else { return }

        configureWindow(window)

        // Programmatic centering: the scene-level `.defaultPosition(.center)`
        // does not take effect for this hidden-title-bar auxiliary scene (the
        // window opens at the AppKit cascade spot instead — verified on a
        // fresh profile), so center via AppKit once per window. Deferred one
        // main-queue hop so SwiftUI has applied the final content size first;
        // `NSWindow.center()` is the macOS-conventional About placement
        // (screen-centered horizontally, slightly above vertical center).
        if centersOnAttach, centeredWindow !== window {
            centeredWindow = window
            DispatchQueue.main.async { [weak window] in
                window?.center()
            }
        }

        guard reassertsOnBecomeKey else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureAttachedWindow(requiresTitlebarRelayout: true)
                self?.scheduleDeferredConfigure(requiresTitlebarRelayout: true)
            }
        }
    }

    private func removeKeyObserver() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        keyObserver = nil
    }

    func configureAttachedWindow(requiresTitlebarRelayout: Bool = false) {
        guard let window else { return }
        configureWindow(window, requiresTitlebarRelayout: requiresTitlebarRelayout)
    }

    private func scheduleDeferredConfigure(requiresTitlebarRelayout: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.configureAttachedWindow(requiresTitlebarRelayout: requiresTitlebarRelayout)
            }
        }
    }

    private func configureWindow(_ window: NSWindow, requiresTitlebarRelayout: Bool = false) {
        applyWindowRole(to: window)

        let corrected = applyChrome(to: window)

        if forcesTitlebarRelayout && (requiresTitlebarRelayout || corrected) {
            forceTitlebarRelayout(for: window)

            if corrected {
                forceFullSizeContentViewRecompute(for: window)
            }
        }

        standardWindowButtonVisibility.apply(to: window)

        assertNonMainCapable(window)
    }

    private func applyWindowRole(to window: NSWindow) {
        if let roleWindow, roleWindow !== window {
            clearWindowRole()
        }
        window.awesoMuxWindowRole = windowRole
        roleWindow = window
    }

    private func clearWindowRole() {
        defer { roleWindow = nil }

        guard let windowRole, let roleWindow else { return }
        if roleWindow.awesoMuxWindowRole == windowRole {
            roleWindow.awesoMuxWindowRole = nil
        }
    }

    /// Tripwire for the Settings window's non-main-capable invariant. The
    /// Settings window is expected to stay non-main-capable. Primary-frame
    /// persistence is now guarded by `AwesoMuxWindowRole`, so this log is a
    /// diagnostic for unexpected AppKit behavior rather than the correctness
    /// boundary.
    private func assertNonMainCapable(_ window: NSWindow) {
        guard assertsNonMainCapable, window.canBecomeMain else { return }
        Self.logger.error(
            "settingsWindowBecameMainCapable styleMask=\(window.styleMask.rawValue, privacy: .public)"
        )
    }

    private func applyChrome(to window: NSWindow) -> Bool {
        var corrected = false

        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
            corrected = true
        }

        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
            corrected = true
        }

        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
            corrected = true
        }

        if window.toolbarStyle != .unifiedCompact {
            window.toolbarStyle = .unifiedCompact
            corrected = true
        }

        // awesoMux is single-window with a sidebar of sessions; native window
        // tabs would surface a stray "+" in the titlebar that duplicates the
        // sidebar's New Workspace control.
        if window.tabbingMode != .disallowed {
            window.tabbingMode = .disallowed
            corrected = true
        }

        return corrected
    }

    private func forceTitlebarRelayout(for window: NSWindow) {
        invalidateLayoutAndDisplay(window.contentView?.superview)

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            invalidateLayoutAndDisplay(window.standardWindowButton(button)?.superview)
        }

        window.displayIfNeeded()
    }

    private func forceFullSizeContentViewRecompute(for window: NSWindow) {
        window.styleMask.remove(.fullSizeContentView)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        forceTitlebarRelayout(for: window)
    }

    private func invalidateLayoutAndDisplay(_ view: NSView?) {
        guard let view else { return }

        view.needsLayout = true
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
    }
}
