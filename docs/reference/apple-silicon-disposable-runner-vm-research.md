# Disposable macOS runner VMs on Apple Silicon

**Date:** 2026-07-11
**Scope:** Evaluate disposable macOS VMs for an awesoMux GitHub Actions runner
on `purpleimac`, an M1 iMac with 16 GB RAM.

## Recommendation

Pilot **Tart with Tartelet**, using one VM at a time and registering runners only
with the private runner-control repository.

Tart is the most mature automation-oriented VM engine in this set. It uses
Apple's Virtualization framework, provides fast clones, OCI image distribution,
SSH and guest-command automation, and maintained macOS/Xcode images. Its current
repository is now under OpenAI and its latest listed release is 2.32.1 from
April 2026. ([Tart repository](https://github.com/openai/tart),
[Tart quick start](https://tart.run/quick-start/))

Tartelet is probably the GitHub project Sarah remembers seeing. It is a macOS
app built specifically to launch self-hosted GitHub Actions runners inside
ephemeral Tart VMs. For each job it clones a golden VM, boots it, registers a
runner, lets it execute one job, deregisters it, shuts it down, and deletes the
clone. It supports repository-scoped registration and stores its GitHub App key
in the host keychain. ([Tartelet lifecycle](https://github.com/framna-dk/tartelet#%EF%B8%8F-how-does-it-work),
[Tartelet configuration](https://github.com/framna-dk/tartelet/wiki/Configuring-Tartelet))

This is materially safer than running Actions directly on the iMac, but it is
not a complete trust boundary by itself. GitHub warns that self-hosted runners
can be persistently compromised by untrusted workflow code and should almost
never be attached directly to public repositories. GitHub also says a JIT
runner's one-job registration does not clean reused hardware; the environment
must be reset separately. Tartelet supplies that missing VM clone/delete reset.
([GitHub secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners))

## What “disposable” means

```text
read-only golden VM
        |
        | clone
        v
per-job VM -> ephemeral GitHub runner -> one exact-SHA test job
        |
        | deregister, stop, delete
        v
no job-written disk survives
```

The golden VM contains macOS, Xcode, Zig, the Actions runner prerequisites, and
awesoMux's build dependencies, but no repository checkout or long-lived CI
secret. Each job starts from that known state. Destroying the clone removes
malware, modified toolchains, caches, credentials, and other files written
inside that guest.

This protects later jobs from an earlier job. It does not make the current job
trusted, prevent a VM escape, or stop the guest from attacking reachable LAN or
host services. Tart documents that a guest on its default NAT network can reach
host services bound to all interfaces; do not expose host services to the guest
and prefer a separate firewall/VLAN policy if outside contributor code is ever
allowed. Do not mount host directories into the VM.
([Tart networking FAQ](https://tart.run/faq/#connecting-to-a-service-running-on-host))

## Licensing constraints

There are two separate licenses to account for.

### macOS guest license

Apple's macOS Sequoia license permits up to two additional macOS copies or
instances in virtual environments on each Apple-branded computer already
running macOS, for software development, testing during development, macOS
Server, or personal non-commercial use. It does not generally permit using
those VMs for service-bureau, time-sharing, terminal-sharing, or similar
services. An internally controlled awesoMux development/test runner on an owned
M1 iMac fits the stated development/testing purpose; this note is not legal
advice. ([Apple macOS Sequoia license, section 2B(iii)](https://www.apple.com/legal/sla/docs/macOSSequoia.pdf))

Use only Apple-branded hosts, accept the macOS and Xcode license terms in the
golden image, and keep the pilot to one VM. One VM is also the practical limit
for a 16 GB M1 while leaving enough memory for the host.

### Tart license

Tart is source-available under the Fair Source License, not an OSI open-source
license. Personal computers and workstations are royalty-free. The free tier
for organizations allows up to 100 host CPU cores; paid licensing begins above
that threshold. A single M1 iMac is comfortably within the free tier, but the
license should be revisited before growing this into a substantial fleet.
([Tart support and licensing](https://tart.run/licensing/))

Tartelet itself is MIT-licensed. ([Tartelet repository](https://github.com/framna-dk/tartelet))

## Comparison

| Project | Reset model | Headless automation | Actions fit | Assessment |
| --- | --- | --- | --- | --- |
| **Tart** | Fast clone/delete from a local or OCI golden image; suspend/resume is also available on supported host/guest versions | CLI, SSH, `tart exec`, Packer, OCI images | Strong ecosystem; Tartelet and Cilicon add runner lifecycle | Best VM engine for this pilot |
| **Tartelet** | Clones and destroys a Tart VM after every Actions job | Host macOS app manages the whole cycle | Purpose-built; repository or organization scope | Best one-Mac pilot orchestrator |
| **Cilicon** | Creates/provisions ephemeral VMs using Tart-format local or OCI images | Host app connects by SSH and supports health probes | Supports GitHub Actions through a GitHub App | Strong alternative; current 2.4.2 release is newer than Tartelet's latest release, but its setup is more infrastructure-oriented ([Cilicon repository](https://github.com/traderepublic/Cilicon)) |
| **Lume / Cua** | Clone/delete a known-good VM; no dedicated snapshot command | Excellent CLI, `--no-display`, unattended setup, HTTP API | No first-party GitHub runner lifecycle; we would build that layer | Most likely other recent project; attractive MIT option if Tart licensing becomes undesirable ([Lume introduction](https://cua.ai/docs/lume/guide/getting-started/introduction), [Lume CLI](https://cua.ai/docs/lume/reference/cli-reference)) |
| **VirtualBuddy** | Saved state plus manual APFS cloning | GUI-first; no documented CI CLI/API | Poor | Good manual macOS-version test lab, not a runner controller ([VirtualBuddy repository](https://github.com/insidegui/VirtualBuddy)) |
| **UTM** | VM cloning and supported save states | `utmctl`/AppleScript can start and stop VMs; UTM must remain open for headless VMs | Possible but requires custom lifecycle work | Broad and actively maintained, but optimized for general VM use rather than disposable macOS CI ([UTM scripting](https://docs.getutm.app/scripting/scripting/), [UTM headless mode](https://docs.getutm.app/advanced/headless/)) |
| **Orchard** | Schedules and deletes Tart VMs across workers | CLI and REST API | Fleet primitive, not a GitHub runner controller | Unnecessary for one or two Macs; reconsider only when several hosts need central scheduling ([Orchard repository](https://github.com/openai/orchard)) |

Lume launched as a recent, open-source Apple Silicon macOS VM CLI and is now
part of the Cua repository, so it is another plausible project Sarah saw. It is
MIT-licensed and supports unattended macOS setup, headless operation, clones,
OCI/GCS images, and a local HTTP API. It is a compelling engine, but for this
specific task Tartelet already implements the runner registration and disposal
loop that we would otherwise have to write and secure.

## Concrete `purpleimac` pilot

1. **Prepare the host.** Use a dedicated non-admin `github-runner` account with
   no iCloud, personal files, SSH keys, signing identities, package-registry
   credentials, Synthetic credentials, or Linear credentials. Keep the GitHub
   App private key only in the host account's keychain. Disable host sleep while
   the pilot is active.

2. **Install Tart and Tartelet.** Pin known versions rather than following
   `latest` silently. Start with one VM, not two. On a 16 GB M1, allocate roughly
   4 vCPUs and 6-8 GB RAM after measuring host pressure; Xcode plus the awesoMux
   Ghostty build may make 8 GB guests tight.

3. **Build a golden image.** Use a pinned macOS/Xcode image or create one from
   an Apple IPSW. Install the exact Xcode and Zig versions awesoMux requires,
   accept Xcode's license, enable SSH/autologin as required by Tartelet, and run
   `./script/swift-test.sh` once. Shut the VM down cleanly and never run CI jobs
   in the golden source itself. Tart publishes base and Xcode images for current
   macOS releases and supports creating from an IPSW.
   ([Tart images and VM creation](https://tart.run/quick-start/#vm-images))

4. **Register only with the private control repository.** Create a narrowly
   scoped GitHub App for that repository's self-hosted runners. Do not attach
   this runner to the public awesoMux repository or a broad organization runner
   group. Give the runner a unique label such as `awesomux-m1-vm`.

5. **Keep the workflow trusted.** The private workflow takes an exact awesoMux
   commit SHA, validates that it is a full hexadecimal SHA reachable from the
   intended repository, checks out that SHA, and runs only deterministic build
   and test commands. Use `permissions: contents: read`; provide no Actions
   secrets to the guest. Do not use workflow definitions or scripts fetched
   from the tested commit as privileged control logic.

6. **Prove disposal.** In the first tests, have a job write a unique sentinel
   outside the checkout. Verify the next job receives a different VM identity
   and cannot find the sentinel. Also cancel jobs and force failures to confirm
   Tartelet still deregisters and deletes their VMs.

7. **Measure before making it a gate.** Record clone-to-ready time, Swift test
   time, full preflight time, peak host/guest memory, disk growth, failure and
   cancellation cleanup, and ten consecutive clean runs. Keep results advisory
   until the runner is stable.

8. **Add Ed's Mac later as another independent host.** Give it the same golden
   image version and shared label, but separate host account and credentials.
   Orchard is not needed merely to let GitHub schedule between two Tartelet
   hosts.

## Security acceptance criteria

Do not run outside-contributor code automatically until all of these hold:

- Every job receives a new VM clone and a one-job ephemeral/JIT runner.
- The golden image is immutable during normal operation and is rebuilt through
  a reviewed process.
- The guest has no mounted host directories, signing material, personal Apple
  account, persistent secrets, SSH agent forwarding, or host administration.
- Runner access is limited to the private controller repository.
- Guest-to-host and guest-to-LAN access is blocked or explicitly allowlisted.
- Logs and test artifacts leave the VM before deletion, without containing
  secrets. GitHub recommends external preservation of ephemeral runner logs.
  ([GitHub self-hosted runner reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling))
- VM disposal is independently verified after success, failure, timeout, and
  cancellation.

The practical conclusion is: **use Tart/Tartelet now, with one disposable VM on
`purpleimac`; keep the private exact-SHA controller architecture; treat the VM
as containment for untrusted build code, not as permission to expose secrets or
the personal Mac environment.**
