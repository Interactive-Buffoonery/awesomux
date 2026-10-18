#!/usr/bin/env python3
"""Synthetic shell receipts and foreground job; never controls the desktop."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["TL_FIXTURES"])
session = os.environ["ZMX_SESSION"]
identity = {
    "session": session, "shellPID": int(sys.argv[2]),
    "pane": os.environ["AWESOMUX_PANE_ID"],
    "workspace": os.environ["AWESOMUX_SESSION_ID"],
    "profile": os.environ["AWESOMUX_PROFILE"], "namespace": os.environ["ZMX_DIR"],
    "home": os.environ["HOME"], "fixedHome": os.environ["CFFIXED_USER_HOME"],
    "homeBeforeFixture": os.environ["TL_HOME_BEFORE_FIXTURE"],
    "startupZDOTDIR": os.environ["TL_ZDOTDIR_AT_FIXTURE"], "zdotdir": os.environ["ZDOTDIR"],
}

def write(name, value):
    temporary = root / (name + ".next")
    temporary.write_text(json.dumps(value))
    temporary.replace(root / name)

mode = sys.argv[1]
if mode == "register":
    write(session + ".json", identity)
elif mode == "respond":
    nonce = sys.argv[3]
    digest = hashlib.sha256((root.joinpath("secret").read_text() + nonce + session).encode()).hexdigest()
    line = "TL_RESPONSE_" + digest[:20]
    write("response-" + nonce + "-" + session + ".json", dict(identity, response=line))
    print(line, flush=True)
elif mode == "job":
    identity["jobPID"] = os.getpid()
    counter = 0
    while not root.joinpath("release").exists():
        write("job.json", dict(identity, heartbeat=counter))
        counter += 1
        time.sleep(0.1)
    write("job-finished.json", identity)
else:
    raise SystemExit("Unknown fixture command")
