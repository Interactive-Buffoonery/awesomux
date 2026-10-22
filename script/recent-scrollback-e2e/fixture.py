#!/usr/bin/env python3
"""Emit finite synthetic history in the real terminal; not a native test runner."""

import argparse
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("ascii", "unicode"), default="ascii")
    parser.add_argument("--bytes", type=int, default=96 * 1024 * 1024)
    parser.add_argument("--idle-seconds", type=float, default=10)
    parser.add_argument("--follow-seconds", type=float, default=0)
    args = parser.parse_args()
    if not 0 <= args.bytes <= 128 * 1024 * 1024:
        parser.error("--bytes must be between 0 and 134217728")
    if not 0 <= args.idle_seconds <= 120 or not 0 <= args.follow_seconds <= 120:
        parser.error("durations must be between 0 and 120 seconds")

    output = sys.stdout.buffer
    output.write(b"\r\nAMX-582-OLDEST\r\n")
    payload = "0123456789abcdef" if args.kind == "ascii" else "e\u0301 \u4e2d\u6587 \U0001f469\u200d\U0001f4bb \U0001f1e8\U0001f1e6"
    emitted = 0
    index = 0
    while emitted < args.bytes:
        row = (f"AMX-582-{index:08d} {payload * 6}  \r\n").encode("utf-8")
        output.write(row)
        emitted += len(row)
        index += 1
    output.flush()
    time.sleep(args.idle_seconds)
    deadline = time.monotonic() + args.follow_seconds
    while time.monotonic() < deadline:
        output.write((f"AMX-582-LIVE-{index:08d} {payload}  \r\n").encode("utf-8"))
        output.flush()
        index += 1
        time.sleep(0.05)
    output.write((f"AMX-582-FINAL {payload}  \r\nAMX-582-EMITTED {emitted}\r\n").encode("utf-8"))
    output.flush()


if __name__ == "__main__":
    main()
