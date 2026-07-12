#!/usr/bin/env bash
set -euo pipefail

LABEL="${AWESOMUX_TERMINAL_PROBE_LABEL:-terminal}"
RUN_CLAUDE=0
TAKE_SCREENSHOT=0
ARTIFACT_ROOT="${AWESOMUX_TERMINAL_DIAGNOSTICS_DIR:-${TMPDIR:-/tmp}/awesomux-terminal-diagnostics}"

usage() {
  cat >&2 <<'USAGE'
usage: script/terminal-color-probe.sh [--label awesomux|ghostty|iterm] [--screenshot] [--claude]

Runs inside the terminal being tested and writes a small diagnostic artifact set.
It captures only terminal color/capability facts, not a full environment and not
Claude conversation content. Use --claude to hand off into Claude Code after the
probe prints the artifact paths.

Suggested Claude color comparison:
  1. Build/install awesoMux: ./script/build_and_run.sh --install
  2. In awesoMux: script/terminal-color-probe.sh --label awesomux-installed-open --claude
  3. In standalone Ghostty: script/terminal-color-probe.sh --label ghostty --claude
  4. In iTerm: script/terminal-color-probe.sh --label iterm --claude

Artifacts are written under "$TMPDIR/awesomux-terminal-diagnostics" by
default (override with AWESOMUX_TERMINAL_DIAGNOSTICS_DIR).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      if [[ $# -lt 2 ]]; then
        usage
        exit 2
      fi
      LABEL="$2"
      shift 2
      ;;
    --screenshot)
      TAKE_SCREENSHOT=1
      shift
      ;;
    --claude)
      RUN_CLAUDE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

safe_label() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

sanitize_env_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'empty'
    return
  fi
  if [[ "$value" == *"/"* || "$value" == *"\\"* ]]; then
    printf 'redacted'
    return
  fi

  printf '%s' "$value" | LC_ALL=C tr -c 'A-Za-z0-9._+:;-' '_' | cut -c 1-80
}

env_value() {
  local key="$1"
  local value
  if value="$(printenv "$key" 2>/dev/null)"; then
    sanitize_env_value "$value"
  else
    printf 'unset'
  fi
}

presence_value() {
  local key="$1"
  local value
  if value="$(printenv "$key" 2>/dev/null)"; then
    if [[ -z "$value" ]]; then
      printf 'empty'
    else
      printf 'set'
    fi
  else
    printf 'unset'
  fi
}

force_color_value() {
  local value
  if ! value="$(printenv FORCE_COLOR 2>/dev/null)"; then
    printf 'unset'
    return
  fi
  if [[ -z "$value" ]]; then
    printf 'empty'
    return
  fi

  local sanitized
  sanitized="$(sanitize_env_value "$value")"
  case "$sanitized" in
    0|1|2|3|true|false|redacted)
      printf '%s' "$sanitized"
      ;;
    *)
      printf 'set'
      ;;
  esac
}

parse_dsr_color_scheme() {
  # Accept the documented Ghostty/Contour shape `ESC [ ? 997 ; N n`
  # and return `dark` / `light` / `unknown` based on N.
  local raw="$1"
  case "$raw" in
    *$'\033[?997;1n'*) printf 'dark' ;;
    *$'\033[?997;2n'*) printf 'light' ;;
    *) printf 'unknown' ;;
  esac
}

query_color_scheme_dsr() {
  # Outputs three space-separated tokens: parsed_scheme raw_hex raw_quoted.
  # `parsed_scheme` is `dark|light|unknown|no-tty|stty-unavailable|no-response|tmux-skipped`.
  # `raw_hex` is a lowercase hex dump of the raw response (empty when no data).
  # `raw_quoted` is the legacy %q-escaped form, kept for human readability.

  # Skip the DSR probe entirely inside tmux/screen — bash 3.2's `read -d`
  # ignores `stty time` once a delimiter is set, so a multiplexer that
  # doesn't passthrough `CSI ? 996 n` will block until the parent shell is
  # killed. Better to short-circuit than to hang the diagnostic loop the
  # script exists for.
  case "${TERM_PROGRAM:-}${TERM:-}" in
    *tmux*|*screen*)
      printf 'tmux-skipped  '
      return
      ;;
  esac

  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'no-tty  '
    return
  fi

  # Probe whether /dev/tty is actually connectable in this process — in
  # headless contexts (CI subprocesses, harness runners) the device node
  # exists and stats as rw but `open()` returns ENXIO/ENODEV. Detect that
  # here so subsequent redirections don't spew "Device not configured"
  # warnings.
  if ! (exec 3</dev/tty) 2>/dev/null; then
    printf 'no-tty  '
    return
  fi

  local old_stty response parsed raw_hex raw_quoted
  old_stty="$( { stty -g < /dev/tty; } 2>/dev/null || true)"
  if [[ -z "$old_stty" ]]; then
    printf 'stty-unavailable  '
    return
  fi

  # Restore the tty on any exit from this function, including SIGINT/SIGTERM
  # during the read. Without this, Ctrl-C in the 1s window leaves the user's
  # shell in `raw -echo` mode and the script that exists to debug terminals
  # becomes the bug being reported.
  # shellcheck disable=SC2064
  trap "stty '$old_stty' < /dev/tty 2>/dev/null || true; trap - RETURN INT TERM" RETURN INT TERM

  # Fail fast if we can't put the tty in raw mode — proceeding anyway
  # would read with default line discipline and could block until newline
  # arrives, which is exactly the hang we're trying to prevent.
  if ! { stty raw -echo min 0 time 10 < /dev/tty; } 2>/dev/null; then
    printf 'stty-unavailable  '
    return
  fi
  printf '\033[?996n' > /dev/tty
  # `-n 128` caps the read even if the terminal floods bytes without ever
  # sending the `n` delimiter; real DSR responses are < 20 bytes.
  IFS= read -r -s -d n -n 128 response < /dev/tty 2>/dev/null || true
  stty "$old_stty" < /dev/tty 2>/dev/null || true

  if [[ -z "$response" ]]; then
    printf 'no-response  '
    return
  fi

  response="${response}n"
  parsed="$(parse_dsr_color_scheme "$response")"
  raw_hex="$(printf '%s' "$response" | LC_ALL=C od -An -tx1 -v | tr -d ' \n')"
  raw_quoted="$(printf '%q' "$response")"
  printf '%s %s %s' "$parsed" "$raw_hex" "$raw_quoted"
}

terminfo_truecolor_evidence() {
  if [[ -z "${TERM:-}" ]]; then
    printf 'term_unset=1\n'
    return
  fi
  if ! command -v infocmp >/dev/null 2>&1; then
    printf 'infocmp_unavailable=1\n'
    return
  fi

  local evidence
  evidence="$(infocmp -1 "$TERM" 2>/dev/null | grep -E '(^[[:space:]]*(Tc|RGB),|setrgb[fb]|setaf|setab)' || true)"
  if [[ -z "$evidence" ]]; then
    printf 'no_truecolor_evidence_found=1\n'
  else
    printf '%s\n' "$evidence"
  fi
}

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
artifact_dir="$ARTIFACT_ROOT/${timestamp}-$(safe_label "$LABEL")"
metadata_path="$artifact_dir/metadata.txt"
swatches_path="$artifact_dir/swatches.ansi"
screenshot_path="$artifact_dir/screenshot.png"

mkdir -p "$artifact_dir"
# Per-user perms — `$TMPDIR` is already per-user on macOS but
# `AWESOMUX_TERMINAL_DIAGNOSTICS_DIR` can point anywhere, including a shared
# `/tmp`. Tighten regardless.
chmod 700 "$ARTIFACT_ROOT" 2>/dev/null || true
chmod 700 "$artifact_dir" 2>/dev/null || true

dsr_result="$(query_color_scheme_dsr)"
dsr_scheme="$(printf '%s' "$dsr_result" | awk '{print $1}')"
dsr_raw_hex="$(printf '%s' "$dsr_result" | awk '{print $2}')"
dsr_raw_quoted="$(printf '%s' "$dsr_result" | awk '{print $3}')"

{
  printf 'label=%s\n' "$(safe_label "$LABEL")"
  printf 'created_at_utc=%s\n' "$timestamp"
  printf 'artifact_dir=%s\n' "$artifact_dir"
  if [[ "$TAKE_SCREENSHOT" -eq 1 ]]; then
    printf 'screenshot_path=%s\n' "$screenshot_path"
  fi
  printf 'term=%s\n' "$(env_value TERM)"
  printf 'colorterm=%s\n' "$(env_value COLORTERM)"
  printf 'colorfgbg=%s\n' "$(env_value COLORFGBG)"
  printf 'no_color=%s\n' "$(presence_value NO_COLOR)"
  printf 'force_color=%s\n' "$(force_color_value)"
  printf 'term_program=%s\n' "$(env_value TERM_PROGRAM)"
  printf 'term_program_version=%s\n' "$(env_value TERM_PROGRAM_VERSION)"
  printf 'awesomux=%s\n' "$(env_value AWESOMUX)"
  printf 'columns_env=%s\n' "${COLUMNS:-unset}"
  printf 'lines_env=%s\n' "${LINES:-unset}"
  printf 'stty_size=%s\n' "$(stty size < /dev/tty 2>/dev/null || printf 'unavailable')"
  printf 'stty_all_size=%s\n' "$(stty -a < /dev/tty 2>/dev/null | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' || printf 'unavailable')"
  printf 'tput_cols=%s\n' "$(tput cols 2>/dev/null || printf 'unavailable')"
  printf 'tput_lines=%s\n' "$(tput lines 2>/dev/null || printf 'unavailable')"
  printf 'tput_colors=%s\n' "$(tput colors 2>/dev/null || printf 'unavailable')"
  printf 'fastfetch_version=%s\n' "$(fastfetch --version 2>/dev/null | head -n 1 || printf 'unavailable')"
  # `ghostty_color_scheme` is the parsed verdict — that's what humans and
  # future tooling should compare. `ghostty_color_scheme_dsr_raw_hex` is the
  # full byte sequence as lowercase hex (machine-friendly). The shell-escaped
  # `_quoted` form is retained because previous diagnostic capture protocols
  # quote it verbatim.
  printf 'ghostty_color_scheme=%s\n' "$dsr_scheme"
  printf 'ghostty_color_scheme_dsr_raw_hex=%s\n' "${dsr_raw_hex:-}"
  printf 'ghostty_color_scheme_dsr=%s\n' "${dsr_raw_quoted:-$dsr_scheme}"
  printf '\n[terminfo truecolor evidence]\n'
  terminfo_truecolor_evidence
} > "$metadata_path"

{
  printf 'awesoMux terminal color probe\n'
  printf 'label: %s\n' "$LABEL"
  printf 'artifact: %s\n' "$artifact_dir"
  if [[ "$TAKE_SCREENSHOT" -eq 1 ]]; then
    printf 'screenshot target: %s\n\n' "$screenshot_path"
  else
    printf '\n'
  fi

  printf 'normal 0-7:  '
  for color in 0 1 2 3 4 5 6 7; do
    printf '\033[3%sm %s \033[0m' "$color" "$color"
  done
  printf '\n'

  printf 'bright 8-15: '
  for color in 0 1 2 3 4 5 6 7; do
    printf '\033[9%sm %s \033[0m' "$color" "$((color + 8))"
  done
  printf '\n'

  printf 'bold:        '
  for color in 0 1 2 3 4 5 6 7; do
    printf '\033[1;3%sm bold%s \033[0m' "$color" "$color"
  done
  printf '\n'

  printf 'dim/faint:   '
  for color in 0 1 2 3 4 5 6 7; do
    printf '\033[2;3%sm dim%s \033[0m' "$color" "$color"
  done
  printf '\n'

  printf 'truecolor:   '
  printf '\033[38;2;205;214;244m fg mocha text \033[0m'
  printf '\033[48;2;30;30;46;38;2;205;214;244m mocha bg \033[0m'
  printf '\033[48;2;239;241;245;38;2;76;79;105m latte bg \033[0m'
  printf '\033[38;2;203;166;247m mauve \033[0m'
  printf '\033[38;2;250;179;135m peach \033[0m'
  printf '\n\n'

  printf 'metadata: %s\n' "$metadata_path"
  printf 'swatches: %s\n' "$swatches_path"
  if [[ "$TAKE_SCREENSHOT" -eq 1 ]]; then
    printf 'screenshot target: %s\n' "$screenshot_path"
  fi
} | tee "$swatches_path"

if [[ "$TAKE_SCREENSHOT" -eq 1 ]]; then
  if command -v screencapture >/dev/null 2>&1; then
    screencapture -i "$screenshot_path" || true
  else
    printf 'screencapture unavailable; screenshot target remains %s\n' "$screenshot_path"
  fi
fi

if [[ "$RUN_CLAUDE" -eq 1 ]]; then
  if ! command -v claude >/dev/null 2>&1; then
    printf 'claude not found on PATH; artifact_dir=%s\n' "$artifact_dir" >&2
    exit 1
  fi
  if [[ "$TAKE_SCREENSHOT" -eq 1 ]]; then
    printf 'Launching Claude Code without recording its output. Artifacts: %s (screenshot target: %s)\n' "$artifact_dir" "$screenshot_path"
  else
    printf 'Launching Claude Code without recording its output. Artifacts: %s\n' "$artifact_dir"
  fi
  exec claude
fi

printf 'Wrote terminal color diagnostics to %s\n' "$artifact_dir"
