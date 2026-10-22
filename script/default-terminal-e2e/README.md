# Default terminal integration harness

This standalone macOS harness checks terminal-file validation and quoting,
default-application success and failure handling, and the document types in the
staged-app build script.

Run it from the repository root:

```sh
./script/default-terminal-e2e/run.sh
```

To retain evidence at a chosen location:

```sh
./script/default-terminal-e2e/run.sh --output /private/tmp/default-terminal-e2e
```

The explicit output path must not already exist, so a failed new run cannot be
mistaken for an older successful report.

A successful output directory contains `report.txt`, the complete `run.log`, the
compiled driver, and `source-receipt.txt`. The receipt records the checkout HEAD,
a SHA-256 of `git diff --binary --no-ext-diff --no-textconv HEAD`, and SHA-256
hashes for the driver, production source, shared process support, runner, and
inspected build script. It checks HEAD and the dirty-diff hash again after the
run and rejects evidence if either changed. A failed build or run keeps the
evidence produced before the failure and exits nonzero.

The registration checks use closures backed by in-process dictionaries. They do
not call Launch Services, write the operating system's default-app settings, or
execute the fixture files. The bundle check only reads the Info.plist template
embedded in `script/build_and_run.sh`.

The default shell round trips cover `/bin/sh`, `/bin/bash`, and `/bin/zsh`. Fish
is opt-in because it is not installed by macOS:

```sh
AWESOMUX_E2E_FISH=/path/to/fish ./script/default-terminal-e2e/run.sh
```

Child output is redirected to temporary files and each direct child gets the
shared 30-second process deadline. This prevents pipe-capacity and inherited-EOF
hangs. It does not kill a child when Foundation fails to report termination,
because the recorded PID may already have been reused; on timeout, the error
reports the preserved partial-output directory for diagnosis. The deadline is a
guard against indefinite hangs, not a performance assertion.
