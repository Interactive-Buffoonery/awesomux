# Terminal Color Diagnostics

Use this loop when Claude Code or another terminal UI renders with the wrong
foreground contrast even though the terminal background itself is correct.

The diagnostic path is intentionally opt-in. It does not add user-facing UI,
does not log full environment dumps, does not log full Ghostty config files,
and does not record Claude conversation content.

## What awesoMux Owns

Terminal color identity crosses three boundaries:

- Ghostty app/surface color scheme: light or dark, applied to the app and each
  surface when awesoMux derives terminal appearance.
- Ghostty config overrides: when awesoMux owns the terminal background
  (`catppuccinTheme` or `custom`), it emits the matching Catppuccin foreground,
  palette, cursor, and selection colors with the background.
- Spawn-time terminal identity: every surface spawn overrides the terminal color
  identity keys `TERM=xterm-ghostty`, `COLORTERM=truecolor`, and `COLORFGBG`.

`ghostty` background mode is visual pass-through for colors, but it still
advertises a light or dark terminal identity based on the effective app theme.
For custom backgrounds, awesoMux derives terminal identity from the selected
background color, so a custom dark background still advertises a dark terminal
even if the app chrome theme is light.

The runtime is initialized from settings-backed terminal appearance during app
startup. That keeps the first surface spawn from using fallback defaults before
settings bootstrap finishes.

## awesoMux Logs

Run the app bundle with gated terminal diagnostics:

```sh
./script/build_and_run.sh --terminal-diagnostics
```

This sets `AWESOMUX_TERMINAL_DIAGNOSTICS=1` for that launch and streams only the
`TerminalDiagnostics` log category. Expected events include:

- `runtime-initialize`
- `runtime-apply-appearance`
- `color-scheme-apply`
- `surface-spawn`
- `surface-color-scheme-apply`

The log includes terminal appearance mode, effective theme, terminal color
scheme, a foreground/background/palette summary, and only these spawn-time
environment keys:

- `TERM`
- `COLORTERM`
- `COLORFGBG`
- `NO_COLOR`
- `FORCE_COLOR`
- `TERM_PROGRAM`
- `TMUX`
- `TMUX_PANE`
- `ZELLIJ`
- `STY`
- `MOSHI_SESSION`
- `SSH_CONNECTION`
- `SSH_CLIENT`
- `SSH_TTY`

Path-like and control-character values are redacted or sanitized before logging.

## Terminal Probe

Run the probe inside the terminal being tested:

```sh
script/terminal-color-probe.sh --label awesomux-installed-open --claude
```

The probe writes a timestamped artifact directory under
`"$TMPDIR/awesomux-terminal-diagnostics"` by default (override with
`AWESOMUX_TERMINAL_DIAGNOSTICS_DIR`) containing:

- `metadata.txt`: sanitized env/capability facts, `tput colors`, terminfo color
  evidence, and the Ghostty color-scheme DSR result. The probe sends the DSR
  *query* `CSI ? 996 n` and Ghostty responds with `ESC [ ? 997 ; N n` where
  `N=1` is dark and `N=2` is light. The metadata records this as three
  separate keys: `ghostty_color_scheme` (the parsed verdict —
  `dark`/`light`/`unknown`/`no-response`/`tmux-skipped`),
  `ghostty_color_scheme_dsr_raw_hex` (the raw response bytes as lowercase
  hex), and `ghostty_color_scheme_dsr` (the same response in shell-escaped
  form, kept for compatibility with prior capture protocols).
- `swatches.ansi`: deterministic normal, bright, bold, dim/faint, and truecolor
  swatches.
- `screenshot.png`: only when `--screenshot` is passed — otherwise no
  screenshot field appears in `metadata.txt`.

Most boundary mismatches can be diagnosed from `metadata.txt` alone — env
identity (TERM/COLORTERM/COLORFGBG), DSR verdict, and terminfo evidence are
plain key=value text. The `swatches.ansi` and `screenshot.png` artifacts
exist for the final "env/DSR match across terminals but rendering still
differs" row of the matrix below.

For a differential comparison, run the same command from the same checkout in
all reference terminals:

```sh
script/terminal-color-probe.sh --label awesomux-installed-open --claude
script/terminal-color-probe.sh --label ghostty --claude
script/terminal-color-probe.sh --label iterm --claude
```

Use `--screenshot` when you want an interactive screenshot saved next to the
metadata and swatch files.

## Diagnosis Matrix

| Evidence | Likely next boundary |
| --- | --- |
| awesoMux reports light or no DSR while Ghostty/iTerm report dark | Ghostty color-scheme boundary |
| Env/DSR match but awesoMux swatches differ | Ghostty config application or palette/faint-opacity behavior |
| Swatches match but Claude differs | Claude Code theme selection/config |
| Only dim/faint samples differ | `faint-opacity` |

awesoMux emits `faint-opacity = 0.95` only when it owns Latte/light palette
output. This preserves Latte text colors that already clear WCAG AA at full
opacity; it cannot make ANSI colors below 4.5:1 at full opacity pass AA — and
most Latte ANSI slots are below it: 14 of 16 fail 4.5:1 against `#eff1f5`
(palette[15] is 1.61:1).

Treat the matrix as a guide, not a reason to patch blindly. Capture artifacts
first, then choose the smallest boundary that explains the mismatch.

## 2026-05-17 Claude Code Finding

The installed/open awesoMux launch path was confirmed with artifact set:

```text
$TMPDIR/awesomux-terminal-diagnostics/20260517T180200Z-awesomux-installed-open
```

That run reported:

```text
term=xterm-ghostty
colorterm=truecolor
colorfgbg=15;0
no_color=unset
force_color=unset
term_program=ghostty
tput_colors=256
ghostty_color_scheme_dsr=$'\E[?997;2n'
```

Claude Code rendered with the expected dark foreground contrast in that launch.
The DSR response still reported light, so the DSR mismatch alone is not the
current Claude contrast regression. Keep the DSR observation in diagnostics,
but do not chase it as the next fix unless swatches or Claude rendering regress
again with matching env/config evidence.
