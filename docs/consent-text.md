# Consent text

Permission requests, blocked-link confirmations, and session reap previews show
all of the subject string. Text wraps, and long content scrolls within a bounded
area so the decision buttons remain visible. Status rows may still abbreviate
identifiers. Focused consent scroll areas handle arrow keys, Page Up/Down,
and Home/End explicitly; Tab leaves the scroll area for the next control.

- Permission banners give the tool and target the full pane width below the
  actions. Their scroll areas are capped at 60 and 120 points respectively.
- Blocked-link dialogs keep the complete URL and decoded details in a 400 by
  280 point scroll area, including the Unicode/punycode comparison when needed.
  Unsafe invisible and directional characters are still scrubbed; removing a
  display length cap must not remove the anti-spoofing sanitation.
- Reap previews show the same full ID and `--force` argument used by the backend.
  The identifier grammar permits only lowercase ASCII letters, digits, and
  hyphens, so the displayed argument needs no shell quoting.

## Remaining exception: destructive dialog titles

Issue #368 deliberately leaves `AwesoMuxApp.sanitizedAlertTitle` using the
existing 60-character compact title. Removing that cap alone can make native
alert titles and bodies grow beyond the available screen. Moving those subjects
into bounded accessories needs a separate review of the shared destructive
alert presentation. Similar names that differ only after character 60 remain
ambiguous in those dialogs. This change does not establish the rule across all
consent surfaces.

## Manual verification

Use isolated development fixtures, not live permission requests or real sessions.
Check a narrow pane with a long tool and a multi-kilobyte target, a URL whose
meaningful suffix falls beyond character 200, an IDN comparison, and a maximum
length reap ID. Verify every suffix is reachable by pointer and keyboard
scrolling, buttons remain visible, copied text is complete, and VoiceOver reads
the full subject. Permission arrival must not steal terminal focus; plain Return
must not allow, and deliberate prompt focus must retain its existing shortcuts.
