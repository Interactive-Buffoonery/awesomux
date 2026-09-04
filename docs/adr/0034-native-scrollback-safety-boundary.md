# 0034 — Bound Show Scrollback inside the native read

- **Status:** Proposed
- **Date:** 2026-09-04
- **Issue:** [#227](https://github.com/Interactive-Buffoonery/awesomux/issues/227)
- **PR:** [#531](https://github.com/Interactive-Buffoonery/awesomux/pull/531)

## Context

The app receives scrollbar dimensions asynchronously. Ghostty deliberately
suppresses renderer updates during synchronized output, so identical cached
dimensions do not prove the live history remained small. Checking the returned
native byte count happens after allocation and cannot protect that read.
Rows and columns alone also do not bound Unicode grapheme storage or the cost
of decompressing terminal pages.

## Decision

Add a narrow, awesoMux-owned native whole-history read. Hold the renderer mutex
while checking live page metadata and formatting into a fixed host buffer.
Reject histories exceeding row, cell, backing-page, or output-byte limits.
Return either the complete text or rejection; never expose a partial prefix.
Keep the inexpensive Swift gate as an early rejection, with the native gate
as the authority for accepted reads.

Compile the checked-in extension in a generated clone of the pinned Ghostty
source. Keep the upstream submodule clean and preserve its pin. Fingerprint
the extension for local artifact validation and CI caches, and run the native
regression suite before publishing a rebuilt library.

## Consequences

- Stable small histories continue to work. Large or uncertain histories show
  the blocked state and offer terminal scrolling or Pane > Find in Pane.
- The native code depends on internal Ghostty types. Pin updates must compile
  it and pass its tests; build preparation rejects an incompatible injection
  point instead of silently omitting the safety check.
- Reading remains synchronous under Ghostty's renderer lock. Work and memory
  are bounded, but this does not promise a fixed response time on every machine.
- A separate feature can offer recent output or paging for large histories.
  That work must preserve this native safety boundary and clearly describe any
  omitted text. VoiceOver's separate history API remains tracked in #523.
