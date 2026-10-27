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

step "Build dynamic framework (device + simulator)"
make framework SDK=device || fail "build framework device"
make framework SDK=sim || fail "build framework simulator"

step "Verify the framework exports the macOS names CEF binds to"
# These are imported by the Steam binaries from macOS AppKit/CoreGraphics; the shim must
# export them under the exact macOS symbol names or the repointed load commands resolve
# to nothing. nm -gU lists defined external symbols.
EXPORTS=$(nm -gU build/device/AppKitShim.framework/AppKitShim 2>/dev/null)
missing=0
for sym in '_OBJC_CLASS_$_NSApplication' '_OBJC_CLASS_$_NSWindow' '_OBJC_CLASS_$_NSView' \
           '_OBJC_CLASS_$_NSEvent' '_NSApp' '_CGDisplayBounds' '_RegisterEventHotKey'; do
  if echo "$EXPORTS" | grep -q -- "$sym\$"; then
    echo "  export OK   $sym"
  else
    echo "  MISSING     $sym"; missing=1
  fi
done
echo "total exported symbols: $(echo "$EXPORTS" | grep -c .)"
[ $missing -eq 0 ] || fail "framework missing expected exports"

step "Link smoke test"
make test SDK=sim || fail "link smoke test"

step "Run smoke test on a simulator"
# Pick the newest iOS runtime and an iPhone that runtime actually supports, instead of
# guessing a model name (an old model fails with "Incompatible device").
read -r RUNTIME DEVTYPE < <(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
rts = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
rt = max(rts, key=lambda r: [int(x) for x in r["version"].split(".")])
phones = [d["identifier"] for d in rt.get("supportedDeviceTypes", []) if d.get("productFamily") == "iPhone"]
print(rt["identifier"], phones[-1] if phones else "")')
echo "device type: $DEVTYPE"
echo "runtime:     $RUNTIME"
[ -n "$DEVTYPE" ] && [ -n "$RUNTIME" ] || fail "find simulator"
UDID=$(xcrun simctl create akshim-smoke "$DEVTYPE" "$RUNTIME") || fail "create simulator"
xcrun simctl boot "$UDID" || fail "boot simulator"
xcrun simctl spawn "$UDID" "$PWD/build/sim/smoke"
CODE=$?

# Runtime cross-check of the SDK gap list (informational: never fails the build).
if [ -f ios-gap.json ]; then
  step "Runtime gap check"
  SIMSDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
  if xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator -isysroot "$SIMSDK" \
       -fobjc-arc -framework Foundation tools/runtime-gap.m -o build/sim/runtime-gap; then
    xcrun simctl spawn "$UDID" "$PWD/build/sim/runtime-gap" "$PWD/ios-gap.json" "$PWD/runtime-gap.json" || true
  fi
fi
xcrun simctl shutdown "$UDID" >/dev/null 2>&1
xcrun simctl delete "$UDID" >/dev/null 2>&1
[ $CODE -eq 0 ] || fail "smoke test exited $CODE"

echo
echo "RESULT: PASS"
