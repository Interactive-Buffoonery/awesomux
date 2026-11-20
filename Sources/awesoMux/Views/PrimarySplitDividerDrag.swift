import AppKit
import AwesoMuxCore
import SwiftUI

struct PrimarySplitDividerInput {
    let mount: PrimaryPaneTree.Mount?
    let splitID: TerminalSplit.ID
    let begin: (UUID) -> Bool
    let change: (UUID, CGSize) -> Bool
    let end: (UUID, Bool) -> Void
}

/// AppKit captures dragged/up events for the mouse-down view. Escape, window
/// deactivation and dismantling all take the same cancellation path.
struct PrimarySplitDividerDrag: NSViewRepresentable {
    let input: PrimarySplitDividerInput

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.update(input)
    }

    static func dismantleNSView(_ view: DragView, coordinator: ()) {
        view.cancelFromViewLifecycle()
    }

    final class DragView: NSView {
        private var input: PrimarySplitDividerInput?
        private var token: UUID?
        private var start = NSPoint.zero
        private var keyMonitor: Any?
        private var isFinishing = false

        func update(_ input: PrimarySplitDividerInput) {
            if self.input?.mount != input.mount || self.input?.splitID != input.splitID {
                cancelFromViewLifecycle()
            }
            self.input = input
        }

        override func mouseDown(with event: NSEvent) {
            guard token == nil, let input, input.mount != nil else { return }
            let token = UUID()
            guard input.begin(token) else { return }
            self.token = token
            start = event.locationInWindow
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.token == token, event.keyCode == 53,
                    let window = self.window, event.window === window
                else { return event }
                self.finish(commit: false)
                return nil
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let token else { return }
            let point = event.locationInWindow
            if input?.change(token, CGSize(width: point.x - start.x, height: start.y - point.y)) != true {
                finish(commit: false)
            }
        }

        override func mouseUp(with event: NSEvent) {
            mouseDragged(with: event)
            finish(commit: true)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow {
                cancelFromViewLifecycle()
                if let window {
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
                }
                if let newWindow {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: newWindow)
                }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func windowResignedKey() {
            finish(commit: false)
        }

        func finish(commit: Bool) {
            guard let token, !isFinishing else { return }
            isFinishing = true
            input?.end(token, commit)
            clearNativeDrag()
            isFinishing = false
        }

        func cancelFromViewLifecycle() {
            guard let token, let input, !isFinishing else { return }
            clearNativeDrag()
            // The representable can update or dismantle during SwiftUI's
            // update pass. The old token still qualifies the deferred write.
            DispatchQueue.main.async {
                input.end(token, false)
            }
        }

        private func clearNativeDrag() {
            token = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }
}
