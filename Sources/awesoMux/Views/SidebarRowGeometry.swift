import AppKit
import SwiftUI

/// Peek anchors must share the window root even when a row has its own hosting view.
struct SidebarRowGeometry: View {
    let changed: (CGRect) -> Void
    @Environment(\.isNativeSidebarRow) private var isNative

    var body: some View {
        if isNative {
            NativeAnchor(changed: changed).allowsHitTesting(false).accessibilityHidden(true)
        } else {
            Color.clear.onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                changed($0)
            }
        }
    }

    private struct NativeAnchor: NSViewRepresentable {
        let changed: (CGRect) -> Void
        func makeNSView(context: Context) -> Anchor { Anchor() }
        func updateNSView(_ view: Anchor, context: Context) { view.changed = changed; view.publishFrame() }
        static func dismantleNSView(_ view: Anchor, coordinator: ()) {
            NotificationCenter.default.removeObserver(view)
            view.changed = nil
        }
    }

    final class Anchor: NSView {
        var changed: ((CGRect) -> Void)?
        private var lastFrame: CGRect?

        static func frameInRoot(_ view: NSView, root: NSView) -> CGRect {
            var frame = view.convert(view.bounds, to: root)
            if !root.isFlipped { frame.origin.y = root.bounds.maxY - frame.maxY }
            return frame
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            var ancestor: NSView? = self
            while let view = ancestor {
                view.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(geometryChanged), name: NSView.frameDidChangeNotification, object: view)
                if let clip = view as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(geometryChanged), name: NSView.boundsDidChangeNotification, object: clip)
                }
                ancestor = view.superview
            }
            publishFrame()
        }
        override func layout() { super.layout(); publishFrame() }
        @objc private func geometryChanged(_ notification: Notification) { publishFrame() }
        func publishFrame() {
            guard let root = window?.contentView else { return }
            let frame = Self.frameInRoot(self, root: root)
            guard frame != lastFrame else { return }
            lastFrame = frame
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastFrame == frame else { return }
                self.changed?(frame)
            }
        }
    }
}
