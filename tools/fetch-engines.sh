#!/bin/bash
# Downloads (once, into the cache) and unpacks the engines tools/engines.txt lists.
#   bash tools/fetch-engines.sh <engines.txt> <cache-dir> <out-dir>
# A .dmg is mounted and copied, a .zip unpacked, a .pkg (Unity's installers) expanded with its
# payloads.
set -euo pipefail
list=$1 cache=$2 out=$3
mkdir -p "$cache" "$out"
grep -v '^#' "$list" | while read -r name url; do
  [ -n "${name:-}" ] || continue
  file="$cache/$name-$(basename "$url")"
  [ -s "$file" ] || curl -fsSL --retry 3 -o "$file" "$url"
  echo "$name: $(basename "$url") $(du -h "$file" | cut -f1) sha256 $(shasum -a 256 "$file" | cut -c1-16)"
  rm -rf "$out/$name"
  case "$file" in
    *.pkg) pkgutil --expand-full "$file" "$out/$name" ;;   # makes the folder itself
  esac
  mkdir -p "$out/$name"
  case "$file" in
    *.dmg)
      mnt=$(mktemp -d)
      hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$file" >/dev/null
      ditto "$mnt" "$out/$name"
      hdiutil detach "$mnt" >/dev/null
      ;;
    *.zip) ditto -x -k "$file" "$out/$name" ;;
    *.pkg) ;;
    *) echo "  don't know how to unpack $file" ;;
  esac
done
