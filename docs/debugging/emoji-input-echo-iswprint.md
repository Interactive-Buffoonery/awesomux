# Emoji Input Echo `<0001f973>` Placeholders

Typing an emoji such as 🥳 (U+1F973) into an awesoMux pane echoed
`<0001f973>` on the prompt line instead of the glyph. `echo`'s *output* of the
same bytes rendered fine. This is INT-140.

## Root cause: missing UTF-8 locale, not a libghostty render bug

The placeholder is zsh's line editor (zle) printing a non-printable codepoint.
zle decides printability with macOS libc `iswprint(3)`, which is locale
sensitive. In the **C locale** — what a GUI/launchd-spawned app inherits when no
`LANG`/`LC_*` is set — `iswprint` rejects *every* non-ASCII codepoint, so any
typed emoji (not just newer ones) echoes as `<NNNNNNNN>`.

Two layers must be kept apart:

- **Input echo** runs through the shell + macOS libc. Locale-gated. This is the
  broken path.
- **Output rendering** runs through libghostty, which ships its own precomputed
  Unicode width tables and grapheme clustering (DEC mode 2027). Locale
  independent. This is why `echo 🥳` always renders correctly.

So this is **not** a libghostty bug, and a `vendor/ghostty` bump would not change
it. (This corrects the issue's first comment, which proposed filing upstream
against `ghostty-org/ghostty`.)

### On the "newer emoji only" hypothesis

The issue's sharper second comment proposed that macOS libc has *stale*
`iswprint`/`wcwidth` tables that predate the U+1F900–U+1F9FF block, making only
post-2018 emoji fail. That is **not reproducible on macOS 26.5.1 (build 25F80)**:
under any UTF-8 locale, every emoji from Unicode 6.0 through 14.0 — including
U+1F973 — is printable and width 2. The decisive variable is the **locale**, not
the codepoint's age. (An older macOS with frozen UTF-8 tables could show a
per-codepoint cutoff; current macOS does not.)

## Reproduce

In an awesoMux pane (`./script/build_and_run.sh`):

```bash
# 1. The locale the shell is actually using.
echo "LC_ALL=$LC_ALL LC_CTYPE=$LC_CTYPE LANG=$LANG"
locale   # LC_CTYPE="C" with everything blank == the broken state

# 2. The three emoji are all symbols (So) — nothing categorically special.
python3 -c "import unicodedata as u; print(u.category('🥳'), u.category('🚀'), u.category('🐶'))"

# 3. Decisive probe: does macOS libc consider them printable, per locale?
printf '#include <stdio.h>\n#include <wchar.h>\n#include <locale.h>\nint main(void){setlocale(LC_ALL,"");printf("1F973=%%d 1F680=%%d 1F436=%%d\\n",iswprint(0x1F973),iswprint(0x1F680),iswprint(0x1F436));return 0;}\n' > /tmp/iswprint.c
clang /tmp/iswprint.c -o /tmp/iswprint
              /tmp/iswprint   # inherited (C) locale
LC_CTYPE=UTF-8 /tmp/iswprint  # UTF-8 ctype
```

Visually: type `echo 🥳 hello 🚀 🐶 emoji` and compare the prompt line (input
echo) against the printed output.

## Measured results (macOS 26.5.1, build 25F80)

| Locale | `iswprint(U+1F973)` | `iswprint(U+1F680/1F436)` | Emoji U+1F436…U+1FAE0 |
| --- | --- | --- | --- |
| C / none set (`LANG=""`) | `0` → placeholder | `0` → placeholder | all `iswprint=0`, `wcwidth=-1` |
| any UTF-8 (`LC_ALL`/`LC_CTYPE`/`LANG`) | `1` | `1` | all `iswprint=1`, `wcwidth=2` |

The age sweep (U+1F436 dog 2010 → U+1FAE0 melting-face 2021) showed **no**
per-codepoint cutoff under UTF-8 — they all pass. Only the C↔UTF-8 axis matters.

libc precedence holds as expected: `LC_ALL` shadows `LC_CTYPE`, which shadows
`LANG`. `LC_CTYPE=UTF-8` alone (macOS's locale-independent codeset) is enough to
flip every codepoint to printable.

## Terminal independence

This is terminal-independent **by construction**, not by an A/B we happened to
run: `iswprint(3)` lives in libSystem and its result depends only on the locale
passed to `setlocale`, never on the controlling terminal or `TERM`. zsh's line
editor calls it identically whether it runs under awesoMux, stock Terminal.app,
or iTerm2 — so the same locale yields the same placeholder behavior everywhere.
Nothing here is terminal-specific; it is purely a shell + libc + locale
interaction. awesoMux's only involvement is that it spawned shells **without** a
locale, so its panes hit the C-locale failure mode unless the parent process
already exported one. (To observe it directly in another terminal, run the
Step-3 probe there with `LANG`/`LC_*` unset.)

## Resolution in awesoMux

awesoMux's spawn environment (`TerminalAppearancePreferences`,
`Sources/AwesoMuxConfig/`) set `TERM`/`COLORTERM`/`COLORFGBG`/`TERM_PROGRAM` but
no locale. It now injects a **UTF-8 ctype fallback** (`LC_CTYPE=UTF-8`) into
spawned shells, but **only** when the inherited environment provides no UTF-8
ctype (`localeCtypeFallback(inheritedEnvironment:)`):

- GUI/launchd launch with no locale → child gets `LC_CTYPE=UTF-8`, emoji input
  echoes correctly.
- User already exports `LANG=…UTF-8` / `LC_CTYPE=…UTF-8` → untouched.
- Explicit non-UTF-8 `LC_ALL` (e.g. `LC_ALL=C`) → respected; our `LC_CTYPE`
  would be shadowed anyway, and the choice is deliberate.

We set only the ctype, not a full `LANG=en_US.UTF-8`, so character
classification is fixed without imposing a language/region the user never chose.

This does not touch libghostty or the user's shell config; it closes the gap
that left awesoMux panes in the C locale.
