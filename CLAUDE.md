@AGENTS.md

# Claude-specific notes

The shared project instructions live in [`AGENTS.md`](AGENTS.md). Read the
architecture and integration documents linked there before making changes.

For UI work, follow the existing SwiftUI/AppKit patterns and the tokens under
[`Sources/DesignSystem/`](Sources/DesignSystem/).

## Git etiquette

- `main` is protected. Use a feature branch and pull request.
- Use Conventional Commits as described in [`AGENTS.md`](AGENTS.md#code-style).
- Use GitHub Issues and pull requests for public planning, handoffs, and review.
- Keep one implementation owner on a branch at a time.

## Pre-merge review gate

The repository's pre-merge review hook applies here. Skip it only for non-code
commits and state the reason in the pull request.
