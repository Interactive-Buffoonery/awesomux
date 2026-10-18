#!/usr/bin/env python3
"""Verify generated SSH shell integration over disposable loopback OpenSSH PTYs."""
import argparse
import getpass
import glob
import os
from pathlib import Path
import pty
import select
import signal
import shlex
import socket
import struct
import subprocess
import termios
import fcntl
import time


def read_until(fd, needle, timeout=12):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data:
        left = deadline - time.monotonic()
        if left <= 0:
            raise AssertionError(f"missing {needle!r}: {bytes(data)!r}")
        if select.select([fd], [], [], left)[0]:
            chunk = os.read(fd, 65536)
            data.extend(chunk)
    return bytes(data)


def config_path(path):
    """OpenSSH config values use double quotes, not POSIX shell quoting."""
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def control_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--integration', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fish', type=Path, help='Also exercise fish startup resources')
    parser.add_argument('--amx', type=Path, help='Also run the existing mouse recovery PTY suite')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.output / 'private-fixture'
    fixture.mkdir(mode=0o700)
    key = fixture / 'key'
    subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    server_config = fixture / 'sshd.conf'
    # AuthorizedKeysFile expands both globs and percent tokens after parsing.
    authorized_key = glob.escape(str(fixture / 'key.pub')).replace('\\', '\\\\').replace('%', '%%')
    server_config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {config_path(key)}
PidFile {config_path(fixture / 'pid')}
AuthorizedKeysFile {config_path(authorized_key)}
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PrintMotd no
''')
    client_config = fixture / 'ssh.conf'
    client_config.write_text(f'''Host fixture
  HostName 127.0.0.1
  User {getpass.getuser()}
  Port {port}
  IdentityFile {config_path(str(key).replace('%', '%%'))}
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
''')
    server_log = (args.output / 'sshd.log').open('w')
    server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(server_config)], stdout=server_log, stderr=server_log)
    results = []
    try:
        deadline = time.monotonic() + 5
        while True:
            if server.poll() is not None:
                raise RuntimeError('loopback sshd failed; inspect sshd.log')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    break
            except OSError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.05)
        cases = [
            ('ordinary', '', '', 'xterm-256color'),
            ('explicit-term', '', 'TERM=vt100 ', 'vt100'),
            ('user-function', 'ssh() { print -r -- CUSTOM-SSH; command ssh "$@"; }\n', '', 'xterm-ghostty'),
            ('user-alias', "alias ssh='command ssh'\n", '', 'xterm-ghostty'),
            ('bypass', '', 'command ', 'xterm-ghostty'),
            ('path-wrapper', '', '', 'xterm-256color'),
            ('startup-alias', '', '', 'xterm-256color'),
        ]
        for case, startup, prefix, expected in cases:
            user = fixture / case
            user.mkdir()
            if case == 'startup-alias':
                (user / '.zshenv').write_text("alias command='printf ALIAS-EXPANDED'\n")
            (user / '.zshrc').write_text("PS1='PROOF> '\nRPROMPT=''\n" + startup)
            env = os.environ.copy()
            env.update(TERM='xterm-ghostty', ZDOTDIR=str(args.integration),
                       GHOSTTY_ZSH_ZDOTDIR=str(user),
                       GHOSTTY_RESOURCES_DIR=str(args.integration.parent.parent),
                       AWESOMUX_SSH_MOUSE_RECOVERY='1')
            if case == 'path-wrapper':
                bin_dir = user / 'bin'
                bin_dir.mkdir()
                shim = bin_dir / 'ssh'
                shim.write_text('#!/bin/sh\nprintf "PATH-WRAPPER:%s\\n" "$TERM"\nexec /usr/bin/ssh "$@"\n')
                shim.chmod(0o700)
                env['PATH'] = str(bin_dir) + ':' + env.get('PATH', '/usr/bin:/bin')
            shell_command = ['/bin/zsh', '-d', '-i']
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 55, 0, 0))
            process = subprocess.Popen(shell_command, stdin=slave, stdout=slave, stderr=slave,
                                       env=env, preexec_fn=control_terminal)
            os.close(slave)
            captured = bytearray()
            try:
                captured.extend(read_until(master, b'PROOF> '))
                # A real SSH PTY carries TERM independently of SendEnv/AcceptEnv.
                remote = 'printf "REMOTE:%s\\n" "$TERM"; printf "ARG:%s\\n" "space ; literal"; exit 7'
                command = prefix + 'ssh -F ' + shlex.quote(str(client_config)) + ' -tt fixture ' + shlex.quote(remote)
                os.write(master, (command + '\r').encode())
                output = read_until(master, b'PROOF> ')
                captured.extend(output)
                status = '$?'
                os.write(master, ('printf "LOCAL:%s STATUS:%s\\n" "$TERM" "' + status + '"\r').encode())
                local = read_until(master, b'LOCAL:xterm-ghostty STATUS:7\r\n')
                output += local
                captured.extend(local)
                assert ('REMOTE:' + expected + '\r\n').encode() in output, f'{case}: wrong remote terminal'
                assert b'ARG:space ; literal\r\n' in output, f'{case}: remote arguments changed'
                if case == 'ordinary':
                    assert b'\x1b[?1006l' in output, 'SSH wrapper disabled mouse recovery'
                if case == 'user-function':
                    assert b'CUSTOM-SSH\r\n' in output, 'user SSH function replaced'
                if case == 'path-wrapper':
                    assert b'PATH-WRAPPER:xterm-256color\r\n' in output, 'PATH SSH wrapper bypassed'
                results.append('PASS ' + case)
            finally:
                (args.output / (case + '.txt')).write_text(captured.replace(b'\x1b', b'<ESC>').decode('utf-8', 'backslashreplace'))
                os.close(master)
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)
        if args.fish:
            for case, startup, prefix, expected in cases:
                if case == 'startup-alias':
                    continue
                if case == 'user-function':
                    startup = 'function ssh; echo CUSTOM-SSH; command ssh $argv; end; '
                elif case == 'user-alias':
                    startup = "alias ssh 'command ssh'; "
                integration = args.integration.parent / 'fish/vendor_conf.d/awesomux-ssh-compat.fish'
                remote = 'printf "REMOTE:%s\\n" "$TERM"; exit 7'
                command = prefix + 'ssh -F ' + shlex.quote(str(client_config)) + ' -tt fixture ' + shlex.quote(remote)
                code = 'source ' + shlex.quote(str(integration)) + '; ' + startup + 'emit fish_prompt; ' + command
                code += '; printf "LOCAL:%s STATUS:%s\\n" "$TERM" "$status"'
                fish_env = {**os.environ, 'TERM': 'xterm-ghostty'}
                if case == 'path-wrapper':
                    fish_env['PATH'] = str(fixture / case / 'bin') + ':' + fish_env.get('PATH', '/usr/bin:/bin')
                result = subprocess.run([str(args.fish), '--no-config', '-i', '-c', code],
                                        env=fish_env, capture_output=True, timeout=12)
                (args.output / ('fish-' + case + '.txt')).write_bytes(result.stdout + result.stderr)
                assert result.returncode == 0, result.stderr
                assert ('REMOTE:' + expected).encode() in result.stdout, result.stdout
                assert b'LOCAL:xterm-ghostty STATUS:7' in result.stdout, result.stdout
                if case == 'path-wrapper':
                    assert b'PATH-WRAPPER:xterm-256color' in result.stdout, result.stdout
                results.append('PASS fish-' + case)
        if args.amx:
            subprocess.run([
                'python3', str(Path(__file__).resolve().parents[1] / 'test-ssh-mouse-recovery.py'),
                '--amx', str(args.amx), '--integration', str(args.integration),
                '--host', 'fixture', '--ssh-config', str(client_config),
                '--output', str(args.output / 'mouse-recovery'),
            ], check=True)
            results.append('PASS existing mouse-recovery suite')
    finally:
        server.terminate()
        server.wait(timeout=5)
        server_log.close()
        (args.output / 'report.txt').write_text('\n'.join(results) + '\n')
    print('\n'.join(results))
    print('Artifacts:', args.output)
    print('Private fixture keys stay in private-fixture; exclude them from review/publication.')


if __name__ == '__main__':
    main()
