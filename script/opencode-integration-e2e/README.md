# OpenCode integration verification

These checks use disposable configuration and data homes. They never install
into the user's OpenCode configuration or use provider credentials.

```sh
node --experimental-vm-modules script/opencode-integration-e2e/plugin-contract.mjs
python3 script/opencode-integration-e2e/run-installer.py
python3 script/opencode-integration-e2e/live-runtime.py
python3 script/opencode-integration-e2e/live-runtime.py --part-rows
# Optional: select an isolated V1 1.18.29 binary.
python3 script/opencode-integration-e2e/live-v1.py --opencode /path/to/opencode-v1
```

The contract check evaluates the shipped TUI source with controlled client
state and a recording subprocess boundary. It covers root/child routing,
permissions and forms, errors, switching, disposal, payload privacy, absent
awesoMux environment, and missing/hung helpers. This is a protocol fixture,
not proof of real OpenCode behavior.

The installer check compiles the production installer, manifest store, lock,
and config types. It checks installation, current/stale status, Repair,
legacy migration, changed-file protection, config-home moves, rollback after
manifest failure, uninstall, and Pi isolation. Its runtime-profile defaults
are fixture stubs; every tested call supplies explicit temporary directories.
It prints the location of `installer.log`.

The live runtime check requires a locally installed OpenCode 2 CLI and a Unix
PTY host. It launches its own authenticated loopback server and two real TUI
clients with distinct awesoMux helper sinks. The server has no pane environment.
It checks discovery, initial identity/state, child permission and question
resolution, root/child execution failure, clients outside awesoMux, graceful
exit, and isolation between clients. A local HTTP model fixture holds its
response until running is observed, then returns a successful SSE response.
No request goes to an external model provider. `--part-rows` checks the V2
experimental split-part writer; the default checks inline assistant content. It writes `report.json`,
plugin discovery, and process logs to its printed evidence directory. Only
owned subprocess groups are terminated and reaped. Use `--opencode PATH` to
select a binary and `--output DIRECTORY` to select evidence storage.

The optional V1 check launches an isolated V1 1.18.29 server and verifies that
the top-level discovery entry emits exactly one `SessionStart`. It records
template hashes and helper receipts in `report.json`, then stops its server.

The production transcript reader can be checked against either live fixture's
retained database, using that fixture's session ID from `pane-0.jsonl`:

```sh
python3 script/opencode-integration-e2e/run-transcript.py \
  --data-home /path/to/live-fixture/data/opencode \
  --session ses_fixture_id --expect-text 'fixture success'
```

This compiles the real reader, snapshot, and SecureFileIO sources with a small
importer-error enum shim, verifies expected text without dumping the transcript,
and records source hashes and row counts in its own `report.json`.

Existing `OpenCodeTranscriptDatabaseTests` exercise both V1 and V2 schema reads,
ordering, session isolation, and source/turn/part limits. Existing
`AgentIntegrationTemplateTests` retain the V1 root-routing and payload checks.
Run them through the repository's normal Swift test wrapper.

These checks do not prove the native awesoMux sidebar, notification delivery,
Settings interactions, signed app packaging, SSH execution, a production provider
request, or a physical device. A native check still needs an app built from
this source, integration enabled and repaired in Settings, and two terminal
panes running OpenCode through a successful turn and a permission prompt.

OpenCode 2 terminal status comes from its TUI part. Desktop and headless
`opencode run` do not load that part. OpenCode Resume, live transcript refresh,
and nonstandard database paths remain unsupported. The V1 discovery bridge
targets V1 1.18.29 and newer; older V1 loaders are not supported.
