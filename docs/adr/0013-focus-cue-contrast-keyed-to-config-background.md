# 0013 - Focus-cue contrast stays keyed to the config background

## Status

Accepted (INT-530).

## Context

The active-pane focus stripe, dim scrim, and `.needs` attention cue key their
contrast off the terminal background color. That color is read once from the
finalized libghostty config (`ghostty_config_get(config, &color, "background",
...)` in the config-build path) and surfaced as
`GhosttyRuntime.terminalBackgroundColor`. That source is trusted *because*
only the user controls it: it comes from the config file on disk, not from
anything a process can write to the pty.
`AwColors.focusAccent(_:terminalBackground:)` then enforces the WCAG 1.4.11
3:1 non-text floor against it, falling back to black/white when both tuned
accent variants miss the floor.

awesoMux does not yet handle runtime OSC 11 background changes
(`GHOSTTY_ACTION_COLOR_CHANGE`, kind BACKGROUND). A security review flagged
that when someone wires that action, the reported background becomes writable
by anything with pty access. A hostile process could then report a background
chosen to minimize the focus stripe's contrast — degrading the `.needs`
attention cue below legibility while the actual painted background stays
unchanged or flickers. Precedent: `RemoteSessionDetector` already drops OSC 7
reports from non-local hosts for the same anti-spoofing reason.

## Decision

- Focus-cue contrast remains keyed to the config-derived background.
  `GhosttyRuntime.terminalBackgroundColor` is written only from the finalized
  config build; no runtime escape-sequence report may write it directly.
- If OSC 11 runtime color changes are ever wired, the reported color must pass
  through a sanitizer before reaching any focus-cue consumer. The sanitizer
  must clamp runtime reports so the `.needs` stripe and other focus cues never
  fall below the WCAG 1.4.11 3:1 floor that
  `AwColors.focusAccent(_:terminalBackground:)` enforces. The expected entry
  point name is `sanitizedRuntimeBackgroundColor`; the guard test keys on it.
- `FocusCueColorSourceGuardTests` pins both constraints: it fails if
  `GHOSTTY_ACTION_COLOR_CHANGE` handling appears in `Sources/` without the
  sanitizer, and if `GhosttyRuntime.terminalBackgroundColor` grows a second
  write site outside the config build.

## Consequences

- Until OSC 11 is wired, apps that change their background at runtime (e.g.
  theme-switching shells) will not update the focus-cue contrast until the
  next config reload. That staleness is accepted; the cue's legibility floor
  is the safety property, not freshness.
- Future OSC 11 work must update the guard test deliberately — routing the
  report through the sanitizer — rather than silently rebinding the cue to an
  attacker-influenced value.
- The guard tests enforce token presence — tripwire semantics, not data flow.
  They prove the sanitizer name appears at a call site in any file touching
  the color-change action; they cannot prove the report actually flows
  through it. Routing correctness remains a code-review responsibility. Once
  OSC 11 handling lands, the string scans should be superseded by a
  behavioral test that feeds a hostile background through the handler and
  asserts the `.needs` cue still clears the 3:1 floor.
