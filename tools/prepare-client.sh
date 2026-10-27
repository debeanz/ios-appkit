#!/usr/bin/env bash
# Reshape the macOS client tree into what the iOS app ships, in place:
#
#   tools/prepare-client.sh <client-dir>
#
# Run on the fetched client before routing (so lib-routes sees exactly the binaries that
# will ship) and again by package-ipa.sh on the bundled copy. Safe to run twice.
set -uo pipefail
root="${1:?usage: prepare-client.sh <client-dir>}"

# The macOS code signatures are void once the binaries are edited; the sideloader signs
# the whole app again.
find "$root" -type d -name _CodeSignature -prune -exec rm -rf {} +

# macOS frameworks are deep bundles (X.framework/Versions/A/... reached through symlinks);
# iOS frameworks are shallow. Collapse each one so its binary sits at X.framework/X — the
# path Steam loads CEF by — and give it a root Info.plist so a sideloader can sign it.
# retag-plan rewrites references into Versions/<v>/ to match.
find "$root" -type d -name '*.framework' -prune | while IFS= read -r fw; do
  [ -d "$fw/Versions" ] || continue
  ver="$fw/Versions/A"
  [ -d "$ver" ] || ver="$(find "$fw/Versions" -mindepth 1 -maxdepth 1 -type d ! -name Current | head -1)"
  [ -n "$ver" ] && [ -d "$ver" ] || continue
  # The top level only holds symlinks into Versions/ (or nothing, if they were lost).
  find "$fw" -mindepth 1 -maxdepth 1 ! -name Versions -exec rm -rf {} +
  mv "$ver"/* "$fw"/
  rm -rf "$fw/Versions"
  if [ -f "$fw/Resources/Info.plist" ] && [ ! -f "$fw/Info.plist" ]; then
    cp "$fw/Resources/Info.plist" "$fw/Info.plist"
  fi
  echo "  flattened ${fw#"$root"/}"
done

# Breakpad launches these helper programs after a crash; iOS can't launch processes, and
# Breakpad treats a missing Inspector as "crash reporting off" rather than failing.
rm -rf "$root/Frameworks/Breakpad.framework/Resources/crash_report_sender.app" \
       "$root/Frameworks/Breakpad.framework/Resources/Inspector"

# Steam's own switches (steam.cfg, read from the client directory) for a client that must
# never update itself or check its files: an update would replace the patched binaries with
# stock Mac ones. The host's launch flags say the same; this also covers the client's own
# updater.
cat > "$root/steam.cfg" <<'EOF'
BootStrapperInhibitAll=enable
BootStrapperInhibitUpdateOnLaunch=enable
BootStrapperInhibitClientChecksum=enable
BootStrapperInhibitBootstrapperChecksum=enable
EOF
