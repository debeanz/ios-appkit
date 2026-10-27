#!/usr/bin/env bash
# Assemble the unsigned Steam.app IPA.
#
#   tools/package-ipa.sh <client-dir> <frameworks-dir> <host-binary> <out.ipa> [routes.json]
#
# Takes the reconstructed macOS client (fetch-client.sh), a directory holding the shim's
# built frameworks (make umbrella SDK=device: AppKitShim.framework, the umbrella Steam's
# load commands point at, and AppKitShimCore.framework, the code it re-exports; every
# *.framework there is embedded), and the built iOS host executable, and produces an unsigned
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
CLIENT="${1:?usage: package-ipa.sh <client-dir> <frameworks-dir> <host-binary> <out.ipa> [routes.json]}"
FW_DIR="${2:?missing frameworks dir}"
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

echo "=== Lay out Steam.app ==="
# Client payload under client/ (the app's own executable is named Steam), reshaped for iOS
# (flattened frameworks, no stale signatures or Breakpad helpers). CI already ran this on
# the fetched client before routing; running it again here is a no-op then.
cp -R "$CLIENT"/. "$app/client/"
bash "$here/prepare-client.sh" "$app/client"
# The iOS host executable is the bundle's main binary.
cp "$HOST" "$app/Steam"; chmod +x "$app/Steam"
cp "$repo/host/Info.plist" "$app/Info.plist"
# Embed the shim frameworks; every binary finds them through an @loader_path rpath here.
for fw in "$FW_DIR"/*.framework; do
  [ -d "$fw" ] && cp -R "$fw" "$app/Frameworks/" && echo "  embedded Frameworks/$(basename "$fw")"
done
[ -d "$app/Frameworks/AppKitShim.framework" ] || { echo "ERROR: no AppKitShim.framework in $FW_DIR"; exit 1; }
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

echo "=== Check every bundled dependency resolves ==="
node "$here/check-deps.js" "$app" || { echo "ERROR: a bundled dependency doesn't resolve (see above)"; exit 1; }

echo "=== Zip the unsigned IPA ==="
rm -f "$OUT"
# -y keeps any symlinks; run from $work so Payload/ is at the archive root.
( cd "$work" && zip -qry "$OUT" Payload )
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
rm -rf "$work"
