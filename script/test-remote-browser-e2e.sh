#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

mkdir -p "$root/.build"
fixture_dir=$(mktemp -d "$root/.build/browser-evidence-fixture.XXXXXXXX")
artifact_dir=$(mktemp -d "$root/.build/browser-evidence-artifacts.XXXXXXXX")
sshd_config="$fixture_dir/sshd_config"
pid_file="$fixture_dir/sshd.pid"

cleanup() {
    if [ -f "$pid_file" ]; then
        pid=$(sed -n '1p' "$pid_file")
        command=$(ps -p "$pid" -o command= 2>/dev/null || true)
        case "$command" in
            *"/usr/sbin/sshd"*"$sshd_config"*) kill "$pid" 2>/dev/null || true ;;
        esac
    fi
    if [ -f "$fixture_dir/sshd.log" ]; then
        cp "$fixture_dir/sshd.log" "$artifact_dir/sshd.log" \
            || echo "warning: could not retain sshd.log" >&2
    fi
    if command -v trash >/dev/null 2>&1; then
        trash "$fixture_dir" || echo "warning: could not trash fixture at $fixture_dir" >&2
    else
        echo "warning: trash is unavailable; fixture retained at $fixture_dir" >&2
    fi
    echo "Remote browser E2E artifacts: $artifact_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

port=$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
user=$(id -un)
umask 077
ssh-keygen -q -t ed25519 -N '' -C awesomux-browser-e2e-host -f "$fixture_dir/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N '' -C awesomux-browser-e2e-client -f "$fixture_dir/client_ed25519"
cp "$fixture_dir/client_ed25519.pub" "$fixture_dir/authorized_keys"

cat > "$sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
AddressFamily inet
HostKey "$fixture_dir/ssh_host_ed25519_key"
PidFile "$pid_file"
AuthorizedKeysFile "$fixture_dir/authorized_keys"
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
StrictModes no
AllowUsers $user
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF

cat > "$fixture_dir/ssh_config" <<EOF
Host awesomux-browser-e2e
    HostName 127.0.0.1
    Port $port
    User $user
    IdentityFile "$fixture_dir/client_ed25519"
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    UserKnownHostsFile "$fixture_dir/known_hosts"
    GlobalKnownHostsFile /dev/null
EOF

/usr/sbin/sshd -t -f "$sshd_config"
/usr/sbin/sshd -E "$fixture_dir/sshd.log" -f "$sshd_config"
ssh-keyscan -q -p "$port" 127.0.0.1 > "$fixture_dir/known_hosts"
chmod 600 "$fixture_dir/known_hosts"
/usr/bin/ssh -F "$fixture_dir/ssh_config" awesomux-browser-e2e 'test "$(uname -m)" = arm64'

swift build --product awesoMuxBridgeHelper
helper="$(swift build --show-bin-path)/awesoMuxBridgeHelper"
test -x "$helper"

AWESOMUX_BROWSER_E2E=1 \
AWESOMUX_BROWSER_E2E_SSH_CONFIG="$fixture_dir/ssh_config" \
AWESOMUX_BROWSER_E2E_HELPER="$helper" \
AWESOMUX_BROWSER_E2E_ARTIFACT_DIR="$artifact_dir" \
./script/swift-test.sh --filter RemoteBrowserE2ETests
