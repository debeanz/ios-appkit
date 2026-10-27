#!/usr/bin/env bash
# Assemble the unsigned Steam.app IPA.
#
#   tools/package-ipa.sh <client-dir> <shim-framework-dir> <host-binary> <out.ipa>
#
# Takes the reconstructed macOS client (fetch-client.sh), the built AppKitShim.framework
# (make framework SDK=device), and the built iOS host executable, and produces an unsigned
# .ipa. The heavy lifting is the Mach-O surgery, driven by retag-plan.json (regenerated
# here from this exact client): every client binary is thinned to arm64, its platform
# retagged macOS->iOS, and every load command for an iOS-missing framework repointed at the
# bundled shim. The result is unsigned on purpose — the sideloader (StikDebug/SideStore)
# signs it and adds the get-task-allow entitlement that lets StikDebug enable JIT.
#
# Needs (all on GitHub Actions macOS runners): bash, jq, node, and the cctools
# lipo / vtool / install_name_tool / codesign. Must run on macOS (the Mach-O tools are
# Apple's). Expected to need iteration: some binaries lack header padding for -add_rpath,
# which this logs rather than failing on.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
CLIENT="${1:?usage: package-ipa.sh <client-dir> <shim-framework-dir> <host-binary> <out.ipa>}"
SHIM_FW="${2:?missing shim framework dir}"
HOST="${3:?missing host binary}"
OUT="${4:?missing out.ipa}"

SHIM_INSTALL='@rpath/AppKitShim.framework/AppKitShim'
work="$(mktemp -d)"
app="$work/Payload/Steam.app"
mkdir -p "$app/Frameworks" "$app/client"

echo "=== Lay out Steam.app ==="
# Client payload under client/ (the app's own executable is named Steam).
cp -R "$CLIENT"/. "$app/client/"
# The iOS host executable is the bundle's main binary.
cp "$HOST" "$app/Steam"; chmod +x "$app/Steam"
cp "$repo/host/Info.plist" "$app/Info.plist"
# Embed the shim; @rpath resolves to here via @executable_path/Frameworks.
cp -R "$SHIM_FW" "$app/Frameworks/AppKitShim.framework"
echo "laid out $(du -sh "$app" | cut -f1) in Steam.app"

echo "=== Plan the surgery (retag-plan over the bundled client) ==="
node "$here/retag-plan.js" "$app/client" "$work/plan.json"

echo "=== Mach-O surgery ==="
dropped=0; thinned=0; retagged=0; repointed=0; rpathfail=0; total=0
while read -r b; do
  f=$(jq -r '.file' <<<"$b")
  path="$app/client/$f"
  # Only real files get listed, but guard against symlinks (shared framework binaries).
  [ -e "$path" ] || continue
  [ -L "$path" ] && continue
  total=$((total+1))

  if [ "$(jq -r '.drop // false' <<<"$b")" = "true" ]; then
    rm -f "$path"; dropped=$((dropped+1)); continue
  fi

  # Edits invalidate any signature; drop it (the sideloader resigns the whole app).
  codesign --remove-signature "$path" 2>/dev/null || true

  if [ "$(jq -r '.thin // false' <<<"$b")" = "true" ]; then
    if lipo "$path" -thin arm64 -output "$path.thin" 2>/dev/null; then
      mv "$path.thin" "$path"; thinned=$((thinned+1))
    fi
  fi

  if [ "$(jq -r '.retag // false' <<<"$b")" = "true" ]; then
    if vtool -set-build-version ios 15.0 15.0 -replace -output "$path" "$path" 2>/dev/null; then
      retagged=$((retagged+1))
    else
      echo "  vtool retag failed: $f"
    fi
  fi

  while read -r from; do
    [ -z "$from" ] && continue
    install_name_tool -change "$from" "$SHIM_INSTALL" "$path" 2>/dev/null && repointed=$((repointed+1)) || true
  done < <(jq -r '.repoint[]?.from' <<<"$b")

  # @rpath -> the app's Frameworks dir. @executable_path is the main exe's dir (app root)
  # for every image in the process, so one rpath covers dylibs at any depth.
  if ! install_name_tool -add_rpath "@executable_path/Frameworks" "$path" 2>/dev/null; then
    rpathfail=$((rpathfail+1))
  fi
done < <(jq -c '.binaries[]' "$work/plan.json")

echo "  binaries processed: $total"
echo "  dropped (x86-only): $dropped   thinned: $thinned   retagged: $retagged"
echo "  load commands repointed: $repointed   add_rpath failures: $rpathfail"

# The host itself is built for iOS already; make sure it too can find @rpath frameworks.
install_name_tool -add_rpath "@executable_path/Frameworks" "$app/Steam" 2>/dev/null || true

echo "=== Zip the unsigned IPA ==="
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# -y keeps symlinks (CEF framework relies on them); run from $work so Payload/ is at root.
( cd "$work" && zip -qry "$OUT" Payload )
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
rm -rf "$work"
