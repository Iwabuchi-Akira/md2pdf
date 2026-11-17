#!/bin/sh
# Test the actual installed binary without touching the user's installation.
set -eu
cd "$(dirname "$0")/.."
binary=${1:-target/aarch64-apple-darwin/release/md2pdf}
case "$binary" in /*) : ;; *) binary=$PWD/$binary ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/md2pdf-uninstall-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/source" "$work/archive" "$work/data/browser/151.0.7922.34"
printf 'md2pdf installer\n' > "$work/data/.md2pdf-install"
cp "$binary" "$work/source/md2pdf"
cp assets/browser.json "$work/source/browser.json"
case "$(uname -m)" in
  arm64|aarch64) target=aarch64-apple-darwin; bundle=chrome-headless-shell-mac-arm64 ;;
  *) target=x86_64-apple-darwin; bundle=chrome-headless-shell-mac-x64 ;;
esac
# A version-only stub avoids networking; conversion itself is tested separately.
mkdir -p "$work/data/browser/151.0.7922.34/$bundle"
printf '#!/bin/sh\necho "Chromium 151.0.7922.34"\n' > "$work/data/browser/151.0.7922.34/$bundle/chrome-headless-shell"
chmod +x "$work/data/browser/151.0.7922.34/$bundle/chrome-headless-shell"
archive=$work/archive/md2pdf-v0.1.0-$target.tar.gz
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work/source" md2pdf browser.json
(cd "$work/archive" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

./install.sh --archive "$archive" --bin-dir "$work/first bin" --data-dir "$work/data" > /dev/null
# Upgrading with a different command directory must remember the first link.
./install.sh --archive "$archive" --bin-dir "$work/second bin" --data-dir "$work/data" > /dev/null
mkdir -p "$work/data/tmp/crashed-run" "$work/data/browser/old-version"
printf 'cache\n' > "$work/data/browser/old-version/cache"
printf 'temporary\n' > "$work/data/tmp/crashed-run/page.html"
printf 'keep\n' > "$work/report.pdf"
# Ignore malicious/unrelated environment overrides when choosing uninstall root.
MD2PDF_DATA_DIR="$work" "$work/second bin/md2pdf" uninstall --dry-run > "$work/preview"
test -x "$work/first bin/md2pdf"
test -x "$work/second bin/md2pdf"
test -d "$work/data/browser/old-version"
MD2PDF_DATA_DIR="$work" "$work/second bin/md2pdf" uninstall > "$work/removal"
test ! -e "$work/data"
test ! -L "$work/first bin/md2pdf"
test ! -L "$work/second bin/md2pdf"
test -f "$work/report.pdf"

# Migrate the original installer's plain marker; discover its command on PATH.
mkdir -p "$work/legacy" "$work/legacy-bin"
cp "$binary" "$work/legacy/md2pdf"
cp assets/browser.json "$work/legacy/browser.json"
printf 'md2pdf installer\n' > "$work/legacy/.md2pdf-install"
ln -s "$work/legacy/md2pdf" "$work/legacy-bin/md2pdf"
PATH="$work/legacy-bin:$PATH" "$work/legacy-bin/md2pdf" uninstall > /dev/null
test ! -e "$work/legacy"
test ! -L "$work/legacy-bin/md2pdf"
printf 'Uninstaller integration checks passed.\n'
