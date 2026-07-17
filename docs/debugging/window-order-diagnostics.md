# Window-order diagnostics

Use this opt-in capture for INT-746, where the main window's inline Agents
roster has appeared briefly over another foreground app. The mode adds logging
only; it does not change activation, ordering, or roster behavior.

## Capture

1. Run `./script/build_and_run.sh --window-diagnostics`.
2. Open the Agents roster in the expanded sidebar.
3. Switch to the app where the flash has been observed and work normally.
4. When the flash occurs, note the time and keep the log stream running for a
   few seconds. A screen recording makes the visual timestamp easier to match.
5. Quit the diagnostic awesoMux build. Save the terminal output around the
   incident, including at least ten seconds before and after the flash.

The filtered stream records:

- application active/resign transitions and the frontmost bundle identifier;
- primary-window key, main, visibility, miniaturization, occlusion, level, and
  ordered-window-index transitions;
- `applicationShouldHandleReopen` decisions for visible and no-window states;
- every `surfacePrimaryWindow` attempt with its source location;
- Agents-roster open state and sidebar display/presentation state.

The diagnostics do not record window titles, paths, terminal contents, agent
content, or typed characters. The environment gate is read once at process
startup and is disabled unless its value is exactly `1`.

## Interpret the trace

- A `surface-primary-window-begin` immediately before the flash identifies an
  awesoMux call site to investigate.
- Window on-screen/key/main transitions without a surfacing event point to
  AppKit or another direct window-order path.
- Roster or sidebar transitions without window-order changes point to a
  SwiftUI presentation-state issue.

Do not change floating-panel behavior or add an activation delay based only on
the presence of an app active/resign pair. Fix the smallest mechanism shown by
the captured sequence, then reproduce the same trigger and add a focused policy
test where that policy can be isolated from AppKit.
