#!/usr/bin/env bash
# Rebuild the native macOS Steam client tree from Valve's CDN, reproducibly.
#
#   tools/fetch-client.sh <client-out-dir> [packages-cache-dir]
#
# Reads tools/client-packages.txt, downloads each package from
# https://client-update.steamstatic.com/<file>, verifies its SHA-256 against the
# manifest, and unzips it into <client-out-dir>. Downloads are cached (and hash-checked)
# in [packages-cache-dir] (default: <client-out-dir>/../.pkgcache) so re-runs and CI
# caching skip the ~270 MB fetch. This is how CI gets the client without the repo
# carrying Valve's binaries: the repo carries only the hashes.
#
# Needs: bash, curl, unzip, and a sha256 tool (sha256sum or shasum -a 256). All present
# on GitHub Actions macOS runners and in Git Bash on Windows.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/client-packages.txt"
out="${1:?usage: fetch-client.sh <client-out-dir> [packages-cache-dir]}"
cache="${2:-$out/../.pkgcache}"
cdn="https://client-update.steamstatic.com"

mkdir -p "$out" "$cache"

# Pick a sha256 implementation.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

while read -r name file want || [ -n "$name" ]; do
  case "$name" in ''|'#'*) continue;; esac
  dst="$cache/$file"

  if [ -f "$dst" ] && [ "$(sha256 "$dst")" = "$want" ]; then
    echo "cached   $name ($file)"
  else
    echo "download $name ($file)"
    curl -fL --retry 3 --retry-delay 2 -o "$dst" "$cdn/$file"
    got="$(sha256 "$dst")"
    if [ "$got" != "$want" ]; then
      echo "ERROR: $file sha256 mismatch" >&2
      echo "  want $want" >&2
      echo "  got  $got" >&2
      exit 1
    fi
    echo "verified $name"
  fi

  unzip -o -q "$dst" -d "$out"
done < "$manifest"

# Valve's CDN zips are built on Windows and store some paths with backslashes (seen in
# webkit_osx: "Frameworks\Chromium Embedded Framework.framework\..."). Info-ZIP's unzip on
# a Mac keeps those as literal filename characters, so each entry lands at the top level
# under one long backslashed name instead of nesting. Rebuild every such entry as a real
# nested path. Three kinds: files move; symlinks (the framework's Versions/Current and
# top-level links) are recreated with their target's backslashes fixed too, since a
# relative link only resolves from its proper place; directory entries merge into the
# nested directory. (On Windows, \ is a separator, so none of this triggers there.)
fixup_backslashes() {
  find "$out" -depth -name '*\\*' -print 2>/dev/null | while IFS= read -r p; do
    rel="${p#$out/}"
    fixed="${rel//\\//}"
    [ "$rel" = "$fixed" ] && continue
    tgt="$out/$fixed"
    mkdir -p "$(dirname "$tgt")"
    if [ -L "$p" ]; then
      link="$(readlink "$p")"
      ln -sfn "${link//\\//}" "$tgt"
      rm -f "$p"
    elif [ -d "$p" ]; then
      mkdir -p "$tgt"
      cp -a "$p"/. "$tgt"/ 2>/dev/null
      rm -rf "$p"
    else
      mv -f "$p" "$tgt"
    fi
  done
}
fixup_backslashes

echo "client ready in $out"
