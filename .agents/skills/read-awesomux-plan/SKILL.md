---
name: read-awesomux-plan
description: Read shared awesoMux planning through authenticated sf when working on issues, product decisions, delivery order, or linked research.
---

# Read shared planning

Use each contributor's authenticated `sf` CLI. A plain HTTP fetch of a private
space can return 403. Keep the space name, URL, ID, and team selection out of
tracked files; configure them locally.

## Local setup

Read `.agents/planning.json` from the repository root. It is gitignored and
contains `spaceId` and `team` strings identifying the shared planning space.
`spaceId` is the exact space ID; `team` accepts a team slug, ID, or display name,
which `sf` resolves. Verify the returned space ID rather than comparing the
team selector with the receipt's canonical slug.
Each contributor supplies their own local configuration and `sf` login; never
put credentials in this file. If configuration is missing, ask for the space
selection while continuing independent repository work. Do not guess a space
or print the user's full space inventory.

## Read the live plan

Commands were exercised with `sf` 0.4.1; consult command help if it differs.
Run these snippets in one shell from the repository root, or preserve variables
between tool calls. Use a fresh directory outside the repository and its real
path: on macOS, downloads reject `/tmp` because it is a symlink. Keep full CLI
receipts private; they can contain access capabilities.

```sh
umask 077
planning_space="$(python3 -c 'import json; print(json.load(open(".agents/planning.json"))["spaceId"])')"
planning_team="$(python3 -c 'import json; print(json.load(open(".agents/planning.json"))["team"])')"
planning_dir="$(python3 -c 'import os,tempfile; print(os.path.realpath(tempfile.mkdtemp(prefix="planning-")))')"
sf spaces get --team "$planning_team" --space "$planning_space" --json \
  > "$planning_dir/space.json"
```

Check success before continuing. Select the live version, which may differ
from the latest upload. Verify the receipt matches the configured space:

```sh
planning_version="$(python3 -c 'import json,sys; c=json.load(open(".agents/planning.json")); d=json.load(open(sys.argv[1]))["data"]; assert d["space"]["id"] == c["spaceId"]; v=d["runtime"]["liveVersionId"]; assert v; print(v)' "$planning_dir/space.json")"
sf spaces download --team "$planning_team" --space "$planning_space" \
  --version "$planning_version" --output "$planning_dir/files" --json \
  > "$planning_dir/download.json"
```

Check download success. Find the issue in `board-data.json`, follow its plan
anchor into `plan.html`, and search by topic. Read relevant included research;
report missing research files and request them only when needed. Record the
retrieved version for time-sensitive claims. The deployed bundle may lag
unpublished source; re-read live metadata if the plan changes mid-task.

Reconcile planning proposals with GitHub, current code, and ADRs; report
conflicts. A milestone is not proof of shipped behavior or extra permission.
Keep private planning content out of public issues and PRs.

If the CLI or authentication is unavailable, report the prerequisite and
continue independent work. Do not read credential files, print access links,
change sharing, publish, or install/update tools just to read the plan.
