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


def helper_cases(args, fixture, client_config, cache, helper):
    """Drive awesomux-ssh directly; a logging ssh shim records every invocation."""
    results = []
    shim_dir = fixture / 'helper-bin'
    shim_dir.mkdir()
    log = fixture / 'ssh-invocations'
    (shim_dir / 'ssh').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(log)) + '\nexec /usr/bin/ssh "$@"\n')
    (shim_dir / 'ssh').chmod(0o700)
    env = {**os.environ, 'TERM': 'xterm-ghostty', 'AWESOMUX_SSH_TERMINFO_HOSTS': str(cache),
           'PATH': str(shim_dir) + ':' + os.environ.get('PATH', '/usr/bin:/bin')}
    if args.terminfo:
        env['TERMINFO'] = str(args.terminfo)
    ssh_args = ['-F', str(client_config), '-o', 'SendEnv=AWESOMUX_E2E_HOME AWESOMUX_E2E_PATH']

    def connect(case, expected, *mode, term='xterm-ghostty'):
        log.unlink(missing_ok=True)
        result = subprocess.run(['/bin/sh', str(helper), *mode] + ssh_args + ['-tt', 'fixture', 'printf "REMOTE:%s\\n" "$TERM"; exit 7'],
                                env={**env, 'TERM': term}, capture_output=True, timeout=12)
        (args.output / ('helper-' + case + '.txt')).write_bytes(result.stdout + result.stderr)
        assert result.returncode == 7, f'{case}: exit status {result.returncode}'
        assert ('REMOTE:' + expected).encode() in result.stdout, f'{case}: {result.stdout!r}'
        return log.read_text().splitlines()

    def setup(case, answer, home, *extra, path=None):
        case_env = {**env, 'AWESOMUX_E2E_HOME': str(home)}
        if path:
            case_env['AWESOMUX_E2E_PATH'] = str(path)
        master, slave = pty.openpty()
        process = subprocess.Popen(['/bin/sh', str(helper), '--setup-terminfo', *extra] + ssh_args + ['fixture'],
                                   stdin=slave, stdout=slave, stderr=slave, env=case_env, preexec_fn=control_terminal)
        os.close(slave)
        output = b''
        try:
            output = read_until(master, b'[y/N] ')
            os.write(master, (answer + '\r').encode())
            while True:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            status = process.wait(timeout=12)
        finally:
            (args.output / ('setup-' + case + '.txt')).write_bytes(output)
            os.close(master)
        return status, output

    cache.unlink(missing_ok=True)
    invocations = connect('missing-cache', 'xterm-256color')
    assert not any(line.startswith('-G') for line in invocations), invocations
    results.append('PASS helper-missing-cache (no ssh -G)')
    cache.write_text('')
    invocations = connect('empty-cache', 'xterm-256color')
    assert not any(line.startswith('-G') for line in invocations), invocations
    results.append('PASS helper-empty-cache (no ssh -G)')
    cache.write_text('\n')
    invocations = connect('blank-cache', 'xterm-256color')
    assert not any(line.startswith('-G') for line in invocations), invocations
    results.append('PASS helper-blank-line-cache (no ssh -G)')
    cache.write_text('')
    connect('other-term', 'vt100', term='vt100')
    connect('portable-other-term', 'xterm-256color', '--portable', term='vt100')
    results.append('PASS helper-other-term (passed through; --portable falls back)')
    if not args.terminfo:
        return results

    home = fixture / 'setup-home'
    home.mkdir()
    status, output = setup('declined', 'n', home)
    assert status == 1 and b'Skipped' in output, output
    assert not (home / '.terminfo').exists(), 'declined setup wrote remote files'
    assert cache.read_text() == '', 'declined setup cached the host'
    results.append('PASS setup-declined')

    status, output = setup('installed', 'y', home)
    assert status == 0 and b'installed' in output, output
    assert any((home / '.terminfo').glob('*/xterm-ghostty')), 'definition not written'
    results.append('PASS setup-installed')
    connect('cached', 'xterm-ghostty')
    results.append('PASS helper-cached-host')

    written = next((home / '.terminfo').glob('*/xterm-ghostty'))
    before = written.stat().st_mtime_ns
    status, output = setup('present', 'y', home)
    assert status == 0 and b'present' in output, output
    assert written.stat().st_mtime_ns == before, 'present definition was rewritten'
    assert cache.read_text().count('\n') == 1, 'host cached twice'
    results.append('PASS setup-present (no rewrite)')
    status, output = setup('force', 'y', home, '--force')
    assert status == 0 and b'installed' in output, output
    results.append('PASS setup-force')

    cache.write_text('someone@elsewhere:22\n' + cache.read_text())
    connect('portable-cached', 'xterm-ghostty', '--portable')
    forget = ['/bin/sh', str(helper), '--forget'] + ssh_args + ['fixture']
    result = subprocess.run(forget, env=env, capture_output=True, timeout=12)
    assert result.returncode == 0 and b'Forgot' in result.stdout, result
    assert cache.read_text() == 'someone@elsewhere:22\n', 'forget changed other entries'
    connect('forgotten', 'xterm-256color')
    result = subprocess.run(forget, env=env, capture_output=True, timeout=12)
    assert result.returncode == 0 and b'was not set up' in result.stdout, result
    results.append('PASS forget (keeps other hosts; reports unknown host)')
    cache.write_text('')

    remote_bin = fixture / 'remote-bin'
    remote_bin.mkdir()
    (remote_bin / 'sh').symlink_to('/bin/sh')
    status, output = setup('no-tic', 'y', fixture / 'no-tic-home', path=remote_bin)
    assert status == 1 and b'no tic' in output and cache.read_text() == '', output
    results.append('PASS setup-no-tic')

    read_only = fixture / 'read-only-home'
    read_only.mkdir(mode=0o500)
    try:
        status, output = setup('read-only', 'y', read_only)
    finally:
        read_only.chmod(0o700)
    assert status == 1 and b'Could not write' in output and cache.read_text() == '', output
    results.append('PASS setup-read-only-home')
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--integration', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fish', type=Path, help='Also exercise fish startup resources')
    parser.add_argument('--amx', type=Path, help='Also run the existing mouse recovery PTY suite')
    parser.add_argument('--terminfo', type=Path,
                        help='Compiled terminfo directory with xterm-ghostty; enables the setup cases')
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
AcceptEnv AWESOMUX_E2E_HOME AWESOMUX_E2E_PATH
# Remote writes land in a fixture home, never the real one.
ForceCommand HOME="${{AWESOMUX_E2E_HOME:-{fixture / 'remote-home'}}}" PATH="${{AWESOMUX_E2E_PATH:-$PATH}}"; export HOME PATH; eval "${{SSH_ORIGINAL_COMMAND:-exec $SHELL -l}}"
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
    (fixture / 'remote-home').mkdir()
    cache = fixture / 'ssh-terminfo-hosts'
    helper = args.integration.parent / 'awesomux-ssh'
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
                       AWESOMUX_SSH_TERMINFO_HOSTS=str(cache),
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
                fish_env = {**os.environ, 'TERM': 'xterm-ghostty', 'AWESOMUX_SSH_TERMINFO_HOSTS': str(cache),
                            'GHOSTTY_RESOURCES_DIR': str(args.integration.parent.parent)}
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
        results += helper_cases(args, fixture, client_config, cache, helper)
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
