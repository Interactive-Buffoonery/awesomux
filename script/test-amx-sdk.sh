#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="amx-sdk-tests-") as temporary:
    root = Path(temporary)
    (root / "script").mkdir()
    shutil.copy2(source / "script/build_amx.sh", root / "script/build_amx.sh")
    (root / "vendor/zmx/.git").mkdir(parents=True)
    (root / "vendor/zmx/build.zig.zon").write_text('.minimum_zig_version = "0.16.0",\n')
    (root / "vendor/zmx/zig-out/bin").mkdir(parents=True)
    binary = root / "vendor/zmx/zig-out/bin/zmx"
    binary.write_text('#!/bin/sh\necho test-version\n')
    binary.chmod(0o755)
    tools = root / "tools"
    tools.mkdir()
    scripts = {
        "git": '#!/bin/sh\nexit 1\n',
        "uname": '#!/bin/sh\necho "$TEST_OS"\n',
        "xcrun": '''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_XCRUN_LOG"
case "$*" in
  *--show-sdk-version) echo "$TEST_SDK_VERSION" ;;
  *--show-sdk-path) echo "$TEST_SDK_PATH" ;;
  *) exit 2 ;;
esac
''',
        "zig": '''#!/bin/sh
if [ "$1" = version ]; then echo "$TEST_ZIG_VERSION"; exit 0; fi
printf '%s\\n' "${ZIG_LIBC-}" > "$TEST_ZIG_LOG"
''',
    }
    for name, content in scripts.items():
        path = tools / name
        path.write_text(content)
        path.chmod(0o755)
    cases = [
        ("build", "Darwin", "27.0", "0.16.0", None, True, True),
        ("test", "Darwin", "27.0", "0.16.0", None, True, True),
        ("test", "Darwin", "27.0", "0.16.0", "/explicit/libc.txt", False, False),
        ("test", "Linux", "27.0", "0.16.0", None, False, False),
        ("test", "Darwin", "26.5", "0.16.0", None, False, True),
        ("test", "Darwin", "27.0", "0.17.0", None, False, False),
    ]
    # Revisit SDK 27 through another developer directory, then the first one.
    cases.extend([cases[1], cases[1]])
    generated_configs = {}
    for index, (action, platform, sdk, zig, override, generated, queries_sdk) in enumerate(cases):
        sdk_path = "/other SDK/MacOSX.sdk" if index == 6 else "/selected SDK/MacOSX.sdk"
        # Match the fake package requirement so selection accepts either minor.
        (root / "vendor/zmx/build.zig.zon").write_text(f'.minimum_zig_version = "{zig}",\n')
        env = dict(os.environ)
        env.pop("ZIG_LIBC", None)
        env.update(PATH=f"{tools}:{env['PATH']}", AWESOMUX_ZMX_ZIG=str(tools / "zig"),
                   TEST_OS=platform, TEST_SDK_VERSION=sdk, TEST_ZIG_VERSION=zig, TEST_SDK_PATH=sdk_path,
                   TEST_ZIG_LOG=str(root / f"zig-{index}.log"),
                   TEST_XCRUN_LOG=str(root / f"xcrun-{index}.log"))
        if override:
            env["ZIG_LIBC"] = override
        subprocess.run(["bash", str(root / "script/build_amx.sh"), action], env=env,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        actual = Path(env["TEST_ZIG_LOG"]).read_text().strip()
        sdk_key = hashlib.sha256(sdk_path.encode()).hexdigest()
        expected = str(root / f".build/amx/sdk-libc-{sdk_key}.txt") if generated else (override or "")
        assert actual == expected, (index, actual, expected)
        assert Path(env["TEST_XCRUN_LOG"]).exists() == queries_sdk, index
        if generated:
            assert Path(actual).read_text() == (
                f"include_dir={root}/script/amx-sdk-compat\n"
                f"sys_include_dir={sdk_path}/usr/include\n"
                "crt_dir=\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n")
            generated_configs.setdefault(actual, Path(actual).read_text())
        for config, contents in generated_configs.items():
            assert Path(config).read_text() == contents, config
        assert not list((root / ".build/amx").glob(".sdk-libc.*")), index
    assert len(generated_configs) == 2
    print(f"Passed {len(cases)} amx SDK wrapper cases")
PY
