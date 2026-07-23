#!/usr/bin/env bash
# End-to-end SSH smoke for the Linux bridge helper (#87 acceptance):
# real sshd, real ssh, manual-install layout, receipt + custody + cleanup
# assertions. Runs in CI (ubuntu runner) or locally anywhere docker works.
set -euo pipefail

HELPER="${1:?usage: linux_handoff_smoke.sh <helper-binary>}"
CONTAINER="awesomux-handoff-smoke"
PORT=2222
KEYDIR="$(mktemp -d)"
SSH_OPTS=(-p "$PORT" -i "$KEYDIR/id" -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SSH=(ssh "${SSH_OPTS[@]}" handoff@127.0.0.1)

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$KEYDIR"; }
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

# --- sshd container -------------------------------------------------------
docker run -d --name "$CONTAINER" -p "127.0.0.1:${PORT}:22" ubuntu:24.04 sleep infinity >/dev/null
docker exec "$CONTAINER" bash -c \
  'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null && mkdir -p /run/sshd'
ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/id"
docker exec "$CONTAINER" useradd -m -s /bin/bash handoff
docker exec "$CONTAINER" install -d -m 700 -o handoff -g handoff /home/handoff/.ssh
docker cp "$KEYDIR/id.pub" "$CONTAINER:/home/handoff/.ssh/authorized_keys"
docker exec "$CONTAINER" bash -c \
  'chown handoff:handoff /home/handoff/.ssh/authorized_keys && chmod 600 /home/handoff/.ssh/authorized_keys'
docker exec -d "$CONTAINER" /usr/sbin/sshd -D
for _ in $(seq 1 30); do
  "${SSH[@]}" true 2>/dev/null && break
  sleep 1
done
"${SSH[@]}" true || fail "sshd never came up"

# --- manual install, per docs/remote-linux-helper.md ----------------------
# Piped over ssh rather than scp: scp's -p means preserve-times (its port
# flag is -P), so reusing SSH_OPTS with scp silently targets port 22.
"${SSH[@]}" 'install -d -m 700 ~/.awesomux && install -d -m 755 ~/.awesomux/bin'
"${SSH[@]}" 'cat > ~/.awesomux/bin/awesomux-bridge-helper' < "$HELPER"
"${SSH[@]}" 'chmod 755 ~/.awesomux/bin/awesomux-bridge-helper'

# --- acceptance: --version advertises both protocols ----------------------
VERSION_OUT="$("${SSH[@]}" '~/.awesomux/bin/awesomux-bridge-helper --version')"
[[ "$VERSION_OUT" == $'awesomux-bridge-v1\nawesomux-handoff-v1' ]] \
  || fail "unexpected --version output: $VERSION_OUT"

# --- acceptance: successful handoff ---------------------------------------
SID="0f0e6c56-9d1f-4c7e-9b1a-3d6f2a54e7c1"
PAYLOAD="hello linux handoff"
RECEIPT="$(printf '%s' "$PAYLOAD" | "${SSH[@]}" \
  "~/.awesomux/bin/awesomux-bridge-helper receive-handoff --session $SID --name note.md --expected-bytes ${#PAYLOAD}")"
REMOTE_PATH="$(printf '%s' "$RECEIPT" | jq -re .path)"
BYTES="$(printf '%s' "$RECEIPT" | jq -re .bytes)"
[[ "$BYTES" == "${#PAYLOAD}" ]] || fail "receipt bytes $BYTES != ${#PAYLOAD}"
[[ "$REMOTE_PATH" == "/home/handoff/.awesomux/handoffs/$SID/"*.md ]] \
  || fail "receipt path off-contract: $REMOTE_PATH"
[[ "$("${SSH[@]}" "cat '$REMOTE_PATH'")" == "$PAYLOAD" ]] || fail "content mismatch"
[[ "$("${SSH[@]}" "stat -c '%a' ~/.awesomux/handoffs")" == "700" ]] || fail "handoffs dir mode"
[[ "$("${SSH[@]}" "stat -c '%a' ~/.awesomux/handoffs/$SID")" == "700" ]] || fail "session dir mode"
[[ "$("${SSH[@]}" "stat -c '%a' '$REMOTE_PATH'")" == "600" ]] || fail "file mode"
# Musl-specific: the static binary publishes via linkat + deferred unlinkat,
# so this catches a surviving .handoff-*.tmp hard link Glibc wouldn't leave.
ENTRY_COUNT="$("${SSH[@]}" "ls -A ~/.awesomux/handoffs/$SID | wc -l" | tr -d '[:space:]')"
[[ "$ENTRY_COUNT" == "1" ]] || fail "session dir has $ENTRY_COUNT entries (expected exactly the published file — a leftover .handoff-*.tmp means the musl linkat publish didn't clean its temporary hard link)"

# --- acceptance: early EOF fails without leftovers ------------------------
SID2="1a2b3c4d-0000-4000-8000-000000000002"
if printf 'abc' | "${SSH[@]}" \
  "~/.awesomux/bin/awesomux-bridge-helper receive-handoff --session $SID2 --name x.md --expected-bytes 9999"; then
  fail "early-EOF handoff unexpectedly succeeded"
fi
LEFTOVERS="$("${SSH[@]}" "ls -A ~/.awesomux/handoffs/$SID2 2>/dev/null | wc -l")"
[[ "$LEFTOVERS" == "0" ]] || fail "early EOF left $LEFTOVERS file(s) behind"

echo "SMOKE PASS"
