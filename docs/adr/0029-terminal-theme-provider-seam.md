# 0029 - Terminal theme provider seam

## Status

Accepted (INT-654).

## Context

awesoMux currently owns terminal-content color emission only for the shipped
Catppuccin path. `TerminalBackgroundMode.catppuccinTheme` resolves a light/dark
background, foreground, ANSI-16 palette, cursor color, and selection colors
from Catppuccin constants before writing the generated Ghostty override config.
`TerminalBackgroundMode.ghostty` leaves colors to Ghostty or the user's
`~/.config/ghostty/config`, while `.custom` lets the user type a background
hex directly and keeps the existing contrast-matched Catppuccin foreground and
palette.

INT-285 needs future Ghostty/iTerm theme import without folding a theme name
into the existing light/dark axis. `EffectiveTheme` is the resolved terminal
identity (light or dark) used for `COLORFGBG` and background selection; it is
not a named theme identifier. The settings preview already showed why this
boundary matters: code that asked the Catppuccin helper directly would preview
the wrong background as soon as any non-Catppuccin provider exists.

ADR 0013 keeps focus-cue contrast keyed to the config-derived terminal
background. This decision does not change that trust boundary; it only changes
which app-owned provider supplies the generated config colors before Ghostty
finalizes the config.

## Decision

Introduce a terminal-theme provider seam in `AwesoMuxConfig`.

- `TerminalThemeProvider` is intentionally small: background, foreground, and
  ANSI-16 palette for an `EffectiveTheme`.
- `CatppuccinThemeProvider` is the one built-in implementation and owns the
  current Catppuccin Mocha/Latte data. Its Ghostty adapter supplies the extra
  cursor and selection lines needed to reproduce today's generated config
  byte-for-byte without widening the base protocol.
- `TerminalThemeCatalog` is the registry. It currently has one built-in id,
  `catppuccin`; nil, unknown, and explicit `catppuccin` resolution all fall
  back to the built-in provider because there is no second provider yet.
- `AppearanceConfig.terminalThemeID` is a separate optional TOML field,
  encoded as `terminal_theme_id` under `[appearance]`. It defaults to nil via
  the same additive `decodeIfPresent(...) ?? defaultValue` pattern as other
  post-v1 appearance fields. Nil means the built-in Catppuccin provider today;
  explicit `"catppuccin"` is equivalent.
- The existing `terminal_background_mode` and `terminal_background_color`
  fields remain intact. The mode still answers who owns the background
  (`ghostty`, named app theme, or direct custom hex); the theme id only names
  the provider used by app-owned named theme paths.
- `.custom` mode remains a direct user-authored hex escape hatch. Its
  background is not routed through the named provider registry. The supporting
  foreground and ANSI palette stay on the current Catppuccin contrast set until
  a separate issue designs richer custom color ownership.

## Consequences

- Catppuccin output remains behaviorally and byte-for-byte stable for current
  users: same background presets, same Mocha/Latte hex values, same palette,
  same cursor/selection lines, same faint-opacity mitigation.
- Future imported themes can add providers and registry entries without
  changing the light/dark identity enum or overloading `terminal_background_*`
  keys with theme selection semantics.
- Existing TOML files continue to decode. Re-encoding a config with nil
  `terminalThemeID` omits `terminal_theme_id`; setting `"catppuccin"` round
  trips explicitly.
- Settings preview and runtime fallback background resolution now use the
  registry-backed provider, so a future non-Catppuccin id can preview and
  backstop through its own background instead of showing Catppuccin by habit.
