# 0030 — Compact terminal dismissal key model

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** Sarah

## Context

awesoMux has two compact terminal surfaces with intentionally different
lifetimes:

- **Floating Panel** is a temporary, workspace-scoped scratch terminal.
- **Terminal Companion** is a long-lived, app-wide terminal whose process and
  scrollback survive minimization and workspace changes.

Both surfaces host real terminal software, where bare Escape is an active input
key for programs such as editors, pagers, fuzzy finders, and terminal UIs.
Treating Escape as a window command at the shared panel boundary made Terminal
Companion unable to deliver that key to its terminal process. At the same time,
the Floating Panel benefits from a fast one-off dismissal path.

## Decision

- Floating Panel retains bare Escape as its smart-dismiss command. For running
  work, its existing confirmation behavior remains in force.
- Terminal Companion never intercepts bare Escape. The key is delivered to the
  hosted terminal surface.
- `Cmd-W` remains the compact-surface window command: it hides Floating Panel
  and minimizes Terminal Companion to its lower-right corner tab.
- Terminal Companion also exposes an explicit minimize control. Its explicit
  close control is the only UI action that ends the companion process.

## Consequences

- Terminal Companion no longer advertises Escape in its footer, accessibility
  hint, shortcut documentation, or feature spec.
- The two surfaces deliberately differ: Floating Panel optimizes for fast,
  disposable scratch work; Terminal Companion prioritizes terminal-program
  compatibility and persistent context.
- Shared panel event handling must only intercept Escape when a surface has
  explicitly opted into an Escape-dismiss callback.
