# Status-plugin install contract — Claude Code, Codex & Grok (INT-519)

Command contract the install/uninstall/status runner is built against, for the
awesoMux **status plugin** (the bundled hook that appends agent runtime events to
`AWESOMUX_AGENT_EVENT_FILE`). This is the spec, not code. It covers the CLI
surfaces the runner shells out to:

- **Claude Code** — the `claude plugin …` CLI plus a marketplace catalog.
- **Codex** — the `codex plugin …` CLI plus the Codex hook **trust** flow, keyed
  on `CODEX_HOME`.
- **Grok** — the `grok plugin …` CLI plus local plugin install, keyed on
  `GROK_HOME`.

Scope mirrors [ADR 0010](adr/0010-opencode-pi-opt-in-agent-integrations.md): install
is a **separate, explicit, reversible** user action from enabling the provider, and
both are global-only. The runner never edits provider files by hand where a CLI
exists; it shells the documented commands and parses their structured output.

Status vocabulary the runner reports per provider:

| Status | Meaning | Operator action |
| --- | --- | --- |
| **Needs review** | Provider has the plugin/hook on disk but it is awaiting an explicit trust/approval step before it will run. | Approve/trust it. |
| **Needs repair** | Manifest/config claims it is installed but the on-disk reality disagrees (missing, modified, hash/trust mismatch, CLI error entry). | Re-install / re-render. |
| **Unsupported** | This CLI/version/policy cannot host the plugin at all. | Surface path for manual handling; do not auto-write. |

> **Repo gap to close before the runner ships (Claude side).** The bundled
> `Resources/AgentIntegrations/claude_code/plugins/awesomux-claude-status/` ships only
> `hooks/hooks.json`. The Claude plugin CLI requires a marketplace catalog
> (`marketplace.json`) and a plugin manifest (`.claude-plugin/plugin.json`) to install
> by name. The runner either (a) renders a local single-plugin marketplace + manifest
> at install time, or (b) we add them to the bundle. The contract below assumes a
> local marketplace named `awesomux` containing plugin `awesomux-claude-status`.

---

## 1. Claude Code — `claude plugin` CLI

Docs: code.claude.com/docs/en — `plugins-reference`, `plugin-marketplaces`,
`discover-plugins`, `settings`, `plugin-dependencies` (Context7 `/websites/code_claude`).

### 1.1 Layout the CLI expects

```text
awesomux/                         ← marketplace root (we render/own this)
├── .claude-plugin/
│   └── marketplace.json          ← catalog: lists awesomux-claude-status
└── plugins/
    └── awesomux-claude-status/
        ├── .claude-plugin/
        │   └── plugin.json        ← manifest; "hooks": "./hooks/hooks.json"
        ├── hooks/
        │   └── hooks.json         ← already in the bundle
        └── skills/
            └── awesomux-documents/
                └── SKILL.md       ← document/annotation convention (ADR-0012 addendum, INT-684)
```

`marketplace.json` minimum: `{ "name": "awesomux", "owner": {...}, "plugins": [ { "name":
"awesomux-claude-status", "source": "./plugins/awesomux-claude-status", "description": "…" } ] }`.
`plugin.json` minimum: `{ "name": "awesomux-claude-status", "version": "x.y.z", "hooks":
"./hooks/hooks.json" }`. Components (the `hooks/` dir) live at plugin **root**, only the
manifest sits in `.claude-plugin/`. (Source: `plugins-reference`, `plugin-marketplaces`.)

### 1.2 Command contract

Plugin ref is always `awesomux-claude-status@awesomux`. Default scope is `user`; the
runner pins `--scope user` explicitly (global-only install per ADR 0010).

| Op | Command | Required env | Notes |
| --- | --- | --- | --- |
| Register catalog | `claude plugin marketplace add <marketplace-root-or-marketplace.json>` | `PATH` to `claude` | Idempotent-ish; adding an already-known marketplace is not a hard failure but re-validates. Local path or path to the `marketplace.json` both accepted. |
| Validate catalog | `claude plugin validate <marketplace-root>` | — | Pre-flight: checks schema, duplicate names, source path traversal, version mismatch. Run before `add` to convert a malformed render into a clean failure. |
| Install | `claude plugin install awesomux-claude-status@awesomux --scope user` | `PATH` | Writes `enabledPlugins["awesomux-claude-status@awesomux"] = true` into the scope's `settings.json`. |
| Uninstall | `claude plugin uninstall awesomux-claude-status@awesomux --scope user` | `PATH` | Removes from `enabledPlugins`. |
| Disable (keep installed) | `claude plugin disable awesomux-claude-status@awesomux` | `PATH` | Fails if an enabled plugin depends on it (we have none). |
| Enable | `claude plugin enable awesomux-claude-status@awesomux` | `PATH` | |
| De-register catalog | `claude plugin marketplace remove awesomux --scope user` | `PATH` | Full uninstall = uninstall plugin, then remove marketplace. |
| **Status (authoritative)** | `claude plugin list --json` | `PATH` | Machine-readable. Parse per §1.3. |

### 1.3 Parsing success vs failure

**Process level.** `claude` is a Node CLI: exit `0` = success, non-zero = failure;
stderr carries the message. Treat "command not found"/ENOENT spawning `claude` as
**Unsupported** (CLI absent). Treat a non-zero exit **with** parseable stderr from a
present binary as a hard failure of that op (surface stderr verbatim).

**Status level — drive off `claude plugin list --json`.** Each plugin entry carries at
least `name`, `version`, a marketplace/source, an enabled flag, and an `errors` array
(documented for dependency/load errors; treat as the general per-plugin error channel).
Decision table for our entry (`awesomux-claude-status@awesomux`):

| Observed | Status |
| --- | --- |
| `claude` binary missing, or `--json` unsupported on this version (no JSON on stdout) | **Unsupported** |
| Entry present, enabled true, `errors` empty | Installed-OK (no action) |
| Marketplace known but our plugin entry absent, **and** `enabledPlugins` in `settings.json` still references it | **Needs repair** (re-install) |
| Entry present but `errors` non-empty (manifest/hooks path bad, plugin failed to load), or `claude plugin validate` fails on our rendered catalog | **Needs repair** |
| Marketplace not yet added / plugin never installed | Not-installed (offer install) |

**Trust / review.** Adding a marketplace and installing from it is the consent gate; in
non-interactive runner use, a marketplace that has been `add`ed and a plugin that
`list --json` shows enabled with no `errors` is considered trusted. If a future CLI
version reports a pending-trust state for the marketplace in `list --json`, map that to
**Needs review**. (Claude has no per-hook trust hash the way Codex does; trust is at the
marketplace/plugin grain.)

**Reload semantics.** Install/enable/disable do not retroactively apply to a running
Claude session. In-session pickup is `/reload-plugins` (slash command; may warn on
MCP-bearing plugins — ours has none, so no `--force` needed). The runner cannot invoke a
slash command in someone else's session, so it shows `/reload-plugins` or restart advice as
post-action guidance rather than a steady status. (Source: `discover-plugins`.)

**Where state lands.** `--scope user` → `~/.claude/settings.json`; `--scope project` →
`.claude/settings.json`; `--scope local` → gitignored local settings. Keys:
`enabledPlugins` (`"name@marketplace": bool`) and `extraKnownMarketplaces`. The runner
treats `claude plugin list --json` as the source of truth and these files as
human-editable inputs, not as the parse target. (Source: `settings`, `plugin-marketplaces`.)

---

## 2. Codex — `codex plugin` CLI + hook trust flow

Docs: `github.com/openai/codex` — `docs/config.md`, `codex-rs/app-server/README.md`,
`codex-rs/config/src/hook_config.rs`, `codex-rs/hooks/src/engine/discovery.rs`,
`codex-rs/cli/src/marketplace_cmd.rs`, `codex-rs/utils/home-dir` (Context7 `/openai/codex`).

Codex has a `Plugin` subcommand (`PluginCli`) **and** a first-class hook **trust** model.
A Codex plugin bundles hooks; the hooks still pass through trust before they run. This is
the structural difference from Claude: install ≠ runnable until **trusted**.

### 2.1 `CODEX_HOME` — the anchor for everything

`CODEX_HOME` resolves the config dir; **unset/empty → `~/.codex`** (`find_codex_home()`).
Config lives at `$CODEX_HOME/config.toml`; plugins under `$CODEX_HOME` per the CLI. The
runner **must** pass the same `CODEX_HOME` to every `codex` invocation and status read it
intends to affect — a mismatched/missing `CODEX_HOME` silently targets `~/.codex` and the
status read will not see installs done under a different home. Validate that the resolved
home is an existing directory before acting; treat a configured-but-missing home as
**Needs repair** (nothing installed there) rather than erroring.

### 2.2 Command contract

| Op | Command | Required env | Notes |
| --- | --- | --- | --- |
| Register marketplace | `codex plugin marketplace add <path-or-owner/repo>` | `CODEX_HOME` | Local path (marketplace root) or `owner/repo`. Name derived automatically. |
| Install plugin | `codex plugin add awesomux-codex-status@<marketplace>` | `CODEX_HOME` | Adds the plugin (and its hooks) to config. |
| List | `codex plugin list` | `CODEX_HOME` | Which plugins/marketplaces are configured. Parse text unless a `--json` is available on the version in use; prefer the app-server RPC (§2.4) for structured status. |
| Health | `codex doctor` | `CODEX_HOME` | Diagnoses install/config/runtime; use to detect **Unsupported** (no plugin/hook support) and broken config. |
| Enable/disable hook | config write to `[state."<key>"] enabled` (via `config/batchWrite` RPC, §2.4) | `CODEX_HOME` | User-controlled state lives under `hooks.state` in `config.toml`. |
| Remove | `codex plugin` remove/uninstall subcommand (PluginCli) + `codex plugin marketplace remove` | `CODEX_HOME` | Mirror of install. |

Plugins surface their hooks via the manifest `hooks` field (`PluginHookSource`, loaded with
a `plugin_id`). Alternatively hooks can be declared directly in `config.toml` as event
tables (`[[SessionStart]]`, `[[PreToolUse]]`, … each with `[[Event.hooks]] type="command"
command="…" timeout=…`). Our bundle currently ships `hooks/hooks.json`; for Codex it must
be reachable as either a plugin manifest `hooks` target or merged into `config.toml`.

Per the ADR-0012 addendum (INT-684), the rendered Codex plugin also carries the
document/annotation-convention skill: the rendered `plugin.json` gains
`"skills": "./skills/"` and the rendered plugin directory ships
`skills/awesomux-documents/SKILL.md` alongside `hooks/hooks.json`. Skills do not
pass through the hook trust model (§2.3) — an installed skill is usable without a
trust step — so skill presence never affects the `Needs review` mapping in §2.5.

### 2.3 The trust model (this is where "Needs review" comes from)

For **unmanaged** hooks Codex computes a SHA-256 over the normalized hook identity
(event name + matcher + handler config) → `sha256:<hex>` (`command_hook_hash`). Per-hook
state is stored in `config.toml`:

```toml
[state."<sourcePath>:<event>:<groupIdx>:<hookIdx>"]
enabled = true
trusted_hash = "sha256:abc123"
```

A hook is **runnable only if it is enabled AND managed or trusted**. For unmanaged hooks,
trusted means the current computed hash equals the stored `trusted_hash`. `trustStatus` is
one of: managed, untrusted (never approved), trusted (hash matches), or modified (hash
differs from the approved one). Older Codex builds used `first-seen` and `changed`; the
runner normalizes those to untrusted and modified. (Source: `app-server/README.md` Hooks
section; `discovery.rs`.)

**Managed** hooks (`isManaged: true`, from requirements/managed config) are non-configurable
and always run; user `state` entries for their keys are ignored. If
`allow_managed_hooks_only = true` is set in `requirements.toml`, user/project/session hooks
(ours) are **ignored entirely** → **Unsupported** in that environment. (Source:
`docs/config.md` Lifecycle hooks.)

### 2.4 Authoritative status read — `hooks/list` RPC

The structured status source is the app-server `hooks/list` RPC (over `codex app-server` /
`codex mcp-server` stdio), which returns hooks nested under a per-working-directory
`data[]` wrapper. Each `data` entry carries its own `warnings`/`errors` (environmental
issues for that cwd, not properties of any one hook); the hook objects themselves omit
those fields:

```jsonc
{
  "result": {
    "data": [{
      "cwd": "/path/to/project",
      "hooks": [{
        "key": "<sourcePath>:<event>:<idx>:<idx>",
        "eventName": "session_start",
        "isManaged": false,
        "pluginId": "awesomux-codex-status@<marketplace>" | null,
        "enabled": true,
        "currentHash": "sha256:…",
        "trustStatus": "managed" | "untrusted" | "trusted" | "modified",
        "sourcePath": "<CODEX_HOME>/config.toml",
        "source": "user" | "plugin" | "managed"
      }],
      "warnings": [],
      "errors": []
    }]
  }
}
```

To **set** enabled state non-interactively, use `config/batchWrite` with key path
`hooks.state` and `mergeStrategy: "upsert"` (and `reloadUserConfig: true`).

### 2.5 Status mapping (Codex)

Match our hook(s) by `pluginId == awesomux-codex-status@<marketplace>` (or by
`command` containing `awesoMuxAgentHook --provider codex` when matching config.toml hooks).

| Observed | Status |
| --- | --- |
| `codex` binary missing; or `codex doctor` reports no hook/plugin support; or `allow_managed_hooks_only = true` (our user hook ignored) | **Unsupported** |
| Our hook present, `enabled: true`, `trustStatus: untrusted` | **Needs review** (user must approve) |
| Our hook present, `enabled: true`, `trustStatus: modified` (current hash ≠ `trusted_hash`) | **Needs review** if the change is the user's; **Needs repair** if our rendered content drifted from what's on disk (we own the file → re-render/re-install) |
| Our hook present, `enabled: true`, `trustStatus: trusted`, hashes match | Installed-OK |
| `pluginId` configured but no matching hook discovered, or `sourcePath`/manifest missing, or `errors` non-empty | **Needs repair** |
| `enabled: false` (user disabled) | Not-active (respect user; offer enable, don't auto-flip) |

**Reload semantics (Codex).** Config/trust changes apply on the next thread/session; a live
thread won't retroactively load a newly trusted hook. `config/batchWrite` with
`reloadUserConfig: true` reloads config for the app-server, but an already-running
interactive session still needs a fresh thread, so the runner shows that as post-action
guidance rather than a steady status.

---

## 3. Grok — `grok plugin` CLI

Grok supports a native plugin tree with `.grok-plugin/plugin.json`, hook config
under the plugin root, and CLI-managed installation under `GROK_HOME`.

### 3.1 Layout the CLI expects

```text
awesomux/
├── .grok-plugin/
│   └── marketplace.json
└── plugins/
    └── awesomux-grok-status/
        ├── .grok-plugin/
        │   └── plugin.json
        └── hooks/
            └── hooks.json
```

The plugin manifest names `hooks/hooks.json`. Current Grok hook event names are
Claude-style CamelCase (`SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PermissionDenied`, and so on); the hook commands invoke
`awesoMuxAgentHook --provider grok`.

### 3.2 Command contract

`GROK_HOME` resolves the config dir; unset defaults to `~/.grok`. The runner
passes the configured home to every Grok invocation so install and status target
the same store.

| Op | Command | Required env | Notes |
| --- | --- | --- | --- |
| Validate | `grok plugin validate <plugin-dir>` | `GROK_HOME`, `PATH` | Run before install to catch malformed local plugin content. |
| Install | `grok plugin install <plugin-dir> --trust` | `GROK_HOME`, `PATH` | Installs and trusts the local plugin. |
| Status | `grok plugin list --json` | `GROK_HOME`, `PATH` | Structured status source. |
| Disable | `grok plugin disable awesomux-grok-status` | `GROK_HOME`, `PATH` | Keeps the plugin installed. |
| Uninstall | `grok plugin uninstall awesomux-grok-status --confirm` | `GROK_HOME`, `PATH` | Removes the plugin without an interactive prompt. |

### 3.3 Status mapping

Decision table for `awesomux-grok-status`:

| Observed | Status |
| --- | --- |
| `grok` binary missing, times out, or `plugin list --json` is unsupported | **Unsupported** |
| Configured `GROK_HOME` path is missing | **Needs repair** |
| Plugin absent and no install record exists | Not-installed |
| Plugin absent but awesoMux has an install record | **Needs repair** |
| Entry status reports `disabled` | Not-active |
| Entry status reports an error/failure state | **Needs repair** |
| Entry present with normal installed/enabled status | Installed-OK |

Current Grok versions expose `plugin disable`, but `plugin list --json` may still
report disabled plugins as `"status": "installed"`. The runner is prepared for a
future disabled status, but treats current installed entries as enabled because
that JSON is the only non-interactive status source.

---

## 4. Cross-cutting runner rules

- **Always pass env explicitly.** Codex: `CODEX_HOME` on every call. Grok:
  `GROK_HOME` on every call. Claude: ensure `claude` is resolved on `PATH` (or
  an absolute path); honor `AWESOMUX_AGENT_HOOK` only inside the rendered
  `hooks.json`, not as a runner env.
- **Prefer structured reads.** `claude plugin list --json`, Codex `hooks/list`,
  and `grok plugin list --json` are the parse targets. Treat human-editable
  files (`settings.json`, `config.toml`) as inputs the user may have changed,
  not as the status source of truth.
- **Consent stays explicit (ADR 0010).** Having a binary path / config home is metadata
  only. The runner does not `add`/`install`/trust without the user's install action, and
  does not flip a user-disabled plugin back on.
- **Modified-file safety (existing installer invariant).** Uninstall/repair only removes
  awesoMux-owned files whose content still matches the rendered template; a modified file is
  surfaced for manual cleanup, never silently overwritten. The Codex trust-hash drift case
  in §2.5 is the provider-native analogue of this same rule.
- **Failure surfacing.** Distinguish *CLI-absent* (Unsupported) from *CLI-present-but-errored*
  (op failure; surface stderr) from *state-disagreement* (Needs repair). Never collapse all
  three into one error.

## 5. Open questions for the runner PR

1. Render the Claude `marketplace.json` + `plugin.json` at install time, or commit them to
   the bundle? (Rendering keeps a single source of truth with the OpenCode/Pi templates.)
2. Codex hooks via plugin manifest vs. direct `config.toml` event tables — which does the
   installer write? Plugin manifest keeps it symmetrical with Claude and carries a
   `pluginId` for clean status matching.
3. Codex `hooks/list` requires spawning the app-server; confirm the minimum Codex version
   that ships `hooks/list` + `config/batchWrite`, and the fallback when only the text
   `codex plugin list` exists (likely: degrade structured status to coarse present/absent).
4. Live reload detection is deferred. Current runner work uses post-action guidance for
   Claude reload and Codex fresh-thread advice.
5. Runtime verification for the instruction-injection skill (ADR-0012 addendum, INT-684):
   confirm the minimum Codex version whose plugin loader honors the `plugin.json`
   `skills` manifest field; confirm OpenCode's `permission.skill` defaults let the
   dropped `~/.config/opencode/skills/awesomux-documents/SKILL.md` load without extra
   config; confirm Pi loads `~/.pi/agent/skills/awesomux-documents/SKILL.md` with no
   trust prompt (project-local skill paths do prompt; the global agent dir should not).
