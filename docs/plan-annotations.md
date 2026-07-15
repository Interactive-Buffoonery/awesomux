# Plan annotations: the AMX marker contract

**Tracking:** GitHub Issues are the public handoff for changes to this contract.
**Status:** contract draft — the format below is authoritative once an implementation PR
references it; changes after that require a migration note in this file.

This document is the contract for structured plan annotations stored in Markdown files
rendered by the awesoMux document pane. It defines the marker grammar, field schema,
lifecycle, anchoring rules, escaping, migration from the INT-562 comment format, and the
privacy boundary. Parser, writer, and UI code must implement this file, not the other way
around.

## Design constraints (inherited)

- **The file is the channel.** All annotation state lives in the Markdown file itself.
  No sidecar files, no database rows, no in-memory-only state that a reload would lose.
  (A UI may keep a derived cache; the file always wins.)
- **Hidden or harmless in other renderers.** Markers are single-line HTML comments —
  invisible in every Markdown renderer. The `<mark>` anchor renders as an ordinary
  highlight where GFM HTML is supported and as inert markup elsewhere. Nothing may render
  as a broken widget or corrupt prose.
- **Survive ordinary agent edits.** An agent editing prose around (or inside) an anchored
  span must not orphan the annotation. Deleting the span and its marker is a legitimate
  resolution, not corruption.
- **Clean room.** Plannotator is product inspiration only. No source, assets, schema
  names, field names, or prose from Plannotator or its forks may be copied. Everything
  below derives from awesoMux's own INT-562 format and naming (`amx` is the product's
  existing CLI/automation prefix).

## Marker grammar

Two marker forms, both single-line HTML comments. `AMX` immediately after `<!--`
distinguishes them from ordinary comments; the required `id=`/`re=` key keeps ordinary
prose out of the schema. Markers are recognized only where a Markdown parser sees
inline or block HTML — annotation-shaped text inside code fences or inline code is
inert, for the parser and the writer alike. If a document ever contains two annotation
markers with the same id (hand edits, merges, or smuggled text), reads surface the
first and writes are refused for that id — fail closed, never guess which marker was
meant.

```
annotation := "<!-- AMX " keys [": " payload] " -->"
thread-note := "<!-- AMX re=" id " " keys ": " payload " -->"

keys    := key "=" value (" " key "=" value)*
key     := [a-z]+
value   := [a-z0-9-]+          ; constrained token, never quoted, never escaped
payload := sanitized free text  ; see Escaping
```

- Keys and values are lowercase tokens. Unknown keys are preserved on rewrite and
  ignored by the parser (forward compatibility without a version field; if the grammar
  itself ever has to change incompatibly, the prefix versions it: `AMX2`).
- The payload is everything between the first `": "` after the keys and the closing
  ` -->`.

### Span-anchored annotation

Immediately follows a `<mark>` span, exactly like the INT-562 format:

```markdown
Deploy happens <mark>after the migration completes</mark><!-- AMX id=q3k7 by=user intent=replace: before the migration starts -->
```

### Document-level annotation

A marker on its own line (a block-level HTML comment), not preceded by `</mark>`. It
is the document's single whole-document note — feedback with no sensible highlighted
span. The writer appends it at the end of the file, blank-line separated, and refuses
to add another; the parser accepts it anywhere.

```markdown
<!-- AMX id=w8p2 by=user intent=comment: Overall this plan skips rollback entirely -->
```

The anchor type is implicit: a marker consumed while a `<mark>` pairing is pending is
span-anchored; any other position is document-level. No `target=` key.

### Thread note

A follow-up reply on an existing span annotation, from either side of the conversation.
`re=` references the annotation id. Notes have no ids of their own; within one
annotation's thread they are ordered by file position, and v1 treats them as
append-only (edit/delete of individual notes is by position, UI-side).
The whole-document note has no reply thread.

```markdown
<!-- AMX re=q3k7 by=claude-code: Reordered; migration now gates the deploy step -->
```

Placement is free — the writer puts a note immediately after the marker it replies to
when that marker still exists, otherwise at the end of the file. A note whose `re=` id
matches no annotation is orphaned: preserved in the file, hidden from the UI.

## Field schema

| Key      | Required | Values                                             | Default   |
|----------|----------|----------------------------------------------------|-----------|
| `id`     | yes      | see Identifiers                                    | —         |
| `by`     | yes      | `user`, `claude-code`, `codex`, `pi`, `opencode`   | —         |
| `intent` | no       | `comment`, `replace`, `delete`                     | `comment` |
| `status` | no       | `open`, `resolved`                                 | `open`    |
| `re`     | thread notes only | an annotation id                          | —         |

- `by` is the author. Use the exact runtime provider identifiers; never write a generic
  `agent` value when the provider is known (INT-580 provider scope). `user` is the
  human in the pane.
- The parser applies defaults for omitted `intent`/`status`; the writer omits keys at
  their default value so untouched markers stay short.

### Intent semantics

The payload's meaning depends on intent:

| Intent    | Anchor          | Payload                                            |
|-----------|-----------------|----------------------------------------------------|
| `comment` | span or document | The note text.                                    |
| `replace` | span only       | The suggested replacement for the marked span.     |
| `delete`  | span only       | Optional rationale; may be empty (keys-only form). |

Rationale that doesn't fit the payload slot (e.g. *why* a replacement) travels as a
thread note on the same annotation. `replace` and `delete` require a span; the parser
demotes a document-level marker carrying those intents to `comment` rather than
guessing a target. An unknown intent value likewise parses as `comment`, so a future
intent degrades to a readable note instead of vanishing.

## Identifiers

- Generated ids are 4 lowercase base36 characters containing **at least one letter**
  (e.g. `q3k7`), drawn randomly; the writer re-rolls on collision within the document.
  Ids are stable for the annotation's lifetime and are never renumbered.
- Legacy INT-562 comments surface with their integer as a string id (`"3"`). The
  at-least-one-letter rule keeps the two namespaces disjoint, so migration never
  collides and `re=` can reference either.
- Ids are unique per document, not globally. Handoff text (INT-582) always pairs ids
  with the document path.

## Lifecycle

```
            create                    handle                    verify + clear
  (user in pane, or agent    ─►  status=resolved  (either  ─►  marker removed
   writing the file)              party flips the key)          (either party)
        status=open
```

- **Create.** The pane writes a marker through the annotation storage layer; an agent
  may equally write one directly into the file (it's just Markdown).
- **Resolve (soft).** Flipping `status=resolved` keeps the marker and mark in place so
  the human can verify what was done. This is the preferred agent behavior for
  annotations it has acted on.
- **Reply.** The pane's writer reopens a resolved annotation when a reply is appended
  (`status` flips back to `open` in the same write): a reply is review activity and
  must not land hidden behind the resolved filter. An agent replying by hand should
  follow the same rule.
- **Edit.** Changing an annotation's payload reopens it. Edited feedback is new review
  activity and must be handled again.
- **Remove (hard).** Deleting the marker — and for span anchors, unwrapping
  `<mark>…</mark>` back to its inner text — ends the annotation. The INT-562 agent
  convention ("handle it, then remove the marker") remains valid and simply skips the
  soft-resolve step. The pane removes annotations individually today; a bulk
  clear-resolved control is tracked as follow-up work.
  The pane's writer also removes the annotation's thread notes on hard removal so
  files don't accumulate hidden orphans; an agent removing a marker by hand may leave
  notes behind, and they stay harmless (orphaned, hidden).
- Storage state never implies delivery: `status=resolved` means someone wrote the key,
  not that bytes reached a verified agent prompt (INT-569 owns that boundary).

Future states (e.g. a rejected/wont-do status) extend the `status` value set; parsers
must treat an unknown status as `open` rather than failing, and rewrites must re-emit
the raw value verbatim (same rule as unknown keys) so a newer schema's state survives
a round trip through an older build. The same applies to unknown `intent` values.

## Anchoring and durability

- One annotation per `<mark>` span; marks do not nest. Additional feedback on the same
  span is a thread note, not a second mark.
- Edits inside a marked span leave the annotation attached (the mark travels with the
  text). Deleting the span plus marker is hard removal.
- A `<mark>` with no adjacent `AMX`/`USER COMMENT` marker is plain author markup and is
  left alone.
- Rapid external rewrites are handled by the reload path, not the format: the parser is
  pure over whatever bytes it is handed.

## Escaping

The payload inherits the INT-562 sanitizer hazards and rules verbatim
(`CommentMarkerWriter.sanitizeNote`):

1. Multiline payloads add `encoding=lines`; backslashes become `\\\\` and CR/LF
   become the two-character sequence `\\n`, keeping markers single-line while
   round-tripping paragraphs. Markers without `encoding=lines` retain the legacy
   behavior where literal `\\n` remains literal text.
2. A literal `-->` gets a zero-width space between `--` and `>` so it cannot close the
   comment early; the parser strips the zero-width space again, so the payload
   round-trips verbatim.
3. A literal `|` is written as `\|` so a marker inside a GFM table cell cannot split
   the row; the parser unescapes outside tables.

Keys and values are constrained tokens and need no escaping. The sanitizer's transforms
are exhaustive over the format's known hazards; there is no separate rejection path
today — a new hazard must extend the sanitizer (and this list) rather than assume one.
Payloads are capped at 8 KiB of stored (escaped) text, enforced on both sides: the
writer refuses a payload whose escaping expands past the cap, and an oversized marker
fails to parse and stays an inert comment, so a runaway writer can't buy an unbounded
layout or screen-reader read with one line.

## Rendering rules

- Marker text never reaches rendered runs — same invariant as INT-562: joined run text
  contains no `<mark>`, `</mark>`, or `<!-- … -->` markup.
- Span-anchored annotations render as the existing highlight-plus-badge affordance,
  keyed by string id instead of integer.
- The single whole-document note renders in pane chrome, not as an inline artifact.
- Thread notes belong to span annotations and render with their inline annotation UI.
- Resolved span annotations render visually de-emphasized; a filter control hides their
  in-document highlights and pills. The document note remains available from pane chrome
  when resolved so it can be reopened or deleted.

## Migration from `USER COMMENT`

- `<mark>…</mark><!-- USER COMMENT N: note -->` continues to parse forever, surfacing
  as `{id: "N", by: user, intent: comment, status: open}`. `by=user` is an assumption
  the legacy format cannot record; it matches how those markers were created.
- **Upgrade on write.** Any write that touches a legacy annotation (note edit, status
  change, thread reply) rewrites that one marker to the AMX form, keeping id `N`.
  Untouched legacy markers are never rewritten — no bulk migration pass over user
  files.
- New annotations always use the AMX form; the legacy integer allocator
  (`nextCommentNumber`) stops being used for inserts.
- The agent-facing nudge text (`NudgeComposer`) must describe both conventions during
  the transition, and must tell agents about soft resolve (`status=resolved`).

## Write safety

awesoMux reads through the bounded secure-file path and binds the render to its resolved
URL, device/inode identity, and exact bytes. Save renders the marker-local change without
merging content, then coordinates the replacement with participating file writers.
Inside coordination it revalidates that render-time identity and performs one final
bounded byte comparison before an atomic, metadata-preserving replacement. Any source,
alias-target, or resolved-file change observed before that replacement refuses the write.

This is not a universal filesystem compare-and-swap. `NSFileCoordinator` serializes
writers that participate in coordination, but an unrelated process can ignore it and
race after awesoMux's final comparison. On an observed conflict, the pane reloads and
keeps the draft. Existing annotation and reply drafts retry against the same stable id
only when that annotation itself is unchanged after reload. A new text selection cannot
be remapped safely, so the pane asks the user to copy the draft and select the text again.

## Privacy boundary

Annotations may carry exactly: id, author (`by`), intent, status, and the payload text a
person or agent deliberately wrote. They must never carry prompt text, tool input,
terminal transcript content, file paths outside the document, model, token, branch, PR,
or cost metadata (ADR-0008 posture; matches the INT-569/INT-582 constraints). Remember
the file is plain Markdown that gets committed, shared, and diffed — treat every field
as public.
