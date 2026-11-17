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
cp uninstall.sh "$work/source/uninstall.sh"
target=aarch64-apple-darwin
bundle=chrome-headless-shell-mac-arm64
# A version-only stub avoids networking; conversion itself is tested separately.
mkdir -p "$work/data/browser/151.0.7922.34/$bundle"
printf '#!/bin/sh\necho "Chromium 151.0.7922.34"\n' > "$work/data/browser/151.0.7922.34/$bundle/chrome-headless-shell"
chmod +x "$work/data/browser/151.0.7922.34/$bundle/chrome-headless-shell"
archive=$work/archive/md2pdf-v0.1.0-$target.tar.gz
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work/source" md2pdf browser.json uninstall.sh
(cd "$work/archive" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
ZDOTDIR=$work/zsh
SHELL=/bin/zsh
export PATH ZDOTDIR SHELL
mkdir -p "$ZDOTDIR"
printf '# user configuration\nexport USER_SETTING=keep\n' > "$work/original-zshrc"
cp "$work/original-zshrc" "$ZDOTDIR/.zshrc"

./install.sh --archive "$archive" --bin-dir "$work/first bin" --data-dir "$work/data" > /dev/null
# Upgrading with a different command directory must remember the first link.
./install.sh --archive "$archive" --bin-dir "$work/second bin" --data-dir "$work/data" > /dev/null
test "$(grep -c '^# >>> md2pdf completion >>>' "$ZDOTDIR/.zshrc")" = 1
test -f "$work/data/completion.zsh"
test -x "$work/data/uninstall.sh"
cmp uninstall.sh "$work/data/uninstall.sh"
# Removed commands must not set up a browser or delete an installation.
"$work/second bin/md2pdf" --help > "$work/help"
if grep -Eq 'setup|uninstall|__install' "$work/help"; then
  printf 'FAIL: private operations are exposed in help\n' >&2; exit 1
fi
for removed in setup uninstall --uninstall; do
  if "$work/second bin/md2pdf" "$removed" > "$work/removed-command" 2>&1; then
    printf 'FAIL: removed command is still accepted: %s\n' "$removed" >&2; exit 1
  fi
done
# Also track a newly-created config file and remove it when it becomes empty.
ZDOTDIR="$work/new zsh" "$work/second bin/md2pdf" __install-completion > /dev/null
mkdir -p "$work/data/tmp/crashed-run" "$work/data/browser/old-version"
printf 'cache\n' > "$work/data/browser/old-version/cache"
printf 'temporary\n' > "$work/data/tmp/crashed-run/page.html"
printf 'keep\n' > "$work/report.pdf"
# Ignore malicious/unrelated environment overrides when choosing uninstall root.
MD2PDF_DATA_DIR="$work" ./uninstall.sh --data-dir "$work/data" --dry-run > "$work/preview"
grep -q 'uninstall.sh' "$work/preview"
test -x "$work/first bin/md2pdf"
test -x "$work/second bin/md2pdf"
test -d "$work/data/browser/old-version"
# Invalid arguments must fail before removing anything.
for invalid in '--unknown' '--data-dir' '--prefix'; do
  if ./uninstall.sh --data-dir "$work/data" "$invalid" > /dev/null 2>&1; then
    printf 'FAIL: invalid uninstall arguments accepted: %s\n' "$invalid" >&2; exit 1
  fi
done
test -x "$work/second bin/md2pdf"
# The installed script finds its own directory without PATH or the repository.
(cd "$work" && MD2PDF_DATA_DIR="$work" "$work/data/uninstall.sh") > "$work/removal"
test ! -e "$work/data"
test ! -L "$work/first bin/md2pdf"
test ! -L "$work/second bin/md2pdf"
test -f "$work/report.pdf"
cmp "$work/original-zshrc" "$ZDOTDIR/.zshrc"
test ! -e "$work/new zsh/.zshrc"

# Migrate the original installer's plain marker; discover its command on PATH.
legacy="$work/legacy prefix/share/md2pdf"
mkdir -p "$legacy" "$work/legacy-bin"
cp "$binary" "$legacy/md2pdf"
cp assets/browser.json "$legacy/browser.json"
printf 'md2pdf installer\n' > "$legacy/.md2pdf-install"
ln -s "$legacy/md2pdf" "$work/legacy-bin/md2pdf"
PATH="$work/legacy-bin:$PATH" ./uninstall.sh --prefix "$work/legacy prefix" > /dev/null
test ! -e "$legacy"
test ! -L "$work/legacy-bin/md2pdf"

# Missing installations are harmless; unmanaged directories and redirecting
# symlinks are rejected without touching their contents.
./uninstall.sh --data-dir "$work/data" > /dev/null
mkdir -p "$work/foreign"
printf 'keep\n' > "$work/foreign/personal.txt"
if ./uninstall.sh --data-dir "$work/foreign" > /dev/null 2>&1; then
  printf 'FAIL: unmanaged directory was accepted\n' >&2; exit 1
fi
ln -s "$work/foreign" "$work/alias"
if ./uninstall.sh --data-dir "$work/alias" > /dev/null 2>&1; then
  printf 'FAIL: symlinked data directory was accepted\n' >&2; exit 1
fi
cp assets/browser.json "$work/foreign/browser.json"
printf 'md2pdf installer\n' > "$work/foreign/.md2pdf-install"
ln -s "$binary" "$work/foreign/md2pdf"
if ./uninstall.sh --data-dir "$work/foreign" > /dev/null 2>&1; then
  printf 'FAIL: symlinked binary was accepted\n' >&2; exit 1
fi
test "$(cat "$work/foreign/personal.txt")" = keep
printf 'Uninstaller integration checks passed.\n'
