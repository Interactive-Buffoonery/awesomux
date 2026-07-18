import AppKit
import GhosttyKit

extension GhosttySurfaceNSView: NSUserInterfaceValidations {
    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()

        if didBecome {
            runtime.setSecureInputFocused(true, for: paneID)
            if let surface {
                ghostty_surface_set_focus(surface, true)
            }
            // Route focus activation through `setActivePane`, which re-arms the
            // selection dwell for the now-active pane. Acknowledging directly
            // here bypassed the dwell's 500ms read guard and unread-growth check,
            // instantly clearing a notification the user hadn't read yet (S3).
            //
            // Must run even while the native surface is still spawning
            // (cold start, respawn window): click-to-focus makes this view
            // first responder unconditionally, and leaving `activePaneID`
            // stale would let the stale-active pane's per-mount vacant-focus
            // reclaim — which treats a peer surface as vacant — steal focus
            // back on every render pass (keystroke misdirection).
            sessionStore.setActivePane(id: paneID, in: sessionID)
        }

        return didBecome
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()

        if didResign, let surface {
            // A pane-focus switch (e.g. clicking into a different split) can
            // happen mid-IME-composition. Without cancelling here, the
            // half-composed preedit text stays frozen and visible in this
            // now-unfocused pane indefinitely — `insertText` only clears it
            // on the next keystroke back in THIS pane.
            if hasMarkedText() {
                unmarkText()
            }
            ghostty_surface_set_focus(surface, false)
        }
        if didResign {
            runtime.setSecureInputFocused(false, for: paneID)
        }

        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        if searchState.isPresented,
           (event.keyCode == 0x35 || event.charactersIgnoringModifiers == "\u{1b}") {
            endSearch()
            return
        }

        markNeedsAttentionPromptAnswered()

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let translatedModifierFlags = GhosttyInputMapper.modifierFlags(
            original: event.modifierFlags,
            translatedGhosttyMods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInputMapper.modifiers(event.modifierFlags)
            )
        )
        let translationEvent: NSEvent = if translatedModifierFlags == event.modifierFlags {
            event
        } else {
            NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translatedModifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translatedModifierFlags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }
        let markedTextBefore = hasMarkedText()

        // Some IMEs swap the active keyboard layout mid-keystroke (e.g.
        // temporarily switching to a Latin layout while composing); skip the
        // lookup entirely while already composing since layout churn there
        // is expected IME behavior, not a signal to bail.
        let keyboardIdBefore: String? = markedTextBefore ? nil : GhosttyKeyboardLayout.id

        // `interpretKeyEvents` below may itself invoke `doCommand(by:)`,
        // which reads `lastPerformKeyEvent` to decide whether to redispatch
        // (see `GhosttySurfaceTextInputClient.doCommand`). That field is
        // scoped to a specific `performKeyEquivalent` pass, so stale state
        // left over from an earlier, already-resolved key equivalent must
        // not leak into this unrelated `interpretKeyEvents` call. Mirrors
        // Ghostty's `SurfaceView_AppKit.keyDown`.
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // Mirrors `keyboardIdBefore` above: only look up the (Carbon,
        // non-trivial) current keyboard layout when we weren't already
        // composing. Passing `GhosttyKeyboardLayout.id` directly as a call
        // argument would defeat this short-circuit — Swift evaluates all
        // arguments eagerly, unlike the `&&` this was ported from.
        let keyboardIdAfter: String? = markedTextBefore ? nil : GhosttyKeyboardLayout.id

        if GhosttySurfaceIMEPolicy.layoutChangedDuringComposition(
            markedTextBefore: markedTextBefore,
            keyboardIdBefore: keyboardIdBefore,
            keyboardIdAfter: keyboardIdAfter
        ) {
            // The layout changed and we weren't already composing — assume
            // an IME consumed this key and bail rather than double-processing.
            return
        }

        syncPreedit(clearIfNeeded: markedTextBefore)

        let composing = hasMarkedText() || markedTextBefore

        if markedTextBefore, let accumulatedText = keyTextAccumulator, !accumulatedText.isEmpty {
            // The IME just committed preedit text while handling this key
            // (Korean IME: composing a character, then arrow-navigating away
            // commits it). Send the committed text as its own key events —
            // not the pressed key itself, which the IME already consumed —
            // then replay the actual key only if it's one that should still
            // reach the terminal post-commit (e.g. the arrow that triggered
            // the commit).
            for text in accumulatedText {
                if GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(text, composing: composing) {
                    continue
                }
                sendCommittedPreeditText(action, text: text, surface: surface)
            }

            if GhosttySurfaceIMEPolicy.shouldReplayCommittedPreeditKey(
                keyCode: translationEvent.keyCode,
                modifierFlags: translationEvent.modifierFlags
            ) {
                // No `text:` here — matches Ghostty's `keyAction(..., composing:
                // false)` call at the replay site, which omits `text` entirely
                // (defaults to nil). The replayed keys are always arrow keys,
                // whose `characters` fall in the private-use function-key range
                // `ghosttyText(for:)` already filters to nil, so this is also
                // the behaviorally-identical choice, not just a literal port.
                sendKeyEvent(
                    action,
                    event: event,
                    surface: surface,
                    composing: false,
                    translationModifierFlags: translationEvent.modifierFlags
                )
            }
            return
        }

        guard let accumulatedText = keyTextAccumulator, !accumulatedText.isEmpty else {
            // A raw control character (e.g. ctrl+h) arriving mid-composition
            // belongs to the IME, not the terminal.
            if GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(event.characters, composing: composing) {
                return
            }

            sendKeyEvent(
                action,
                event: event,
                surface: surface,
                text: ghosttyText(for: translationEvent),
                composing: composing,
                translationModifierFlags: translationEvent.modifierFlags
            )
            return
        }

        for text in accumulatedText {
            // Drop bare control characters the IME accumulated while
            // composing so they don't leak through to the terminal.
            if GhosttySurfaceIMEPolicy.shouldSuppressComposingControlInput(text, composing: composing) {
                continue
            }

            sendKeyEvent(
                action,
                event: event,
                surface: surface,
                text: text,
                translationModifierFlags: translationEvent.modifierFlags
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        guard Self.terminalKeyUpDispatchValidation(
            hasSurface: surface != nil,
            isFirstResponder: window?.firstResponder === self
        ),
        let surface else {
            return
        }

        sendKeyEvent(GHOSTTY_ACTION_RELEASE, event: event, surface: surface)
    }

    static func terminalKeyUpDispatchValidation(
        hasSurface: Bool,
        isFirstResponder: Bool
    ) -> Bool {
        hasSurface && isFirstResponder
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else {
            return
        }

        if hasMarkedText() {
            return
        }

        guard let action = GhosttyInputMapper.flagsChangedAction(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ) else {
            return
        }

        sendKeyEvent(action, event: event, surface: surface)

        // INT-632: covers the stationary-mouse cases that `sendMousePosition`'s
        // continuous injection can't see (no motion event fires while the
        // pointer is still). ⌘-down arms hover for "mouse already resting on
        // a link, then presses ⌘" — mirroring libghostty's hover-refresh on
        // physical Shift in its `keyCallback`. ⌘-up fires the SAME probe
        // with plain mods (nothing injected once ⌘ leaves the flags): the
        // key event's mods-changed branch clears only the visuals, and a
        // stale `over_link` would open a link on a later motionless PLAIN
        // click. Not perfectly byte-identical to physical ⌘⇧ — this path
        // can emit one same-cell-deduped motion report where the key path
        // emits none; accepted, bounded to one event per ⌘ transition.
        //
        // Guards: flagsChanged goes to the FIRST RESPONDER, not the view
        // under the pointer, so a ⌘ chord with the mouse elsewhere must not
        // fabricate a position report (`currentMousePositionInView` returns
        // nil off-view), and mid-drag it must not interrupt the TUI's drag
        // stream (`hasNoMouseButtonHeld`, the same invariant every other
        // non-drag position sender holds).
        if GhosttyInputMapper.isCommandKeyCode(event.keyCode),
           hasNoMouseButtonHeld,
           ghostty_surface_mouse_captured(surface),
           let pos = currentMousePositionInView() {
            ghostty_surface_mouse_pos(
                surface,
                pos.x,
                pos.y,
                GhosttyInputMapper.mouseModifiers(event.modifierFlags, mouseCaptured: true)
            )
        }

        // INT-453: ⌘ pressed while already resting on a link promotes the peek to
        // instant (no new `updateMouseOverLink` fires for an unchanged link).
        if GhosttyInputMapper.isCommandKeyCode(event.keyCode),
            event.modifierFlags.contains(.command)
        {
            promoteLinkPeekForCommandIfHovering()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isApplicationCommandShortcut(event),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        guard event.type == .keyDown,
              window?.firstResponder === self,
              let surface else {
            return false
        }

        // Ask libghostty whether this exact key sequence resolves to a
        // configured binding (Ghostty reference: SurfaceView_AppKit.swift
        // performKeyEquivalent, ~1290-1319, via `ghostty_surface_key_is_binding`).
        // A recognized binding is safe to encode immediately: the terminal
        // already knows what to do with it, so there's nothing to gain by
        // giving AppKit's text-editing responder chain (`doCommand(by:)`)
        // first crack — and doing so risks it silently swallowing the key
        // instead (see `performNonBindingKeyEquivalent`).
        if isGhosttyBinding(event, surface: surface) {
            return sendKeyEvent(
                event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                event: event,
                surface: surface,
                text: ghosttyText(for: event)
            )
        }

        return performNonBindingKeyEquivalent(event, surface: surface)
    }

    /// Whether libghostty has a configured binding for this exact key event.
    /// Mirrors `Ghostty.Surface.keyIsBinding` — we only need the yes/no here,
    /// not the returned `ghostty_binding_flags_e` (awesoMux has no
    /// key-sequence/key-table concept to gate on, unlike Ghostty's own
    /// `MenuShortcutManager`-driven menu dispatch).
    func isGhosttyBinding(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = GhosttyInputMapper.modifiers(event.modifierFlags)
        keyEvent.consumed_mods = GhosttyInputMapper.modifiers(
            event.modifierFlags.subtracting([.control, .command])
        )
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepoint(for: event)

        var flags = ghostty_binding_flags_e(0)
        return (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
    }

    /// Handles a command/control-modified key that is NOT a libghostty
    /// binding. Delegates the decision to `GhosttyKeyEquivalentPolicy` (pure,
    /// unit-tested) and only does the AppKit-side dispatch here.
    ///
    /// `surface` is unused directly but kept in the signature to mirror
    /// `isGhosttyBinding`'s call shape and make the call site read as
    /// "we already confirmed there's a live surface."
    func performNonBindingKeyEquivalent(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        let (decision, updatedLastPerformKeyEvent) = GhosttyKeyEquivalentPolicy.decideNonBindingKeyEquivalent(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            characters: event.characters,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            lastPerformKeyEvent: lastPerformKeyEvent
        )
        lastPerformKeyEvent = updatedLastPerformKeyEvent

        switch decision {
        case .ignore, .waitForResponderChain:
            return false

        case let .encode(equivalent), let .redispatch(equivalent):
            return dispatchKeyEquivalent(equivalent, from: event)
        }
    }

    /// Builds a synthetic keyDown carrying `equivalent` as its characters and
    /// routes it through our own `keyDown(with:)` — reusing the full
    /// translation/IME-aware encode path rather than duplicating it here.
    /// Mirrors Ghostty's `finalEvent` construction in `performKeyEquivalent`.
    func dispatchKeyEquivalent(_ equivalent: String, from event: NSEvent) -> Bool {
        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else {
            return false
        }

        // `keyDown(with:)` below can reenter synchronously: `interpretKeyEvents`
        // may call `doCommand(by:)`, whose default case can redispatch via
        // `NSApp.sendEvent`, which can route right back through
        // `performKeyEquivalent` → `dispatchKeyEquivalent` → here, nested
        // inside the ORIGINAL `keyDown`'s own `interpretKeyEvents` call. The
        // nested `keyDown(with: finalEvent)` unconditionally resets
        // `keyTextAccumulator = []` on entry and nils it via its own `defer`
        // on exit — without saving/restoring here, that clobbers whatever
        // the enclosing (outer) `keyDown` call had already accumulated,
        // silently dropping IME input. `keyTextAccumulator` is a
        // per-keystroke ephemeral batch (unlike `markedText`, which is
        // legitimately shared, continuously-updated IME UI state with no
        // "outer vs. nested" distinction) — save/restore is scoped to this
        // one field.
        let savedAccumulator = keyTextAccumulator
        defer { keyTextAccumulator = savedAccumulator }

        keyDown(with: finalEvent)
        return true
    }

    static func isApplicationCommandShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.command)
    }

    static func isCommandSubmitKey(_ event: NSEvent, text: String?) -> Bool {
        if event.keyCode == 0x24 || event.keyCode == 0x4C {
            return true
        }

        return text?.contains(where: { $0 == "\n" || $0 == "\r" }) == true
    }

    static let submittedSSHCommandCaptureLimit = 2_048

    static func isBackspace(_ event: NSEvent, text: String?) -> Bool {
        event.keyCode == 0x33
            || text?.contains(where: { $0 == "\u{7f}" || $0 == "\u{8}" }) == true
    }

    static func isPossibleSubmittedSSHCommandPrefix(_ input: String) -> Bool {
        let trimmed = input.drop(while: \.isWhitespace)
        guard !trimmed.isEmpty else {
            return true
        }
        let command = trimmed.prefix(while: { !$0.isWhitespace })
        return "ssh".hasPrefix(String(command))
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the hovered link opens through libghostty's own OPEN_URL
        // gate below; dismiss the peek preview first (transient would also close,
        // but this clears state deterministically and keeps click-through intact).
        dismissLinkPeek()
        // No extra `makeFirstResponder` here — `localEventLeftMouseDown`
        // (below) already transferred focus for this click, via a global
        // event monitor that runs BEFORE the responder chain.
        //
        // INT-607: that monitor's `return nil` was meant to also PREVENT this
        // override from running at all for a focus-only click (mirrors
        // Ghostty's `SurfaceView_AppKit.mouseDown`), so the click would never
        // be forwarded to whatever mouse-mode TUI is running in the
        // newly-focused pane. Live diagnostic capture proved that prevention
        // does not hold: `localEventLeftMouseDown` logs `consumed-focus-transfer`
        // and THIS override still fires for the same click a millisecond
        // later — on every focus-transfer click observed, not intermittently.
        // With the shared monitor, this override remains the authoritative
        // decision point: the policy's focus-only latch, set by the monitor's
        // prediction, is consumed here to decide whether THIS click's press
        // should reach libghostty at all — not just whether to un-arm a release
        // suppression after the fact.
        let wasFocusOnlyClick = mouseButtonPolicy.isFocusOnlyLeftClickArmed
        let currentSurface = surface
        let shouldCheckMouseCapture = !wasFocusOnlyClick
            && hasPendingFocusTransferClick
            && event.clickCount > 1
        let mouseCaptured = if shouldCheckMouseCapture, let currentSurface {
            ghostty_surface_mouse_captured(currentSurface)
        } else {
            false
        }
        let leftMouseDownDecision = GhosttyMouseFocusClickPolicy.decideLeftMouseDown(
            isFocusOnlyClick: wasFocusOnlyClick,
            hasPendingFocusTransferClick: hasPendingFocusTransferClick,
            clickCount: event.clickCount,
            hasSurface: currentSurface != nil,
            mouseCaptured: mouseCaptured
        )
        hasPendingFocusTransferClick = leftMouseDownDecision.hasPendingFocusTransferClick

        logMouseDiagnostic(
            event: "mouse-down",
            extra: "focusOnly=\(wasFocusOnlyClick) pendingFocusClick=\(self.hasPendingFocusTransferClick)"
        )

        guard mouseButtonPolicy.mouseDown(
            button: .left,
            surfaceIdentity: currentMouseSurfaceIdentity
        ) == .send else {
            return
        }

        switch leftMouseDownDecision.decision {
        case .suppressFocusTransfer:
            return
        case let .sendPress(replaySuppressedFocusClick):
            if replaySuppressedFocusClick,
               sendMouseButton(.press, button: GHOSTTY_MOUSE_LEFT, event: event) {
                sendMouseButton(.release, button: GHOSTTY_MOUSE_LEFT, event: event)
            }
        }

        // The policy suppresses the paired release unless this press has a
        // current surface identity. That covers cold-start/respawn windows and
        // lets the later mouseUp verify it is still talking to the same native
        // surface incarnation.
        sendMouseButton(.press, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        let decision = mouseButtonPolicy.mouseUp(
            button: .left,
            surfaceIdentity: currentMouseSurfaceIdentity
        )
        logMouseDiagnostic(event: "mouse-up", extra: "decision=\(decision)")

        guard decision == .send else {
            return
        }

        sendMouseButton(.release, button: GHOSTTY_MOUSE_LEFT, event: event)
    }

    // Runs on a global local event monitor, BEFORE the responder chain sees
    // `leftMouseDown` — mirrors Ghostty's `SurfaceView_AppKit`
    // `localEventLeftMouseDown`. Predicts "this click transfers pane focus,
    // it should not act on the app inside" via the policy's focus-only latch,
    // consumed by `mouseDown` above — see INT-607 comment there for why this
    // monitor's OWN `nil` return can no longer be trusted to prevent dispatch
    // on its own.
    // The shared monitor has already resolved this surface by window hit-test,
    // so overlay clicks never reach this method.
    func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window != nil,
              window == event.window else {
            return event
        }

        mouseButtonPolicy.clearFocusOnlyLeftClick()

        guard window.firstResponder !== self else {
            logMouseDiagnostic(event: "mouse-focus-monitor", extra: "branch=already-focused")
            return event
        }

        if NSApp.isActive, window.isKeyWindow {
            // Window/app already focused: this click is ONLY switching pane
            // focus within the split — it must not act on whatever mouse-mode
            // TUI is running in the target pane. `mouseDown` is the one that
            // actually enforces that now (see its comment); this monitor only
            // records the prediction and still returns `event` (not `nil`),
            // since consuming here doesn't reliably stop dispatch anyway.
            window.makeFirstResponder(self)
            mouseButtonPolicy.armFocusOnlyLeftClick()
            logMouseDiagnostic(event: "mouse-focus-monitor", extra: "branch=consumed-focus-transfer")
            return event
        }

        // Window/app not yet active: let the click proceed normally so
        // AppKit can activate the app/window AND deliver the click — matches
        // native macOS click-to-focus-and-act conventions (not
        // `acceptsFirstMouse`, which would swallow the click's meaning).
        window.makeFirstResponder(self)
        logMouseDiagnostic(event: "mouse-focus-monitor", extra: "branch=inactive-app-passthrough")
        return event
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Same cold-start/respawn race as the left button (INT-607 follow-up,
        // caught by adversarial review): don't allow a release through if the
        // press itself never reached a live surface.
        guard mouseButtonPolicy.mouseDown(
            button: .right,
            surfaceIdentity: currentMouseSurfaceIdentity
        ) == .send else {
            return
        }
        sendMouseButton(.press, button: GHOSTTY_MOUSE_RIGHT, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard mouseButtonPolicy.mouseUp(
            button: .right,
            surfaceIdentity: currentMouseSurfaceIdentity
        ) == .send else {
            return
        }

        sendMouseButton(.release, button: GHOSTTY_MOUSE_RIGHT, event: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Same cold-start/respawn race as the left button (INT-607 follow-up).
        // One shared flag covers all non-left/right button numbers, matching
        // this file's existing choice not to track them individually elsewhere.
        guard mouseButtonPolicy.mouseDown(
            button: .other,
            surfaceIdentity: currentMouseSurfaceIdentity
        ) == .send else {
            return
        }
        sendMouseButton(
            .press,
            button: GhosttyInputMapper.mouseButton(event.buttonNumber),
            event: event
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        guard mouseButtonPolicy.mouseUp(
            button: .other,
            surfaceIdentity: currentMouseSurfaceIdentity
        ) == .send else {
            return
        }

        sendMouseButton(
            .release,
            button: GhosttyInputMapper.mouseButton(event.buttonNumber),
            event: event
        )
    }

    // A held button always produces `mouseDragged`/`rightMouseDragged`/
    // `otherMouseDragged`, never `mouseMoved`/`mouseEntered`/`mouseExited` — but
    // AppKit can still deliver a stray boundary/hover event mid-gesture
    // (trackpad-driven ambiguity, an event racing a click's dispatch) with a
    // button still physically held. Reporting position to libghostty in that
    // state risks it treating the event as drag-adjacent for whatever
    // left-over press/selection state it's tracking, so every non-drag
    // position/boundary sender (the three handlers below plus the ⌘-probe
    // in `flagsChanged`) shares this same "only when nothing is
    // actually held" gate — independent of whether `mouseDown` actually ran
    // for the current gesture (see its own comment: it always does now).
    var hasNoMouseButtonHeld: Bool {
        NSEvent.pressedMouseButtons == 0
    }

    override func mouseMoved(with event: NSEvent) {
        logMouseDiagnostic(event: "mouse-moved", extra: "gated=\(!self.hasNoMouseButtonHeld)")

        guard hasNoMouseButtonHeld else {
            return
        }

        sendMousePosition(event)
    }

    // Mirrors Ghostty's `mouseEntered`/`mouseExited`: reset libghostty's
    // pointer position at tracking-area boundaries. Without `mouseExited`
    // sending (-1, -1), libghostty keeps believing the pointer is at its
    // last in-bounds cell after the cursor leaves the surface — mouse-mode
    // reports and selection logic that gate on "is the pointer in the
    // viewport" never see it leave.
    override func mouseEntered(with event: NSEvent) {
        logMouseDiagnostic(event: "mouse-entered", extra: "gated=\(!self.hasNoMouseButtonHeld)")

        guard hasNoMouseButtonHeld else {
            return
        }

        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        logMouseDiagnostic(event: "mouse-exited", extra: "gated=\(!self.hasNoMouseButtonHeld)")

        // Pointer left the surface — no link is hovered anymore. libghostty also
        // emits a nil `MOUSE_OVER_LINK` shortly, but dismiss here too so the peek
        // doesn't linger the full grace window after the cursor is gone.
        dismissLinkPeek()

        guard let surface else {
            return
        }

        // A drag in progress keeps delivering `mouseDragged` even after the
        // cursor leaves our bounds, so don't stomp its position with (-1,-1).
        guard hasNoMouseButtonHeld else {
            return
        }

        ghostty_surface_mouse_pos(
            surface,
            -1,
            -1,
            GhosttyInputMapper.modifiers(event.modifierFlags)
        )
    }

    // Install the tracking area that makes `mouseMoved` actually fire on hover —
    // mirrors Ghostty.app's `SurfaceView_AppKit.updateTrackingAreas`. Without it
    // libghostty's pointer position only updated on click/drag, so hover-over-link
    // detection never fired (no pointing-hand cursor, no link highlight) and wheel
    // events in mouse-mode TUIs reported at a stale cell. `.activeAlways` so mouse
    // reports still flow when unfocused; `.inVisibleRect` scopes to the visible
    // portion inside the scroll wrapper.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        // Link-hover pointing-hand is an awesoMux-only affordance (Ghostty's
        // own app only shows a URL banner on hover, see `SurfaceView.swift`
        // around line 139 — it doesn't touch the cursor there), so it takes
        // priority over whatever shape the terminal program last requested.
        if mouseOverLink != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        } else if let terminalCursorShape {
            addCursorRect(bounds, cursor: terminalCursorShape)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // INT-607: the shipped mouseMoved/mouseEntered guard doesn't cover this
        // handler — if AppKit is dispatching mouseDragged with no button
        // physically held (the "AppKit's own button-tracking state confused"
        // lead), this log line proves it directly.
        logMouseDiagnostic(event: "mouse-dragged")
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // Scrolling moves the content under a peek anchored at a fixed cursor
        // point; dismiss rather than let it float over unrelated text.
        dismissLinkPeek()

        guard let surface else {
            return
        }

        // True Ghostty parity (`SurfaceView_AppKit.scrollWheel`): send ONLY the
        // wheel report, no pre-scroll `ghostty_surface_mouse_pos`. The always-on
        // `.mouseMoved` tracking area (see `updateTrackingAreas`) keeps
        // libghostty's pointer current on hover, so the report lands at the right
        // cell without an extra position push — and crucially we no longer inject
        // a stray mouse-MOTION report before every wheel event, which Ghostty
        // never does (INT-523: awesoMux was interleaving motion+wheel into the
        // inner app's stream where Ghostty sends clean wheel reports).
        //
        // 2x multiplier on PRECISE deltas (matches Ghostty): one physical scroll
        // maps to fewer, larger wheel reports instead of a flood of tiny ones.
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            GhosttyInputMapper.scrollMods(event)
        )
    }

    @IBAction func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    // Ghostty (`SurfaceView_AppKit.swift:1627-1633`) triggers the same
    // `paste_from_clipboard` binding action as `paste(_:)` — libghostty's
    // clipboard-paste handling already strips formatting, so there's no
    // separate "plain text" binding action to call.
    @IBAction func pasteAsPlainText(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    // Ghostty: `SurfaceView_AppKit.swift:1635-1641`.
    @IBAction func pasteSelection(_ sender: Any?) {
        performBindingAction("paste_from_selection")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    // Ghostty: `SurfaceView_AppKit.swift:1659-1665`.
    @IBAction func selectionForFind(_ sender: Any?) {
        performBindingAction("search_selection")
    }

    /// INT-197: the Edit menu's Copy/Paste/Select All items (nil-target,
    /// Cmd-C/V/A) validate against this view when it's the menu's resolved
    /// target. Enabling them here — instead of the old `performKeyEquivalent`
    /// keyCode dispatch — lets AppKit route the shortcuts through the menu
    /// item, which restores VoiceOver's "Copy, Edit menu" announcement and
    /// delegates keyboard-layout translation to the menu's own key-equivalent
    /// matching. When another responder (sidebar field, findbar) is first
    /// responder, the menu resolves to *that* responder, so this view yields
    /// structurally. And if resolution walks the responder chain up to this
    /// view while the surface itself is not first responder (e.g. an internal
    /// child is focused), the `isFirstResponder` gate disables the terminal
    /// edit actions — that fallthrough is intentional, not a gap.
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        Self.terminalEditActionValidation(
            action: item.action,
            hasSurface: surface != nil,
            isFirstResponder: window?.firstResponder === self
        ) ?? true
    }

    /// Pure decision for `validateUserInterfaceItem`. `nil` means "not one of
    /// the gated terminal edit actions" — the caller falls back to AppKit's
    /// default of auto-enabling any action the target responds to, so a dead
    /// surface only disables the gated actions, not everything else routed at
    /// this view. All five paste/copy variants are gated identically: they
    /// all funnel into `performBindingAction`, which silently no-ops on a
    /// dead surface, and a menu item that can't do anything should say so.
    static func terminalEditActionValidation(
        action: Selector?,
        hasSurface: Bool,
        isFirstResponder: Bool
    ) -> Bool? {
        switch action {
        case #selector(GhosttySurfaceNSView.copy(_:)),
             #selector(GhosttySurfaceNSView.paste(_:)),
             #selector(GhosttySurfaceNSView.selectAll(_:)),
             #selector(GhosttySurfaceNSView.pasteAsPlainText(_:)),
             #selector(GhosttySurfaceNSView.pasteSelection(_:)),
             #selector(GhosttySurfaceNSView.selectionForFind(_:)):
            return hasSurface && isFirstResponder
        default:
            return nil
        }
    }

    /// Returns whether the completion actually reached libghostty. `false`
    /// means the surface was torn down (process exited, view disposed)
    /// while its confirm dialog was still up — callers must not treat that
    /// as a real outcome (e.g. announcing success/cancellation to VoiceOver
    /// for a completion that silently no-opped).
    @discardableResult
    func completeClipboardRequest(
        data: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) -> Bool {
        guard let surface else {
            return false
        }

        data.withCString { cData in
            ghostty_surface_complete_clipboard_request(
                surface,
                cData,
                state,
                confirmed
            )
        }
        return true
    }

    @discardableResult
    func sendKeyEvent(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        surface: ghostty_surface_t,
        text: String? = nil,
        composing: Bool = false,
        translationModifierFlags: NSEvent.ModifierFlags? = nil
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = GhosttyInputMapper.modifiers(event.modifierFlags)
        keyEvent.consumed_mods = GhosttyInputMapper.modifiers(
            (translationModifierFlags ?? event.modifierFlags)
                .subtracting([.control, .command])
        )
        keyEvent.text = nil
        keyEvent.composing = composing
        keyEvent.unshifted_codepoint = unshiftedCodepoint(for: event)
        let shouldRefreshShellActivity = shouldRefreshShellActivityForCommandSubmit(
            action: action,
            event: event,
            text: text
        )
        let isCommandSubmit = action == GHOSTTY_ACTION_PRESS
            && Self.isCommandSubmitKey(event, text: text)
        prepareShellActivityCommandSubmit(
            shouldRefreshShellActivity: shouldRefreshShellActivity
        )

        // Only attach `text` for printable input. Control characters (< 0x20)
        // are encoded by libghostty's KeyEncoder from `keycode` + `mods`; if we
        // pass them as text the encoder skips that path and the byte goes out
        // raw. Concretely: Shift-Tab arrives as U+0019 (BackTab) and would
        // bypass the CSI Z encoding the terminal expects — Claude Code's
        // mode toggle, reverse-tab completion, etc. all break. Mirrors
        // Ghostty's reference SurfaceView_AppKit.keyAction.
        guard let text, let firstByte = text.utf8.first, firstByte >= 0x20 else {
            let handled = ghostty_surface_key(surface, keyEvent)
            observeSubmittedSSHCommandInput(
                action: action,
                event: event,
                text: text,
                handled: handled,
                isCommandSubmit: isCommandSubmit
            )
            scheduleShellActivityRefreshIfCommandSubmitted(
                handled: handled,
                shouldRefreshShellActivity: shouldRefreshShellActivity
            )
            return handled
        }

        let handled = text.withCString { cText in
            keyEvent.text = cText
            return ghostty_surface_key(surface, keyEvent)
        }
        observeSubmittedSSHCommandInput(
            action: action,
            event: event,
            text: text,
            handled: handled,
            isCommandSubmit: isCommandSubmit
        )
        scheduleShellActivityRefreshIfCommandSubmitted(
            handled: handled,
            shouldRefreshShellActivity: shouldRefreshShellActivity
        )
        return handled
    }

    func observeSubmittedSSHCommandInput(
        action: ghostty_input_action_e,
        event: NSEvent,
        text: String?,
        handled: Bool,
        isCommandSubmit: Bool
    ) {
        guard handled, action == GHOSTTY_ACTION_PRESS else {
            return
        }

        if isCommandSubmit {
            let command = submittedSSHCommandBuffer
            submittedSSHCommandBuffer = ""
            submittedSSHCommandCaptureDisabled = false
            if !command.isEmpty {
                sessionStore.noteSubmittedCommand(
                    sessionID: sessionID,
                    paneID: paneID,
                    command: command
                )
            }
            return
        }

        guard !submittedSSHCommandCaptureDisabled else {
            return
        }
        if Self.isBackspace(event, text: text) {
            if !submittedSSHCommandBuffer.isEmpty {
                submittedSSHCommandBuffer.removeLast()
            }
            return
        }
        guard let text, !text.isEmpty else {
            return
        }
        submittedSSHCommandBuffer.append(text)
        if submittedSSHCommandBuffer.count > Self.submittedSSHCommandCaptureLimit
            || !Self.isPossibleSubmittedSSHCommandPrefix(submittedSSHCommandBuffer) {
            submittedSSHCommandBuffer = ""
            submittedSSHCommandCaptureDisabled = true
        }
    }

    /// Sends IME-committed preedit text as its own key event, deliberately
    /// bypassing keycode/mods (matches Ghostty's `committedPreeditTextAction`,
    /// `SurfaceView_AppKit.swift:1490-1505`): this text was already fully
    /// resolved by the IME, so there's no real key/modifier combination to
    /// attach — encoding it with `keycode: 0, mods: NONE` tells libghostty's
    /// KeyEncoder to treat it purely as text.
    @discardableResult
    func sendCommittedPreeditText(
        _ action: ghostty_input_action_e,
        text: String,
        surface: ghostty_surface_t
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = 0
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0

        return text.withCString { cText in
            keyEvent.text = cText
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    func shouldRefreshShellActivityForCommandSubmit(
        action: ghostty_input_action_e,
        event: NSEvent,
        text: String?
    ) -> Bool {
        action == GHOSTTY_ACTION_PRESS
            && session.layout.pane(id: paneID)?.agentKind == .shell
            && Self.isCommandSubmitKey(event, text: text)
    }

    func scheduleShellActivityRefreshIfCommandSubmitted(
        handled: Bool,
        shouldRefreshShellActivity: Bool
    ) {
        guard handled,
              shouldRefreshShellActivity else {
            return
        }

        runtime.scheduleShellActivityRefreshAfterCommandSubmit(for: paneID, in: sessionStore)
    }

    func prepareShellActivityCommandSubmit(
        shouldRefreshShellActivity: Bool
    ) {
        guard shouldRefreshShellActivity else {
            return
        }

        // Clear this pane's command-finished idle latch BEFORE the global
        // refresh so the submit's own sample reads the true prompt-marker
        // state instead of a stale latch left by the previous command.
        shellCommandFinishedIdleLatched = false
        runtime.refreshShellActivity(in: sessionStore)
    }

    func ghosttyText(for event: NSEvent) -> String? {
        guard let characters = event.characters, !characters.isEmpty else {
            return nil
        }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(
                    byApplyingModifiers: event.modifierFlags.subtracting(.control)
                )
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }

    func unshiftedCodepoint(for event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let characters = event.characters(byApplyingModifiers: []),
              let scalar = characters.unicodeScalars.first else {
            return 0
        }

        return scalar.value
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else {
            return false
        }

        return action.withCString { cAction in
            ghostty_surface_binding_action(
                surface,
                cAction,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
    }

    func writeFromChrome(_ text: String) {
        sendText(text)
        window?.makeFirstResponder(self)
    }

    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else {
            return
        }

        let shouldRefreshShellActivity = session.layout.pane(id: paneID)?.agentKind == .shell
            && text.contains(where: { $0 == "\n" || $0 == "\r" })
        prepareShellActivityCommandSubmit(
            shouldRefreshShellActivity: shouldRefreshShellActivity
        )

        text.withCString { cText in
            ghostty_surface_text(
                surface,
                cText,
                UInt(text.lengthOfBytes(using: .utf8))
            )
        }

        if shouldRefreshShellActivity {
            runtime.scheduleShellActivityRefreshAfterCommandSubmit(for: paneID, in: sessionStore)
        }
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else {
            return
        }

        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { cText in
                ghostty_surface_preedit(
                    surface,
                    cText,
                    UInt(text.lengthOfBytes(using: .utf8))
                )
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// Returns whether the button state actually reached libghostty. Mouse
    /// handlers ask `GhosttySurfaceMouseButtonPolicy` before calling this so a
    /// press that missed the current surface — or reached an older surface
    /// incarnation — cannot let its paired release through later.
    @discardableResult
    func sendMouseButton(
        _ state: MouseButtonState,
        button: ghostty_input_mouse_button_e,
        event: NSEvent
    ) -> Bool {
        guard let surface else {
            return false
        }

        // INT-632: only the left button ever opens a link, so only the left
        // button ever gets the bypass. Compute the decision once at press —
        // never at release, see `leftClickLinkBypassActive`'s doc comment —
        // and reuse it unchanged for the paired release. No hover gate here:
        // libghostty's own (continuously refreshed) over_link state decides
        // whether the click opens a link; our job is only to make the mods
        // match what physical ⌘⇧ would send.
        var mods = GhosttyInputMapper.modifiers(event.modifierFlags)
        if button == GHOSTTY_MOUSE_LEFT {
            if state == .press {
                leftClickLinkBypassActive = ghostty_surface_mouse_captured(surface)
                    && event.modifierFlags.contains(.command)
            }
            if leftClickLinkBypassActive {
                mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue)
            }
        }

        // Ghostty's `SurfaceView_AppKit.mouseDown`/`mouseUp` never send a
        // position report before the button event — the tracking area keeps
        // libghostty's pointer current. A pre-button position report is a
        // second, redundant input the inner mouse-mode app has to consume.
        ghostty_surface_mouse_button(
            surface,
            state.ghosttyState,
            button,
            mods
        )
        return true
    }

    func sendMousePosition(_ event: NSEvent) {
        guard let surface else {
            return
        }

        // INT-632: continuous injection while captured + ⌘ held keeps
        // libghostty's over_link hover state fresh through cursor drift —
        // see `GhosttyInputMapper.mouseModifiers` for why one-shot isn't
        // enough and why the motion-report trade-off is accepted.
        let pos = mousePosition(for: event)
        ghostty_surface_mouse_pos(
            surface,
            pos.x,
            pos.y,
            GhosttyInputMapper.mouseModifiers(
                event.modifierFlags,
                // ⌘ test first: mouse_captured takes libghostty's renderer
                // mutex, and this runs per motion event — short-circuit past
                // it on the vast majority of moves where ⌘ isn't held.
                mouseCaptured: event.modifierFlags.contains(.command)
                    && ghostty_surface_mouse_captured(surface)
            )
        )
    }

    // INT-138: NO clamp. libghostty treats negative coordinates as the "cursor
    // left the viewport" sentinel (same contract upstream relies on:
    // `SurfaceView_AppKit.swift` mouseMoved/mouseEntered pass raw
    // `frame.height - pos.y`, and its drags delegate straight to mouseMoved —
    // no `max(0, …)` anywhere). A drag that exits the top/left edge must be
    // able to report negatives so mouse-mode/selection logic sees the pointer
    // leave; clamping to 0 pins it to an edge cell instead. Call sites that
    // genuinely require an in-bounds point use `currentMousePositionInView()`,
    // which guards with `bounds.contains` and returns nil off-view.
    nonisolated static func viewMousePosition(viewLocalPoint: CGPoint, boundsHeight: CGFloat) -> CGPoint {
        CGPoint(x: viewLocalPoint.x, y: boundsHeight - viewLocalPoint.y)
    }

    func mousePosition(for event: NSEvent) -> CGPoint {
        Self.viewMousePosition(
            viewLocalPoint: convert(event.locationInWindow, from: nil),
            boundsHeight: bounds.height
        )
    }

    /// INT-632: `flagsChanged` events aren't mouse events — `locationInWindow`
    /// on them isn't a documented-reliable source of the current pointer
    /// position the way it is for real mouse events. `NSEvent.mouseLocation`
    /// (screen coordinates, always current regardless of event type) is the
    /// correct primitive for "where is the mouse right now," independent of
    /// what triggered this call.
    ///
    /// Returns nil when the pointer isn't over this view: libghostty treats
    /// only NEGATIVE coordinates as "outside the viewport," so a clamped
    /// out-of-bounds point would fabricate an in-viewport report and undo
    /// the (-1,-1) pointer-left sentinel `mouseExited` sent.
    func currentMousePositionInView() -> CGPoint? {
        guard let window else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = convert(windowPoint, from: nil)
        guard bounds.contains(localPoint) else {
            return nil
        }
        return Self.viewMousePosition(viewLocalPoint: localPoint, boundsHeight: bounds.height)
    }

    /// INT-607 (mouse-move selection bug, unresolved by PR #292) diagnostic —
    /// rides the existing `AWESOMUX_TERMINAL_DIAGNOSTICS` toggle
    /// (`script/build_and_run.sh --terminal-diagnostics`) rather than a
    /// one-off env var, so it's on-demand and doesn't need its own cleanup
    /// pass. `NSEvent.pressedMouseButtons` is logged on every call site so a
    /// live capture can show whether AppKit is dispatching `mouseDragged` while
    /// no button is actually held.
    func logMouseDiagnostic(event: String, extra: @autoclosure @escaping () -> String = "") {
        guard Self.terminalDiagnosticsEnabled else {
            return
        }

        Self.terminalDiagnosticsLogger.info(
            """
            terminal-diagnostics event=\(event, privacy: .public) \
            pane=\(self.paneID.uuidString.prefix(8), privacy: .public) \
            pressed=\(NSEvent.pressedMouseButtons, privacy: .public) \
            \(extra(), privacy: .public)
            """
        )
    }
}

enum MouseButtonState {
    case press
    case release

    var ghosttyState: ghostty_input_mouse_state_e {
        switch self {
        case .press:
            GHOSTTY_MOUSE_PRESS
        case .release:
            GHOSTTY_MOUSE_RELEASE
        }
    }
}
