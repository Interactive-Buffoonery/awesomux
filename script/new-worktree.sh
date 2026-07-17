#!/usr/bin/env bash
# Create an isolated awesoMux worktree, initialize its submodules, and start Pi.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./script/new-worktree.sh [--no-launch] [branch]

Create a new branch from origin/main in the sibling awesomux-worktrees
folder, initialize its submodules, and launch Pi from the new worktree.

Options:
  --no-launch  Set up the worktree without launching Pi
  -h, --help   Show this help

Environment:
  AWESOMUX_WORKTREE_DIR  Override the directory that contains worktrees
  PI_BIN                 Override the Pi executable (default: pi)
EOF
}

LAUNCH_PI=1
BRANCH=""
while (( $# > 0 )); do
  case "$1" in
    --no-launch)
      LAUNCH_PI=0
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

PI_BIN="${PI_BIN:-pi}"
if (( LAUNCH_PI == 1 )) && ! command -v "$PI_BIN" >/dev/null 2>&1; then
  echo "error: Pi executable not found: $PI_BIN" >&2
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
if (( LAUNCH_PI == 0 )); then
  printf 'Open it with:\n  cd %q && pi\n' "$WORKTREE_PATH"
  exit 0
fi

echo "Launching Pi..."
cd "$WORKTREE_PATH"
exec "$PI_BIN"
