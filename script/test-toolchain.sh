#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/awesomux-toolchain-test.XXXXXX")"
cleanup() {
    local status=$?
    if command -v trash >/dev/null 2>&1; then
        trash "$FIXTURE"
    else
        for path in "$FIXTURE"/bin/* "$FIXTURE"/script/* "$FIXTURE"/.* "$FIXTURE"/result; do
            if [[ -f "$path" || -L "$path" ]]; then unlink "$path"; fi
        done
        rmdir "$FIXTURE/bin" "$FIXTURE/script" "$FIXTURE"
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$FIXTURE/script" "$FIXTURE/bin"
cp "$ROOT_DIR/script/check-toolchain.sh" "$FIXTURE/script/"
printf '6.3.3\n' > "$FIXTURE/.swift-version"
printf '6.4\n' > "$FIXTURE/.swift-version-macos"
printf '27.0\n' > "$FIXTURE/.xcode-version"
printf 'darwin=main\nlinux=6.3.3\n' > "$FIXTURE/.swift-format-version"
cat > "$FIXTURE/bin/tool" <<'EOF'
#!/usr/bin/env bash
case "$(basename "$0")" in
    uname) echo "$TEST_PLATFORM" ;;
    xcodebuild) printf 'Xcode %s\nBuild version 27A266a\n' "$TEST_XCODE" ;;
    xcrun)
        if [[ "$1" == swift ]]; then
            if [[ "${TEST_SELECTED_FAILURE:-0}" != 0 ]]; then
                echo 'selected compiler unavailable' >&2
                exit "$TEST_SELECTED_FAILURE"
            fi
            echo "Apple Swift version $TEST_SELECTED_SWIFT"
        else
            echo "$TEST_SDK"
        fi ;;
    swift)
        if [[ "$1" == format ]]; then
            echo "$TEST_FORMATTER"
        else
            if [[ "${TEST_PATH_FAILURE:-0}" != 0 ]]; then
                echo 'PATH compiler unavailable' >&2
                exit "$TEST_PATH_FAILURE"
            fi
            echo "Apple Swift version $TEST_SWIFT"
        fi ;;
esac
EOF
chmod +x "$FIXTURE/bin/tool"
for tool in uname xcodebuild xcrun swift; do
    ln -s tool "$FIXTURE/bin/$tool"
done
export PATH="$FIXTURE/bin:$PATH"
export TEST_PLATFORM=Darwin TEST_XCODE=27.0 TEST_SDK=27.0
export TEST_SWIFT=6.4 TEST_SELECTED_SWIFT=6.4 TEST_FORMATTER=main
unset TOOLCHAINS
check() { bash "$FIXTURE/script/check-toolchain.sh"; }
reject() {
    if check > "$FIXTURE/result" 2>&1; then
        echo "error: accepted mismatched toolchain: $*" >&2
        exit 1
    else
        local status=$?
    fi
    [[ "$status" -eq "${2:-1}" ]]
    grep -Fq "$1" "$FIXTURE/result"
}
check
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault check
TOOLCHAINS=org.swift.640 reject "require the default Xcode toolchain"
SWIFT_EXEC=/alternate/swiftc reject "unset SWIFT_EXEC and SWIFT_EXEC_MANIFEST"
SWIFT_EXEC_MANIFEST=/alternate/swiftc reject "unset SWIFT_EXEC and SWIFT_EXEC_MANIFEST"
TEST_XCODE=26.6 reject "Xcode 27.0"
TEST_SDK=26.4 reject "SDK is required"
TEST_SWIFT=6.3.3 reject "PATH Swift differs"
TEST_SELECTED_SWIFT=6.3.3 reject "PATH Swift differs"
TEST_SWIFT=6.3.3 TEST_SELECTED_SWIFT=6.3.3 reject "Swift 6.4 is required"
TEST_PATH_FAILURE=42 reject "PATH Swift version probe failed (exit 42)" 42
grep -Fxq 'PATH compiler unavailable' "$FIXTURE/result"
TEST_SELECTED_FAILURE=43 reject "selected Xcode Swift version probe failed (exit 43)" 43
grep -Fxq 'selected compiler unavailable' "$FIXTURE/result"
TEST_FORMATTER=6.3.0 reject "swift-format main"
TEST_PLATFORM=Linux TEST_SWIFT=6.3.3 TEST_FORMATTER=6.3.3 check
TEST_PLATFORM=Linux TEST_SWIFT=6.4 TEST_FORMATTER=6.3.3 reject "Swift 6.3.3 is required"
echo "Toolchain guard regression checks passed"
