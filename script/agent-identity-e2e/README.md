# Unmanaged SSH provider icon QA

Use an isolated development build and a disposable workspace. The fixture
renders provider chrome through an ordinary SSH connection; it does not launch
agents, install hooks, or change remote configuration.

On a Mac with SSH access to itself, run this in the workspace, using the absolute
checkout path:

```sh
ssh -t localhost python3 /absolute/checkout/script/agent-identity-e2e/fixture.py
```

On another SSH host, copy the fixture to a temporary directory you own and run
that path. Keep the same connection open for the sequence below.

| Command | Expected icon |
| --- | --- |
| Initial screen | Claude Code |
| `codex` | Codex |
| `claude` | Claude Code |
| `codex-stale-claude` | Codex despite the retained Claude banner |
| `claude-stale-codex` | Claude Code despite the retained Codex banner |
| `codex`, then `quoted` | Codex remains; quoted example does not switch it |
| `shell` | Existing icon remains without remote process-exit evidence |
| `exit` | Fixture exits; disconnect SSH to restore local shell detection |

Capture screenshots after each provider switch, including the sidebar and
terminal footer. Record the build commit, CLI versions for any real-provider
checks, and whether execution state, attention, or unread counts changed.

Also verify these paths with actual Claude Code and Codex:

- Exit a local hooked agent, SSH from the same pane, and switch remote agents.
  The post-exit state suppression must not block the remote provider icon.
- Scroll into old provider output while switching the current agent. The
  current active-screen footer, rather than scrollback, determines the icon.
- Run local agents and managed SSH sessions with remote process evidence.
  Their existing authoritative detection must retain priority.

The fallback supports specific input/footer layouts. Custom footers, wrapped
input, or changed CLI layouts may retain the previous icon. A program that
renders an identical footer can imitate a provider. Text inference does not
establish a provider session identity or permission to send prompts.
