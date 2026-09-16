import AppKit
import DesignSystem
import SwiftUI

enum NativeTitlebarChrome {
    @MainActor
    static func apply(to window: NSWindow) {
        // A real unified toolbar gives AppKit ownership of the modern control
        // insets. The app still draws its own contents in the full-size titlebar area.
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "awesoMux.titlebar")
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}

struct NativeTitlebarGeometry: Equatable {
    var height: CGFloat = AppTitlebarMetrics.fallbackHeight
    var leadingInset: CGFloat = AppTitlebarMetrics.trafficLightClearance

    @MainActor
    init?(window: NSWindow) {
        // Keep the last normal geometry while the system slides its controls
        // out of the window in full screen.
        guard !window.styleMask.contains(.fullScreen),
            let close = window.standardWindowButton(.closeButton),
            !close.isHidden,
            let container = close.superview
        else { return nil }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let frames = buttons.map { $0.convert($0.bounds, to: nil) }
        let centreFromTop =
            container.isFlipped
            ? close.frame.midY - container.bounds.minY
            : container.bounds.maxY - close.frame.midY
        guard centreFromTop > 0, centreFromTop.isFinite,
            let rightEdge = frames.map(\.maxX).max(), rightEdge.isFinite
        else { return nil }
        height = centreFromTop * 2
        leadingInset = rightEdge + AppTitlebarMetrics.lockupPadding
    }

    init() {}
}

/// The app keeps its own titlebar contents; AppKit owns the controls and their
/// alignment in the primary window. Auxiliary windows retain compact chrome.
struct NativeTitlebar<Content: View>: View {
    @ViewBuilder var content: (NativeTitlebarGeometry) -> Content
    @State private var geometry = NativeTitlebarGeometry()

    var body: some View {
        content(geometry)
            .frame(height: geometry.height)
            .padding(.bottom, min(0, AppTitlebarMetrics.layoutHeight - geometry.height))
            .background {
                LinearGradient(
                    colors: [Color.aw.surface.chrome2, Color.aw.surface.chrome],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            .background {
                NativeTitlebarGeometryReader { measured in
                    if geometry != measured { geometry = measured }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct NativeTitlebarGeometryReader: NSViewRepresentable {
    let onChange: (NativeTitlebarGeometry) -> Void

    func makeNSView(context: Context) -> GeometryView {
        GeometryView(onChange: onChange)
    }

    func updateNSView(_ view: GeometryView, context: Context) {
        view.onChange = onChange
        view.scheduleMeasurement()
    }

    final class GeometryView: NSView {
        var onChange: (NativeTitlebarGeometry) -> Void
        private var measurementPending = false
        private var frameObservers: [NSObjectProtocol] = []

        init(onChange: @escaping (NativeTitlebarGeometry) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        deinit {
            MainActor.assumeIsolated {
                for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
            frameObservers.removeAll()
            if let close = window?.standardWindowButton(.closeButton), let container = close.superview {
                for view in [close, container] {
                    view.postsFrameChangedNotifications = true
                    frameObservers.append(
                        NotificationCenter.default.addObserver(
                            forName: NSView.frameDidChangeNotification, object: view, queue: .main
                        ) { [weak self] _ in
                            MainActor.assumeIsolated { self?.scheduleMeasurement() }
                        })
                }
            }
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !measurementPending else { return }
            measurementPending = true
            // Do not publish SwiftUI state during an AppKit layout pass, or
            // force another native layout from inside this reader.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                measurementPending = false
                guard let window, let measured = NativeTitlebarGeometry(window: window) else { return }
                onChange(measured)
            }
        }
    }
}
