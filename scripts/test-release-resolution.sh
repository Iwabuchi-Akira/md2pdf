#!/bin/sh
# Exercise GitHub redirects without network access or a user installation.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/md2pdf-release-test.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/mock-bin" "$work/source" "$work/assets"
case "$(uname -m)" in arm64|aarch64) target=aarch64-apple-darwin ;; *) target=x86_64-apple-darwin ;; esac
cat > "$work/source/md2pdf" <<'EOF'
#!/bin/sh
case "${1:-}" in
  setup) mkdir -p "$MD2PDF_DATA_DIR/browser" ;;
  __install-record) printf '{}\n' ;;
esac
EOF
chmod +x "$work/source/md2pdf"
printf '{}\n' > "$work/source/browser.json"
archive=md2pdf-v0.1.0-$target.tar.gz
COPYFILE_DISABLE=1 tar -czf "$work/assets/$archive" -C "$work/source" md2pdf browser.json
(cd "$work/assets" && shasum -a 256 "$archive" > SHA256SUMS)
cat > "$work/mock-bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=
while [ "$#" -gt 0 ]; do
  case "$1" in --output) output=$2; shift 2 ;; *) url=$1; shift ;; esac
done
case "$url" in
  */releases/latest)
    case "$MOCK_RELEASE" in
      unpublished) printf 'https://github.com/Iwabuchi-Akira/md2pdf/releases' ;;
      login) printf 'https://github.com/login' ;;
      network) exit 22 ;;
      published) printf 'https://github.com/Iwabuchi-Akira/md2pdf/releases/tag/v0.1.0' ;;
    esac
    ;;
  */releases/download/v0.1.0/*) cp "$MOCK_ASSETS/${url##*/}" "$output" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/mock-bin/curl"
PATH=$work/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin
MOCK_ASSETS=$work/assets
export PATH MOCK_ASSETS
for scenario in unpublished login network; do
  if MOCK_RELEASE=$scenario ./install.sh --prefix "$work/$scenario" > "$work/$scenario.log" 2>&1; then
    printf 'FAIL: invalid release resolution succeeded: %s\n' "$scenario" >&2; exit 1
  fi
  test ! -e "$work/$scenario"
  if grep -q 'バージョンは' "$work/$scenario.log"; then
    printf 'FAIL: release resolution reported an argument error\n' >&2; exit 1
  fi
done
grep -q '公開済みのGitHub Releaseがありません' "$work/unpublished.log"
grep -q '転送先を確認できません' "$work/login.log"
grep -q 'リリースを取得できません' "$work/network.log"
MOCK_RELEASE=published ./install.sh --prefix "$work/published" > "$work/published.log"
test -L "$work/published/bin/md2pdf"
MOCK_RELEASE=unpublished ./install.sh --version v0.1.0 --prefix "$work/explicit" > "$work/explicit.log"
test -L "$work/explicit/bin/md2pdf"
printf 'Release resolution checks passed.\n'
