#!/bin/sh
# Exercise installation without touching the user's home or downloading Chromium.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/md2pdf-installer-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/source" "$work/archives"
target=aarch64-apple-darwin
cat > "$work/source/md2pdf" <<'EOF'
#!/bin/sh
if [ "${1:-}" = __install-browser ]; then
  test -n "${MD2PDF_DATA_DIR:-}"
  test "${MOCK_SETUP_FAIL:-0}" = 0 || exit 1
  mkdir -p "$MD2PDF_DATA_DIR/browser/test-version"
  printf 'ready\n' > "$MD2PDF_DATA_DIR/browser/test-version/ready"
else
  printf 'md2pdf 0.1.0\n'
fi
EOF
chmod +x "$work/source/md2pdf"
cp uninstall.sh "$work/source/uninstall.sh"
printf '{}\n' > "$work/source/browser.json"
archive=$work/archives/md2pdf-v0.1.0-$target.tar.gz
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work/source" md2pdf browser.json uninstall.sh
(cd "$work/archives" && shasum -a 256 "$(basename "$archive")" > SHA256SUMS)
# Deliberately exclude the user's existing md2pdf command from PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
prefix=$work/install
./install.sh --prefix "$prefix" --archive "$archive" > "$work/install.log"
test -L "$prefix/bin/md2pdf"
test -x "$prefix/share/md2pdf/uninstall.sh"
test -f "$prefix/share/md2pdf/browser/test-version/ready"
test "$("$prefix/bin/md2pdf" --version)" = 'md2pdf 0.1.0'

# Managed install can be updated in place.
PATH=$prefix/bin:$PATH ./install.sh --prefix "$prefix" --archive "$archive" > /dev/null

# Failed browser setup must preserve the previously installed executable.
previous=$(shasum -a 256 "$prefix/share/md2pdf/md2pdf")
if MOCK_SETUP_FAIL=1 ./install.sh --prefix "$prefix" --archive "$archive" > /dev/null 2>&1; then
  printf 'FAIL: setup failure was ignored\n' >&2; exit 1
fi
test "$previous" = "$(shasum -a 256 "$prefix/share/md2pdf/md2pdf")"

# Unknown commands are never overwritten without --force.
mkdir -p "$work/conflict/bin"
printf 'keep me\n' > "$work/conflict/bin/md2pdf"
if ./install.sh --prefix "$work/conflict" --archive "$archive" > /dev/null 2>&1; then
  printf 'FAIL: existing command was overwritten\n' >&2; exit 1
fi
test "$(cat "$work/conflict/bin/md2pdf")" = 'keep me'
./install.sh --prefix "$work/conflict" --archive "$archive" --force > /dev/null

# Preserve unmanaged legacy data (the user's reference tool has this shape).
mkdir -p "$work/legacy/share/md2pdf"
printf 'legacy\n' > "$work/legacy/share/md2pdf/convert.cjs"
if ./install.sh --prefix "$work/legacy" --archive "$archive" > /dev/null 2>&1; then
  printf 'FAIL: unmanaged data directory was accepted\n' >&2; exit 1
fi
test ! -e "$work/legacy/share/md2pdf/.md2pdf-install"

# A command may not replace its own binary with a self-referencing symlink.
if ./install.sh --bin-dir "$work/same" --data-dir "$work/same" --archive "$archive" > /dev/null 2>&1; then
  printf 'FAIL: identical bin and data directories were accepted\n' >&2; exit 1
fi
test ! -e "$work/same"

# A checksum mismatch must fail before creating installation directories.
printf '\000' >> "$archive"
if ./install.sh --prefix "$work/tampered" --archive "$archive" > /dev/null 2>&1; then
  printf 'FAIL: tampered archive was accepted\n' >&2; exit 1
fi
test ! -e "$work/tampered"

# Reject Intel before downloads or installation directory creation.
mkdir -p "$work/mock-bin"
cat > "$work/mock-bin/uname" <<'EOF'
#!/bin/sh
case "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; *) exit 1 ;; esac
EOF
chmod +x "$work/mock-bin/uname"
if PATH="$work/mock-bin:$PATH" ./install.sh --prefix "$work/intel" > "$work/intel.log" 2>&1; then
  printf 'FAIL: Intel installation was accepted\n' >&2; exit 1
fi
grep -q 'Intel Macには対応していません' "$work/intel.log"
test ! -e "$work/intel"
printf 'Installer checks passed.\n'
