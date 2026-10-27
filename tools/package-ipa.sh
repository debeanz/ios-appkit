#!/usr/bin/env bash
# Assemble the unsigned Steam.app IPA.
#
#   tools/package-ipa.sh <client-dir> <shim-framework-dir> <host-binary> <out.ipa> [routes.json]
#
# Takes the reconstructed macOS client (fetch-client.sh), the built AppKitShim.framework
# (make framework SDK=device), and the built iOS host executable, and produces an unsigned
# .ipa. The heavy lifting is the Mach-O surgery, driven by retag-plan.json (regenerated
# here from this exact client): every client binary is thinned to arm64, its platform
# retagged macOS->iOS, and every system load command rewritten — to its shallow iOS path,
# or to the bundled shim (routes.json from lib-routes.js decides which). The result is
# unsigned on purpose: the sideloader (LiveContainer/SideStore) signs it, and StikDebug can
# attach to enable JIT.
#
# Needs (all on GitHub Actions macOS runners): bash, jq, node, python3, and the cctools
# lipo / vtool / install_name_tool / codesign. Must run on macOS (the Mach-O tools are
# Apple's).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
CLIENT="${1:?usage: package-ipa.sh <client-dir> <shim-framework-dir> <host-binary> <out.ipa> [routes.json]}"
SHIM_FW="${2:?missing shim framework dir}"
HOST="${3:?missing host binary}"
OUT="${4:?missing out.ipa}"
ROUTES="${5:-}"

# Make OUT absolute now: the zip step runs inside a cd to $work, where a relative path
# would resolve to the wrong place (and get cleaned up).
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
work="$(mktemp -d)"
app="$work/Payload/Steam.app"
mkdir -p "$app/Frameworks" "$app/client"

# macOS frameworks are deep bundles (X.framework/Versions/A/... reached through symlinks);
# iOS frameworks are shallow. Collapse each one so its binary sits at X.framework/X — the
# path Steam loads CEF by — and give it a root Info.plist so a sideloader can sign it.
flatten_frameworks() {
  find "$1" -type d -name '*.framework' -prune | while IFS= read -r fw; do
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
    echo "  flattened ${fw#"$1"/}"
  done
}

echo "=== Lay out Steam.app ==="
# Client payload under client/ (the app's own executable is named Steam).
cp -R "$CLIENT"/. "$app/client/"
flatten_frameworks "$app/client"
# The iOS host executable is the bundle's main binary.
cp "$HOST" "$app/Steam"; chmod +x "$app/Steam"
cp "$repo/host/Info.plist" "$app/Info.plist"
# Embed the shim; every binary finds it through an @loader_path rpath to this directory.
cp -R "$SHIM_FW" "$app/Frameworks/AppKitShim.framework"
echo "laid out $(du -sh "$app" | cut -f1) in Steam.app"

echo "=== Plan the surgery (retag-plan over the bundled client) ==="
node "$here/retag-plan.js" "$app/client" "$work/plan.json" ${ROUTES:+"$ROUTES"} || { echo "retag-plan failed"; exit 1; }
nplan=$(jq '.binaries | length' "$work/plan.json" 2>/dev/null || echo 0)
echo "planned $nplan binaries${ROUTES:+ (routed by $(basename "$ROUTES"))}"
[ "$nplan" -gt 0 ] || { echo "ERROR: plan is empty — no binaries found under the bundled client"; exit 1; }

# Path from a binary's directory to the app's Frameworks dir, for its @loader_path rpath.
# @loader_path rather than @executable_path: under LiveContainer the process's executable
# is LiveContainer itself, so @executable_path would point into the wrong app.
rel_to_frameworks() {
  python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$app/Frameworks" "$1"
}

echo "=== Mach-O surgery ==="
dropped=0; thinned=0; retagged=0; rewrites=0; rewritefail=0; rpathfail=0; total=0
while read -r b; do
  f=$(jq -r '.file' <<<"$b")
  path="$app/client/$f"
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

  # Every load-command rewrite for this binary in one install_name_tool call (CEF is
  # ~200 MB; one call per rewrite would rewrite it dozens of times). If the batch fails,
  # redo them one by one so the log names the rewrite that broke.
  args=(); n=0
  while IFS=$'\t' read -r from to; do
    [ -z "$from" ] && continue
    args+=(-change "$from" "$to"); n=$((n+1))
  done < <(jq -r '.repoint[]? | [.from, .to] | @tsv' <<<"$b")
  if [ "$n" -gt 0 ]; then
    if install_name_tool "${args[@]}" "$path" 2>/dev/null; then
      rewrites=$((rewrites+n))
    else
      while IFS=$'\t' read -r from to; do
        [ -z "$from" ] && continue
        if install_name_tool -change "$from" "$to" "$path" 2>/tmp/int.err; then
          rewrites=$((rewrites+1))
        else
          rewritefail=$((rewritefail+1)); echo "  rewrite failed: $f: $from -> $to: $(tr '\n' ' ' </tmp/int.err)"
        fi
      done < <(jq -r '.repoint[]? | [.from, .to] | @tsv' <<<"$b")
    fi
  fi

  if ! install_name_tool -add_rpath "@loader_path/$(rel_to_frameworks "$(dirname "$path")")" "$path" 2>/tmp/int.err; then
    rpathfail=$((rpathfail+1)); echo "  add_rpath failed: $f: $(tr '\n' ' ' </tmp/int.err)"
  fi
done < <(jq -c '.binaries[]' "$work/plan.json")

echo "  binaries processed: $total"
echo "  dropped (x86-only): $dropped   thinned: $thinned   retagged: $retagged"
echo "  load commands rewritten: $rewrites   rewrite failures: $rewritefail   add_rpath failures: $rpathfail"

# The host sits at the app root, so its own Frameworks rpath is @loader_path/Frameworks.
install_name_tool -add_rpath "@loader_path/Frameworks" "$app/Steam" 2>/dev/null || true

echo "=== Zip the unsigned IPA ==="
rm -f "$OUT"
# -y keeps any symlinks; run from $work so Payload/ is at the archive root.
( cd "$work" && zip -qry "$OUT" Payload )
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
rm -rf "$work"
