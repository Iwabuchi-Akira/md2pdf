#!/bin/sh
# Run after `cargo build --release --locked --target TARGET`.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { printf 'Usage: %s TARGET [OUTPUT_DIR]\n' "$0" >&2; exit 1; }
target=$1
case "$target" in aarch64-apple-darwin) : ;; *) printf 'Apple Silicon macOS only. Unsupported target: %s\n' "$target" >&2; exit 1 ;; esac
output=${2:-dist}
case "$output" in /*) : ;; *) output=$PWD/$output ;; esac
version=$(awk '/^\[package\]$/ { package = 1; next } /^\[/ { package = 0 } package && /^version[[:space:]]*=/ { gsub(/"/, "", $3); print $3; exit }' Cargo.toml)
[ -n "$version" ] || { printf 'Package version is missing.\n' >&2; exit 1; }
binary=target/$target/release/md2pdf
[ -x "$binary" ] || { printf 'Build first: cargo build --release --locked --target %s\n' "$target" >&2; exit 1; }
mkdir -p "$output"
stage=$(mktemp -d "${TMPDIR:-/tmp}/md2pdf-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cp "$binary" "$stage/md2pdf"
cp assets/browser.json "$stage/browser.json"
set -- md2pdf browser.json
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  if [ -f "$notice" ]; then cp "$notice" "$stage/$notice"; set -- "$@" "$notice"; fi
done
archive=md2pdf-v$version-$target.tar.gz
COPYFILE_DISABLE=1 tar -czf "$output/$archive" -C "$stage" "$@"
(cd "$output" && shasum -a 256 "$archive" > "$archive.sha256" && cat ./*.sha256 > SHA256SUMS)
printf '%s\n' "$output/$archive"
