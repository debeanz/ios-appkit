#!/bin/bash
# Full CI run: build for device and simulator, link and run the smoke test.
# Everything goes to stdout so the caller can tee it into build.log.
set -uo pipefail

step() { echo; echo "=== $* ==="; }
fail() { echo; echo "RESULT: FAIL at step: $1"; exit 1; }

step "Toolchain"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphonesimulator --show-sdk-version

step "Build device (arm64)"
make SDK=device || fail "build device"

step "Build simulator (arm64)"
make SDK=sim || fail "build simulator"

step "Link smoke test"
make test SDK=sim || fail "link smoke test"

step "Run smoke test on a simulator"
# Pick the newest available iPhone instead of hard-coding a model name.
DEVTYPE=$(xcrun simctl list devicetypes | grep -o 'com.apple.CoreSimulator.SimDeviceType.iPhone-[0-9A-Za-z-]*' | tail -1)
RUNTIME=$(xcrun simctl list runtimes available | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | tail -1)
echo "device type: $DEVTYPE"
echo "runtime:     $RUNTIME"
[ -n "$DEVTYPE" ] && [ -n "$RUNTIME" ] || fail "find simulator"
UDID=$(xcrun simctl create akshim-smoke "$DEVTYPE" "$RUNTIME") || fail "create simulator"
xcrun simctl boot "$UDID" || fail "boot simulator"
xcrun simctl spawn "$UDID" "$PWD/build/sim/smoke"
CODE=$?
xcrun simctl shutdown "$UDID" >/dev/null 2>&1
xcrun simctl delete "$UDID" >/dev/null 2>&1
[ $CODE -eq 0 ] || fail "smoke test exited $CODE"

echo
echo "RESULT: PASS"
