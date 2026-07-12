# 0001 — Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-05-01
- **Deciders:** eD, Sarah

## Context

awesoMux is a young project — early SwiftPM scaffold, libghostty not yet wired in, several locked decisions in `AGENTS.md` and several still open. As the codebase grows, decisions about architecture (terminal backend integration, persistence, IPC, agent plug-in surface, etc.) will accumulate. Without a durable record, the *why* behind each choice rots: comments lie, commit messages get squashed, conversations vanish.

Several engineering skills (`improve-codebase-architecture`, `diagnose`, `tdd`, the team-review skills) are designed to read a `docs/adr/` directory before proposing changes — both to honour past decisions and to flag conflicts loudly when they arise.

## Decision

We will record significant architectural decisions as Architectural Decision Records (ADRs) in `docs/adr/`, following the lightweight convention popularised by Michael Nygard.

- Files are numbered sequentially: `0001-…`, `0002-…`, etc. The number is permanent — never renumber.
- Filenames are kebab-case, derived from the title: `0042-vendor-libghostty-as-xcframework.md`.
- Each ADR has the headers: **Status**, **Date**, **Deciders**, then sections **Context**, **Decision**, **Consequences**.
- Statuses: `Proposed`, `Accepted`, `Deprecated`, `Superseded by ADR-NNNN`.
- Superseding an ADR doesn't delete the old one — mark it `Superseded` and link forward.

What warrants an ADR (rough heuristic): a decision that, if revisited a year from now, would have someone asking "why did we do it this way?" and not finding the answer in the code. Examples: choice of terminal backend, persistence model, IPC mechanism, vendoring strategy, MIT/GPL licensing firewall, agent plug-in shape.

What does *not* warrant an ADR: implementation details, library version bumps, refactors, bug fixes.

## Consequences

- A new directory `docs/adr/` exists. Architectural decisions accumulate here as numbered files; see the directory listing.
- The engineering skills that read ADRs have somewhere to look when picking which decisions matter for a task.
- Future architectural decisions get a lightweight place to land. The bar to write one should stay low: a half-page is fine.
- `AGENTS.md` already documents some locked decisions in prose. Those will migrate to ADRs as they get revisited or as they need to be cited from elsewhere — we won't backfill the whole list eagerly.
