#!/usr/bin/env python3
"""Exercise generated zsh recovery through disposable amx PTYs and SSH."""

import argparse
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import time

REPORT = b"\x1b[<35;4;22M\x1b[<35;8;22M\x1b[<35;12;23M"
RESET = b"".join(b"\x1b[?" + str(mode).encode() + b"l" for mode in (9, 1000, 1002, 1003, 1005, 1006, 1015, 1016))
TUI = """import os,select,termios,tty
old=termios.tcgetattr(0)
tty.setraw(0)
try:
 os.write(1,b'\\x1b[?1003h\\x1b[?1006hTUI-READY\\r\\n')
 data=b''
 for _ in range(3):
  ready,_,_=select.select([0],[],[],15)
  if not ready: break
  data=os.read(0,4096)
  if data.strip(b'\\r\\n'): break
 os.write(1,b'TUI-GOT:'+data.hex().encode()+b'\\r\\n')
finally:
 termios.tcsetattr(0,termios.TCSANOW,old)
"""


def read_until(fd, needle, timeout=15):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while needle not in data:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"missing {needle!r}: {bytes(data)!r}")
        if select.select([fd], [], [], remaining)[0]:
            data.extend(os.read(fd, 65536))
    return bytes(data)


def drain(fd, timeout=0.2):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            break
        data.extend(os.read(fd, 65536))
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--amx", required=True, type=Path)
    parser.add_argument("--integration", required=True, type=Path)
    parser.add_argument("--host", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    user = args.output / "user"
    user.mkdir(exist_ok=True)
    (user / ".zshrc").write_text("PS1='PROOF> '\nRPROMPT=''\n")
    local_tui = args.output / "tui.py"
    local_tui.write_text(TUI)
    env = os.environ.copy()
    env.update(
        ZMX_DIR=str(args.output / "s"), ZMX_DIR_MODE="700", SHELL="/bin/zsh",
        ZDOTDIR=str(args.integration), GHOSTTY_ZSH_ZDOTDIR=str(user),
        GHOSTTY_RESOURCES_DIR=str(args.integration.parent.parent),
        AWESOMUX_SSH_MOUSE_RECOVERY="1",
    )
    ssh = f"ssh -o BatchMode=yes {shlex.quote(args.host)}"
    remote_enable = ssh + " " + shlex.quote("printf '\\033[?1003h\\033[?1006hREMOTE-DIED\\n'")
    local_command = "python3 " + shlex.quote(str(local_tui))
    remote_tui = ssh + " -tt " + shlex.quote("python3 -c " + shlex.quote(TUI))
    results = []

    for case in ("ssh-exit", "local-tui", "remote-tui", "compound-tui", "next-tui", "nested-tui", "reattach-tui", "ordinary-command", "hook-chain", "ssh-failure", "suspended-ssh", "absolute-ssh", "unrelated-stopped"):
        startup = "PS1='PROOF> '\nRPROMPT=''\n"
        startup += "_proof_preexec() { printf 'LATER-PREEXEC\\n'; }\n"
        startup += "_proof_precmd() { printf 'LATER-PRECMD:%s\\n' $?; }\n"
        startup += "preexec_functions+=(_proof_preexec)\nprecmd_functions+=(_proof_precmd)\n"
        if case == "suspended-ssh":
            startup += "zmodload zsh/parameter\n"
            startup += "_proof_jobs() { print -r -- JOB-STATES:${(kv)jobstates} JOB-TEXTS:${(kv)jobtexts}; }\nprecmd_functions+=(_proof_jobs)\n"
        if case == "absolute-ssh":
            startup += "ssh() { return 0; }\n"
        (user / ".zshrc").write_text(startup)
        master, slave = pty.openpty()
        name = f"mouse-{os.getpid()}-{case}"
        process = subprocess.Popen(
            [str(args.amx), "attach", name, "/bin/zsh", "-d", "-i"],
            stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
        )
        os.close(slave)
        captured = bytearray()
        try:
            captured.extend(read_until(master, b"\x1b[H"))
            os.write(master, b"\r")
            captured.extend(read_until(master, b"PROOF> "))
            captured.extend(drain(master))
            if case == "reattach-tui":
                subprocess.run([str(args.amx), "detach"], env={**env, "ZMX_SESSION": name}, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                process.wait(timeout=5)
                os.close(master)
                master, slave = pty.openpty()
                process = subprocess.Popen(
                    [str(args.amx), "attach", "--existing", name],
                    stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
                )
                os.close(slave)
                captured.extend(read_until(master, b"\x1b[H"))
                os.write(master, b"\r")
                captured.extend(read_until(master, b"PROOF> ") + drain(master))
            if case == "unrelated-stopped":
                os.write(master, b"sleep 60 & kill -STOP $!; sleep 0.1\r")
                captured.extend(read_until(master, b"PROOF> ") + drain(master))
            if case in ("ssh-exit", "next-tui", "reattach-tui", "absolute-ssh", "unrelated-stopped"):
                os.write(master, ((remote_enable.replace("ssh ", "/usr/bin/ssh ", 1) if case == "absolute-ssh" else remote_enable) + "\r").encode())
                output = read_until(master, b"\x1b[?1006hREMOTE-DIED") + drain(master)
                if b"PROOF> " not in output:
                    output += read_until(master, b"PROOF> ") + drain(master)
                captured.extend(output)
                assert RESET in output, "SSH prompt did not emit canonical mouse cleanup"
            if case in ("hook-chain", "ssh-failure"):
                command = "false" if case == "hook-chain" else ssh + " 'exit 7'"
                os.write(master, (command + "\r").encode())
                output = read_until(master, b"PROOF> ") + drain(master)
                captured.extend(output)
                assert b"LATER-PREEXEC\r\n" in output, "later preexec hook was skipped"
                status = b"1" if case == "hook-chain" else b"7"
                assert b"LATER-PRECMD:" + status + b"\r\n" in output, "later precmd hook was skipped or lost command status"
            elif case in ("ssh-exit", "absolute-ssh", "unrelated-stopped"):
                os.write(master, REPORT)
                time.sleep(0.1)
                os.write(master, b"\r")
                output = drain(master)
                captured.extend(output)
                assert b"command not found: 35" not in output, "reports reached local shell"
                if case == "unrelated-stopped":
                    os.write(master, b"kill -KILL %1\r")
                    captured.extend(read_until(master, b"PROOF> ") + drain(master))
            elif case == "ordinary-command":
                os.write(master, b"printf 'ORDINARY-DONE:%s\\n' ${AWESOMUX_SSH_MOUSE_RECOVERY-unset}\r")
                output = read_until(master, b"ORDINARY-DONE:unset\r\n") + drain(master)
                captured.extend(output)
                assert RESET not in output, "ordinary command reset mouse modes"
            else:
                command = remote_tui if case in ("remote-tui", "suspended-ssh") else local_command
                if case == "nested-tui":
                    command = "/bin/zsh -d -i -c " + shlex.quote(local_command)
                if case == "compound-tui":
                    command = remote_enable + "; " + local_command
                os.write(master, (command + "\r").encode())
                output = read_until(master, b"\x1b[?1006hTUI-READY\r\n")
                captured.extend(output)
                assert RESET not in output, "active TUI received mouse cleanup"
                if case == "suspended-ssh":
                    os.write(master, b"\r~\x1a")
                    output = read_until(master, b"PROOF> ") + drain(master)
                    captured.extend(output)
                    assert RESET not in output, "stopped SSH lost its live TUI mouse modes"
                    os.write(master, b"fg\r")
                    captured.extend(drain(master))
                os.write(master, REPORT)
                output = read_until(master, b"TUI-GOT:" + REPORT.hex().encode()) + drain(master)
                if case == "suspended-ssh":
                    if b"PROOF> " not in output:
                        output += read_until(master, b"PROOF> ") + drain(master)
                    assert RESET in output, "resumed SSH exit did not restore local mouse modes"
                    # A later unrelated stopped job may reuse the old SSH job ID.
                    os.write(master, b"sleep 60 & kill -STOP $!; sleep 0.1\r")
                    captured.extend(output + read_until(master, b"PROOF> ") + drain(master))
                    os.write(master, (remote_enable + "\r").encode())
                    output = read_until(master, b"\x1b[?1006hREMOTE-DIED") + drain(master)
                    if b"PROOF> " not in output:
                        output += read_until(master, b"PROOF> ") + drain(master)
                    assert RESET in output, "reused unrelated job ID suppressed SSH exit cleanup"
                    os.write(master, b"kill -KILL %1\r")
                    captured.extend(output + read_until(master, b"PROOF> ") + drain(master))
                else:
                    captured.extend(output)
            results.append(f"PASS {case}")
        finally:
            (args.output / f"{case}.txt").write_text(
                captured.replace(b"\x1b", b"<ESC>").decode("utf-8", "backslashreplace")
            )
            subprocess.run(
                [str(args.amx), "kill", name, "--force"], env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            process.wait(timeout=5)
            os.close(master)
    (args.output / "report.txt").write_text("\n".join(results) + "\n")
    print("\n".join(results))
    print(f"Artifacts: {args.output}")


if __name__ == "__main__":
    main()
