#!/usr/bin/env bash
# Create an isolated awesoMux worktree, initialize its submodules, and start an agent TUI.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./script/new-worktree.sh [--no-launch] [--tui NAME] [branch]

Create a new branch from origin/main in the sibling awesomux-worktrees
folder, initialize its submodules, and launch an agent TUI from the new worktree.

Options:
  --no-launch  Set up the worktree without launching an agent TUI
  --tui NAME   Launch pi, claude, codex, opencode, or grok without prompting
  -h, --help   Show this help

Environment:
  AWESOMUX_WORKTREE_DIR  Override the directory that contains worktrees
  PI_BIN                 Override the Pi executable (default: pi)
  CLAUDE_BIN             Override the Claude Code executable (default: claude)
  CODEX_BIN              Override the Codex executable (default: codex)
  OPENCODE_BIN           Override the OpenCode executable (default: opencode)
  GROK_BIN               Override the Grok executable (default: grok)
EOF
}

LAUNCH_TUI=1
TUI=""
BRANCH=""
while (( $# > 0 )); do
  case "$1" in
    --no-launch)
      LAUNCH_TUI=0
      ;;
    --tui)
      if (( $# < 2 )); then
        echo "error: --tui requires a name" >&2
        exit 2
      fi
      TUI="$2"
      shift
      ;;
    --tui=*)
      TUI="${1#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$BRANCH" ]]; then
        echo "error: provide only one branch name" >&2
        usage >&2
        exit 2
      fi
      BRANCH="$1"
      ;;
  esac
  shift
done

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: run this script from an awesoMux checkout" >&2
  exit 1
}
COMMON_GIT_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir)"
PRIMARY_ROOT="$(dirname "$COMMON_GIT_DIR")"
REPOSITORY_NAME="$(basename "$PRIMARY_ROOT")"

if [[ -z "$BRANCH" ]]; then
  printf 'Branch name (for example, feature/int-768-analytics-core): '
  IFS= read -r BRANCH || {
    echo >&2
    echo "error: no branch name provided" >&2
    exit 1
  }
fi

if [[ -z "$BRANCH" ]] || ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: invalid branch name: ${BRANCH:-<empty>}" >&2
  exit 1
fi

if (( LAUNCH_TUI == 1 )) && [[ -z "$TUI" ]]; then
  cat <<'EOF'
Agent TUI to launch:
  1) Pi
  2) Claude Code
  3) Codex
  4) OpenCode
  5) Grok
EOF
  printf 'Choice [1]: '
  IFS= read -r TUI || {
    echo >&2
    echo "error: no agent TUI selected" >&2
    exit 1
  }
  TUI="${TUI:-1}"
fi

TUI_NAME=""
TUI_BIN=""
if (( LAUNCH_TUI == 1 )); then
  case "$TUI" in
    1|pi|Pi)
      TUI_NAME="Pi"
      TUI_BIN="${PI_BIN:-pi}"
      ;;
    2|claude|Claude|claude-code)
      TUI_NAME="Claude Code"
      TUI_BIN="${CLAUDE_BIN:-claude}"
      ;;
    3|codex|Codex)
      TUI_NAME="Codex"
      TUI_BIN="${CODEX_BIN:-codex}"
      ;;
    4|opencode|OpenCode|open-code)
      TUI_NAME="OpenCode"
      TUI_BIN="${OPENCODE_BIN:-opencode}"
      ;;
    5|grok|Grok)
      TUI_NAME="Grok"
      TUI_BIN="${GROK_BIN:-grok}"
      ;;
    *)
      echo "error: unknown agent TUI: ${TUI:-<empty>}" >&2
      echo "choose pi, claude, codex, opencode, or grok" >&2
      exit 2
      ;;
  esac
fi

WORKTREE_BASE="${AWESOMUX_WORKTREE_DIR:-$(dirname "$PRIMARY_ROOT")/${REPOSITORY_NAME}-worktrees}"
WORKTREE_NAME="${BRANCH//\//-}"
WORKTREE_PATH="$WORKTREE_BASE/$WORKTREE_NAME"

if git -C "$ROOT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "error: local branch already exists: $BRANCH" >&2
  exit 1
fi
if [[ -e "$WORKTREE_PATH" ]]; then
  echo "error: worktree path already exists: $WORKTREE_PATH" >&2
  exit 1
fi

if (( LAUNCH_TUI == 1 )) && ! command -v "$TUI_BIN" >/dev/null 2>&1; then
  echo "error: $TUI_NAME executable not found: $TUI_BIN" >&2
  exit 1
fi

echo "Fetching origin..."
git -C "$ROOT_DIR" fetch origin
mkdir -p "$WORKTREE_BASE"

echo "Creating $WORKTREE_PATH on $BRANCH..."
git -C "$ROOT_DIR" worktree add "$WORKTREE_PATH" -b "$BRANCH" origin/main

echo "Initializing submodules..."
if ! git -C "$WORKTREE_PATH" submodule update --init --recursive; then
  cat >&2 <<EOF
error: submodule initialization failed. The worktree was kept at:
  $WORKTREE_PATH
Retry with:
  git -C "$WORKTREE_PATH" submodule update --init --recursive
EOF
  exit 1
fi

printf '\nWorktree ready: %s\n' "$WORKTREE_PATH"
if (( LAUNCH_TUI == 0 )); then
  printf 'Open it with:\n  cd %q\n' "$WORKTREE_PATH"
  exit 0
fi

echo "Launching $TUI_NAME..."
cd "$WORKTREE_PATH"
exec "$TUI_BIN"
