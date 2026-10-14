# amx reaper safety E2E report

Date: 2026-10-14

Surface: `script/amx-reap.sh` invoked through `script/amx-reap-e2e.sh` with a
fake `amx` executable, an isolated temporary `HOME`, and the production profile
selected explicitly. No real daemon, socket directory, or application data was
read or changed.

Run the fixture from the repository root:

```sh
script/amx-reap-e2e.sh
```

## Before

Baseline: `c96d09c21104e0079366877e1b1f9f079aadfcf0`

The initial fixture run failed with nine assertions. The failure-bearing output
was:

```text
FAIL escaped-owned: missing output: reaped 0 orphan daemon(s)
FAIL escaped-owned: expected kills '', got 'abc-def'
CASE escaped-owned status=0 kills=abc-def
  | reaping orphan abc-def
  | reaped 1 orphan daemon(s); left owned daemons untouched.
FAIL malformed-state: expected nonzero status, got 0
FAIL malformed-state: missing output: could not read owned session ids
FAIL malformed-state: expected kills '', got 'owned-1'
CASE malformed-state status=0 kills=owned-1
  | reaping orphan owned-1
  | reaped 1 orphan daemon(s); left owned daemons untouched.
FAIL list-failure: expected nonzero status, got 0
FAIL list-failure: missing output: could not list live amx sessions
CASE list-failure status=0 kills=none
  | reaped 0 orphan daemon(s); left owned daemons untouched.
FAIL kill-failure: expected nonzero status, got 0
FAIL kill-failure: missing output: reaped 0 orphan daemon(s); 1 failed.
CASE kill-failure status=0 kills=orphan-1
  | reaping orphan orphan-1
  | reaped 1 orphan daemon(s); left owned daemons untouched.
RESULT FAIL failures=9
```

The decoded value of `"abc\u002ddef"` is `abc-def`, which satisfies
`TerminalSessionID.isValid`. The escaped-ID case was therefore a real ownership
error rather than an impossible session name.

## After

The final fixture run passed all ten scenarios:

```text
CASE escaped-owned status=0 kills=none
CASE valid-mixed status=0 kills=orphan-1
CASE malformed-state status=1 kills=none
CASE state-unreadable status=1 kills=none
CASE state-directory status=1 kills=none
CASE state-fifo status=1 kills=none
CASE state-dangling-link status=1 kills=none
CASE list-failure status=1 kills=none
CASE kill-failure status=1 kills=orphan-1
CASE all-kill-failure status=1 kills=orphan-1
RESULT PASS
```

The valid mixed-state case killed only the orphan. Ownership failures and live
inventory failures issued no kill. Failed orphan and all-mode kills were
attempted, counted as failures rather than successes, and returned status 1.
