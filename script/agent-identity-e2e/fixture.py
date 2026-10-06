#!/usr/bin/env python3
"""Render deterministic provider chrome through ordinary SSH for native QA.

Run in an isolated awesoMux workspace:
    ssh -t localhost python3 /absolute/path/to/fixture.py
Enter claude, codex, codex-stale-claude, claude-stale-codex, quoted, shell, or exit.
This fixture does not run providers,
install hooks, or change remote configuration.
"""
import shutil
import sys


def draw(provider):
    columns, rows = shutil.get_terminal_size((80, 24))
    lines = ["Unmanaged SSH agent icon QA fixture"]
    if provider == "codex-stale-claude":
        lines.append("Claude Code v2.1.0")
    elif provider == "claude-stale-codex":
        lines.append("OpenAI Codex (v0.154.0)")
    if provider in {"codex", "codex-stale-claude"}:
        footer = ["› Ask Codex to do anything", "GPT-6-Sol low · /tmp · SSH icon QA", "← for agents · ? for shortcuts"]
    elif provider in {"claude", "claude-stale-codex"}:
        footer = ["─" * min(columns, 60), "❯ ", "─" * min(columns, 60), "  ? for shortcuts"]
    elif provider == "quoted":
        footer = ["```text", "› Ask Codex to do anything", "GPT-6-Sol low · /tmp", "← for agents · ? for shortcuts", "```", "example output only"]
    else:
        footer = ["example@localhost /tmp $ "]
    screen = lines + [""] * max(0, rows - len(lines) - len(footer) - 1) + footer
    sys.stdout.write("\033[2J\033[H" + "\r\n".join(screen))
    sys.stdout.flush()


draw("claude")
for command in sys.stdin:
    command = command.strip()
    if command == "exit":
        break
    if command in {"claude", "codex", "codex-stale-claude", "claude-stale-codex", "quoted", "shell"}:
        draw(command)
