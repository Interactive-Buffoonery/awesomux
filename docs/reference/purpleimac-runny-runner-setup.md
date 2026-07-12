# Sarah's iMac Runny runner setup

**Status:** In progress
**Started:** 2026-07-11
**Host alias:** `purpleimac`
**Host account:** `github-runner`
**Controller repository:** `Interactive-Buffoonery/runner-control` (private)

This is the operational record for a one-slot, disposable macOS GitHub Actions
runner hosted on Sarah's M1 iMac. The runner is reusable across explicitly
allowlisted source repositories; it is not attached directly to awesoMux or any
other public repository.

The approval-agent architecture and gate proposal remain in
[`awesomux-pr-approval-agent-gate-proposal.md`](awesomux-pr-approval-agent-gate-proposal.md).
Earlier VM-tool research is retained in
[`apple-silicon-disposable-runner-vm-research.md`](apple-silicon-disposable-runner-vm-research.md),
but its Tart/Tartelet recommendation is superseded by the Runny decision in
this runbook.

## Public-document hygiene

awesoMux is public. This record intentionally omits LAN and Tailscale
addresses, SSH host-key fingerprints, public keys, GitHub App identifiers,
registration tokens, and credentials. Current connection details belong in
Sarah's private SSH configuration and the `network-hosts` skill.

Never paste the GitHub App private key into a terminal transcript, issue, pull
request, workflow, or this document. Transfer the `.pem` as a file and keep it
readable only by `github-runner`.

## Final architecture

```text
Sarah or Ed authorizes an exact source-repository commit SHA
        |
        v
private Interactive-Buffoonery/runner-control workflow
        |
        | targets only the Runny labels
        v
Runny.app in the dedicated github-runner macOS account
        |
        | pull verified OCI image, clone, boot, provision
        v
fresh macOS VM + one-use JIT GitHub Actions runner
        |
        | checkout allowlisted repository at the validated exact SHA
        | run the selected test tier without privileged credentials
        v
collect result and logs, destroy VM, recycle slot
```

- **Runny.app v1.1.0** is the selected VM and runner controller. It uses
  Apple's Virtualization framework directly and consumes Tart-compatible OCI
  images without requiring Tart at runtime.
- The desktop app runs as `github-runner` and manages a per-user LaunchAgent.
- The pilot has one slot: 4 virtual CPUs and 8 GiB guest memory.
- Runny registers runners only with the private `runner-control` repository.
- `runner-control` is the trusted control plane for multiple allowlisted source
  repositories. Tested repositories do not supply the controller workflow.
- Every request names a full commit SHA. The workflow validates both the source
  repository and SHA before checkout.
- Every job gets a fresh VM and a single-use JIT runner configuration. Runny
  destroys the VM after success, failure, cancellation, or timeout.
- The guest receives no Synthetic, Linear, signing, notarization, personal
  GitHub, SSH, or GitHub-write credential.

## Verified host and account state

Read-only inspection and smoke testing on 2026-07-11 recorded:

| Item             | Verified state                                           |
| ---------------- | -------------------------------------------------------- |
| Machine          | Apple iMac (`iMac21,1`), Apple M1                        |
| CPU and memory   | 8 host cores, 16 GB unified memory                       |
| Host OS          | macOS 26.5.2                                             |
| Internal storage | 1 TB APFS SSD                                            |
| Host Xcode       | Xcode 26.6                                               |
| Host Zig         | 0.15.2                                                   |
| Runner account   | Standard non-admin `github-runner` account               |
| Remote access    | SSH verified over both LAN and Tailscale aliases         |
| Runny            | Runny.app v1.1.0 installed and opened as `github-runner` |
| Controller repo  | Private `Interactive-Buffoonery/runner-control` created  |

The account has no iCloud login, personal files, private SSH keys, signing
identities, package-registry credentials, Synthetic credentials, Linear
credentials, or persistent awesoMux checkout. Sarah's and Ed's public
administration keys may be separate lines in
`/Users/github-runner/.ssh/authorized_keys`; their private keys never belong on
the iMac.

The account can remain logged in behind Fast User Switching while Sarah uses
her normal account. After a reboot or FileVault unlock, someone may need to log
into `github-runner` before its user LaunchAgent can run. The Mac must remain
awake while accepting jobs, though the display may sleep.

## Historical Tart validation

Tart and Softnet were removed after Runny was selected. They are not production
dependencies. The completed Tart tests remain useful evidence about the host:

- a Tahoe guest booted with 4 vCPUs, 8 GiB memory, and a 100 GB virtual disk;
- SSH into the guest worked;
- no host-directory mount was present;
- a two-clone sentinel test proved job-written guest data did not survive into
  a fresh clone;
- host free-memory pressure recovered after VM shutdown.

The old Tart image library was moved to the `github-runner` Trash. Empty that
account's Trash in Finder before Runny downloads its production image; the
directory is approximately 100 GB and the installed `trash` CLI did not
recognize it as an item it could empty on this macOS version.

## Runny configuration target

Runny's desktop home is `/Users/github-runner/.runny/`. The GitHub App key and
`config.yaml` will live there with owner-only access. The proposed first-pilot
configuration is:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/bojanrajkovic/runny/main/tools/configschema/config.schema.json
pools:
  - name: purpleimac
    os: darwin
    image: ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:a914e5b3fc1197d61832009778a77ca30717314fd32702cfdf90a42f2c279ea3
    count: 1
    target:
      owner: Interactive-Buffoonery
      repo: runner-control
    github:
      app_id: GITHUB_APP_ID
      private_key_path: /Users/github-runner/.runny/runner-control.pem
    labels:
      - self-hosted
      - macOS
      - ARM64
      - runny
      - purpleimac
    ssh_user: admin
    ssh_password: admin
    ssh_hardening: rotate
    cpu_cores: 4
    ram_gb: 8

limits:
  max_job_duration: 2h
  max_idle: 30m
  max_debug_hold: 15m

retention:
  cycles_per_slot: 20
  max_age: 168h
```

`GITHUB_APP_ID` is a placeholder, not a secret. The image is pinned to an exact
OCI manifest digest rather than a movable tag. Runny verifies the manifest and
blob hashes while populating its own image cache under `~/.runny/images`.

`ssh_hardening: rotate` installs an in-memory per-cycle key, disables SSH
password authentication, and pins the guest host key. The stronger `scramble`
mode was attempted first, but the pinned Tahoe image's SecureToken-backed
`admin` account rejects root password changes through `dscl` with
`eDSAuthFailed`. Runny's default `rotate` mode preserves the important remote
access controls while leaving the image password unchanged for console access.

The labels and repository target are intentionally product-neutral. A future
second Mac gets its own host label and credentials but can register with the
same private controller repository. GitHub can then schedule a general job on
either host or a diagnostic job on one named host.

## GitHub App

Create one GitHub App for Runny's runner-registration lifecycle:

1. In the `Interactive-Buffoonery` organization, open **Settings → Developer
   settings → GitHub Apps → New GitHub App**.
2. Use the unique name **CodeRunner Runner** and set the homepage to the
   private `runner-control` repository.
3. Disable **Webhook → Active**. Runny polls GitHub and needs no webhook.
4. Grant only repository **Administration: Read and write**. GitHub describes
   this as the self-hosted-runner administration capability for a
   repository-scoped installation.
5. Create the App and generate one private `.pem` key.
6. Install the App on **Only select repositories**, selecting only
   `runner-control`.
7. Record the App ID and the local path of the downloaded `.pem`. Do not paste
   the key contents anywhere.

This App registers disposable runners; it does not need source-repository
contents access. Public source repositories can be cloned without another
credential. If a private repository is added later, give checkout a separate,
narrowly scoped read identity rather than widening this App.

## Bring-up sequence

After the App exists:

1. Transfer its `.pem` directly into
   `/Users/github-runner/.runny/runner-control.pem` and set mode `0600`.
2. Replace `GITHUB_APP_ID` in the proposed configuration and install
   `/Users/github-runner/.runny/config.yaml` with mode `0600`.
3. In Runny.app, enable **Settings → Daemon → Start runnyd at login**.
4. Accept the one-time Local Network prompt when the first guest boots.
5. Verify the installation from the `github-runner` account:

   ```sh
   runnyctl doctor
   runnyctl status
   ```

6. Wait for the pinned image download and for the `purpleimac` slot to reach
   `LISTENING`. Diagnose a failed cycle with:

   ```sh
   runnyctl why <slot>
   ```

7. Confirm that the disposable runner appears online only under
   `runner-control` repository settings.

GitHub returns an empty Actions-runner download list for a new repository until
at least one workflow has completed. `runner-control` was initialized with a
README and a manual-only, zero-permission, GitHub-hosted bootstrap workflow.
After that workflow completed once, GitHub exposed the official `osx/arm64`
runner archive and Runny could enter `ENSURE_IMAGE`. This bootstrap workflow
does not target Runny or implement any gate logic.

Do not put the GitHub App key or controller-repository write credentials inside
the guest. Runny mints the short-lived JIT registration material after SSH
hardening and sends only that material into the disposable VM.

## Controller workflow requirements

No controller workflow code should be written until Sarah signs off on the
full gate configuration. The workflow must preserve these boundaries:

- manual or otherwise explicitly trusted pilot trigger;
- full 40-character hexadecimal commit SHA, never a branch or pull-request
  head name;
- strict allowlist of source repositories and permitted test tiers;
- checkout of exactly the validated repository and SHA;
- immutable, SHA-pinned third-party Actions;
- minimal workflow permissions and no guest-visible control-plane secrets;
- job timeout shorter than Runny's two-hour outer deadline;
- result bound to the tested repository and commit SHA;
- no use of workflow files from the tested commit as privileged controller
  logic;
- fail closed on missing, stale, cancelled, malformed, or conflicting results.

The approval agent may tighten a gate but can never loosen it. It may approve
or abstain; it must never request changes or merge.

## Pilot and promotion

Start with manually authorized, trusted exact-SHA runs. Before allowing
outside-contributor code, independently block or narrowly allowlist guest
access to the host and LAN. Runny's default NAT isolates concurrent guests from
one another, but it does not claim to prevent guest-to-host or guest-to-LAN
access.

The pilot must cover at least 20 representative jobs, including:

- success and test failure;
- timeout and cancellation;
- daemon and host restart;
- network loss;
- deliberately dirty guest state;
- sentinel persistence attempts;
- invalid repository and SHA inputs;
- attempts to select a non-allowlisted test tier.

Promotion requires correct SHA attribution on every run, zero cross-job state
survival, no host/LAN/credential exposure, acceptable reliability and resource
pressure, and explicit Sarah-or-Ed sign-off. Until then, results are
informational.

### Disposal smoke results

The manual, zero-permission `Runny Disposal Smoke` workflow in the private
`runner-control` repository performs no checkout and receives no secrets. Its
first VM writes `$HOME/.runny-disposal-sentinel` outside the Actions workspace;
the next VM must prove that file is absent. When available, it also requires the
fresh VM's randomized MAC address to differ.

The first matrix completed on 2026-07-11:

| Ending                | Evidence                                                                                                                                                                                                                               | Result                                                                                                                                     |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Success               | [run 29165598194](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29165598194)                                                                                                                                   | Both jobs passed; sentinel absent and MAC changed in the second VM.                                                                        |
| Forced failure        | [run 29165710907](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29165710907)                                                                                                                                   | First job exited 42; the fresh verification VM passed.                                                                                     |
| Job timeout           | [run 29165744640](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29165744640)                                                                                                                                   | GitHub cancelled the job after its two-minute deadline; the fresh verification VM passed.                                                  |
| External cancellation | [cancelled run 29165854414](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29165854414), then [verification run 29165888616](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29165888616) | The cancelled VM had written its sentinel; the immediately following VM found no sentinel, then completed another two-cycle success check. |

After the matrix, the slot returned to `LISTENING` and every post-boot doctor
check remained green.

### Private-network boundary results

Runny's vmnet NAT permits guest-to-host and guest-to-LAN traffic by default.
The Purple iMac therefore has a dedicated PF child anchor for disposable Runny
guests. The boundary is loaded as `com.apple/runny` from
`/etc/pf.anchors/com.interactivebuffoonery.runny`; it does not replace or flush
Apple's main PF anchor.

The anchor:

- permits the guest subnet to use the vmnet gateway's TCP and UDP DNS service;
- blocks guest IPv4 traffic to private, loopback, link-local, carrier-grade
  NAT, multicast, and reserved ranges;
- blocks guest IPv6 traffic on `bridge100`, including the host's vmnet IPv6
  address; and
- leaves required public IPv4 egress available.

The IPv6 rule is deliberately interface-scoped. Runny management and the
required job egress use IPv4, so a disposable guest has no current reason to
initiate IPv6 traffic over the host bridge.

Persistence uses the following root-owned files:

| File                                                                            | Purpose                                                  | SHA-256 after installation                                         |
| ------------------------------------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------ |
| `/etc/pf.conf`                                                                  | Loads the direct `com.apple/runny` child anchor at boot. | `2625e7ca49aa6bc39488c04d8712b32a4427447cb70d9a2099b0102f7e202d0a` |
| `/etc/pf.anchors/com.interactivebuffoonery.runny`                               | Contains the scoped Runny boundary.                      | `a90b31b25b1d72fc5e21703502a0d1dc233eb8a984b5fd02b6ee18c76133deb7` |
| `/usr/local/libexec/com.interactivebuffoonery.runny-pf-enable`                  | Enables PF and reloads only the child anchor.            | `139f02e136468a27d3f5b1a1b30dc8a884225bf360c2e22642e9d7c22fa4d6bc` |
| `/Library/LaunchDaemons/com.interactivebuffoonery.runny-network-boundary.plist` | Runs the loader once at system startup.                  | `8a891d09ffa3dd2f96de72ba2035087c466b8025ca4358f7842e3e161b64d0d6` |

The original PF configuration remains at
`/etc/pf.conf.pre-runny-network-boundary`. The reviewed recovery script is
staged at `/private/tmp/uninstall-runny-network-boundary.sh`; because
`/private/tmp` is not a durable source of truth, recovery consists of disabling
the LaunchDaemon, restoring that backup, flushing only
`com.apple/runny`, and releasing the loader's PF token. Recreate and review the
script from this procedure if the staged copy is no longer present.

The private `runner-control` repository contains a manual, zero-permission
`Runny Network Boundary Probe`. It performs no checkout and receives no
secrets. Its evidence on 2026-07-11 was:

| Stage                           | Evidence                                                                                             | Result                                                                                                                                                                   |
| ------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Unfiltered baseline             | [run 29166293344](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29166293344) | Guest SSH could reach the vmnet gateway, host LAN and Tailscale routes, and a LAN peer; GitHub API and GHCR were reachable.                                              |
| IPv4 enforcement                | [run 29166612006](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29166612006) | All probed private IPv4 SSH paths were blocked while GitHub API and GHCR remained reachable.                                                                             |
| Persistent IPv4 enforcement     | [run 29169724275](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29169724275) | The same IPv4 boundary passed after installation through the persistent PF child anchor.                                                                                 |
| IPv6 audit                      | [run 29169852282](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29169852282) | Proved the host's vmnet IPv6 SSH path remained reachable, while the IPv4 boundary stayed effective.                                                                      |
| Final IPv4 and IPv6 enforcement | [run 29169942516](https://github.com/Interactive-Buffoonery/runner-control/actions/runs/29169942516) | Gateway, host LAN, host Tailscale, host vmnet IPv6, and LAN-peer SSH were blocked; GitHub API returned HTTP 200 and GHCR returned its expected unauthenticated HTTP 401. |

After the final probe, `runnyctl doctor` remained entirely green, the pinned
image remained cached, and Runny recycled the slot normally.

## Current checklist

- [x] Record host hardware, software, storage, and resource envelope.
- [x] Create and isolate the non-admin `github-runner` account.
- [x] Verify SSH through LAN and Tailscale routes.
- [x] Prove Apple Virtualization can run a 4-vCPU, 8-GiB Tahoe guest.
- [x] Prove basic fresh-clone disposal with a sentinel test.
- [x] Remove Tart and Softnet from the production path.
- [x] Install and open Runny.app v1.1.0 as `github-runner`.
- [x] Create private `Interactive-Buffoonery/runner-control`.
- [x] Initialize GitHub Actions with the isolated manual bootstrap workflow.
- [ ] Empty the old Tart image library from `github-runner` Trash.
- [x] Create and install the repository-scoped GitHub App.
- [x] Transfer the App key and install the reviewed Runny configuration.
- [x] Pass Runny's pre-start configuration, permission, image, and host checks.
- [x] Enable the Runny LaunchAgent.
- [x] Pass post-boot `runnyctl doctor`, including Local Network confirmation.
- [x] Download, verify, cache, boot, and register the pinned production image.
- [ ] Sign off on and implement the exact-SHA controller workflow.
- [x] Prove disposal after success, failure, timeout, and cancellation.
- [x] Implement and verify guest-to-host and guest-to-LAN isolation.
- [ ] Complete the 20-run informational pilot and review its results.
- [ ] Promote the result only after Sarah-or-Ed sign-off.

## References

- [Runny onboarding](https://github.com/bojanrajkovic/runny/blob/main/docs/onboarding.md)
- [Runny security model](https://github.com/bojanrajkovic/runny/blob/main/docs/security.md)
- [Runny repository](https://github.com/bojanrajkovic/runny)
- [GitHub self-hosted runner security](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners)
- [Apple Fast User Switching](https://support.apple.com/guide/mac-help/mchlp2439/mac)
