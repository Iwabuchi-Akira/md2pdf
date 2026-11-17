#!/bin/sh
# Install a prebuilt md2pdf. Rust, Node.js, Homebrew and Git are not required.
set -eu

usage() {
  cat <<'EOF'
使い方: ./install.sh [オプション]
  --prefix DIR          設置先のルート (標準: ~/.local)
  --bin-dir DIR         コマンドの設置先 (標準: PREFIX/bin)
  --data-dir DIR        本体・専用ブラウザの設置先 (標準: PREFIX/share/md2pdf)
  --version VERSION     GitHub Releasesのバージョン (例: v0.1.0、標準: latest)
  --repository OWNER/REPO  配布元 (標準: Iwabuchi-Akira/md2pdf)
  --archive FILE        手元の配布用tar.gzを使う (隣のSHA256SUMSも必要)
  --checksum-file FILE  --archiveの検証用SHA256SUMSを指定
  --force               既存の同名コマンドの置き換えを許可
  -h, --help            この説明を表示
EOF
}

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 の値が必要です。"; }
absolute_path() {
  case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s/%s\n' "$PWD" "$1" ;; esac
}

prefix=${HOME:?HOMEが未設定です}/.local
bin_dir=
data_dir=
release_version=latest
repository=Iwabuchi-Akira/md2pdf
archive=
checksum_file=
force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) need_value "$@"; prefix=$2; shift 2 ;;
    --bin-dir) need_value "$@"; bin_dir=$2; shift 2 ;;
    --data-dir) need_value "$@"; data_dir=$2; shift 2 ;;
    --version) need_value "$@"; release_version=$2; shift 2 ;;
    --repository) need_value "$@"; repository=$2; shift 2 ;;
    --archive) need_value "$@"; archive=$2; shift 2 ;;
    --checksum-file) need_value "$@"; checksum_file=$2; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die 'このインストーラーはmacOS向けです。'
case "$(uname -m)" in
  arm64|aarch64) target=aarch64-apple-darwin ;;
  *) die 'Apple SiliconのmacOS（arm64）専用です。Intel Macには対応していません。' ;;
esac
prefix=$(absolute_path "$prefix")
bin_dir=$(absolute_path "${bin_dir:-$prefix/bin}")
data_dir=$(absolute_path "${data_dir:-$prefix/share/md2pdf}")
[ ! -L "$data_dir" ] || die '本体の設置先にシンボリックリンクは使えません。'
if [ -d "$bin_dir" ]; then bin_dir=$(cd "$bin_dir" && pwd -P); fi
if [ -d "$data_dir" ]; then data_dir=$(cd "$data_dir" && pwd -P); fi
command_path=$bin_dir/md2pdf
[ "$command_path" != "$data_dir/md2pdf" ] || die '--bin-dir と --data-dir は別のフォルダを指定してください。'
[ ! -d "$command_path" ] || die "$command_path はディレクトリです。"
if [ -d "$data_dir" ] && [ -n "$(ls -A "$data_dir")" ] && [ ! -f "$data_dir/.md2pdf-install" ] && [ "$force" -eq 0 ]; then
  die "$data_dir は既存の管理対象外フォルダです。別の --data-dir を指定するか、移行する場合は --force を指定してください。"
fi

# An owned symlink can be upgraded. Other commands require an explicit --force.
owned=0
if [ -L "$command_path" ] && [ "$(readlink "$command_path")" = "$data_dir/md2pdf" ]; then owned=1; fi
if { [ -e "$command_path" ] || [ -L "$command_path" ]; } && [ "$owned" -eq 0 ] && [ "$force" -eq 0 ]; then
  die "$command_path が既にあります。置き換える場合は --force を指定してください。"
fi
existing_command=$(command -v md2pdf 2>/dev/null || :)
if [ -n "$existing_command" ] && [ -d "$(dirname "$existing_command")" ]; then
  existing_command=$(cd "$(dirname "$existing_command")" && pwd -P)/$(basename "$existing_command")
fi
if [ -n "$existing_command" ] && [ "$existing_command" != "$command_path" ] && [ "$force" -eq 0 ]; then
  die "別のmd2pdfがPATHにあります: $existing_command。移行する場合は --force を指定してください。"
fi

for program in curl tar shasum mktemp; do
  command -v "$program" >/dev/null 2>&1 || die "macOS標準コマンドが見つかりません: $program"
done
work=$(mktemp -d "${TMPDIR:-/tmp}/md2pdf-install.XXXXXX")
stage=
link_stage=
cleanup() {
  rm -rf "$work"
  [ -z "$stage" ] || rm -rf "$stage"
  [ -z "$link_stage" ] || rm -f "$link_stage"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "$archive" ]; then
  archive=$(absolute_path "$archive")
  checksum_file=$(absolute_path "${checksum_file:-$(dirname "$archive")/SHA256SUMS}")
  [ -f "$archive" ] || die "配布ファイルが見つかりません: $archive"
  [ -f "$checksum_file" ] || die "チェックサムが見つかりません: $checksum_file"
else
  [ -z "$checksum_file" ] || die '--checksum-file は --archive と一緒に使ってください。'
  case "$repository" in
    *[!A-Za-z0-9_./-]*|/*|*/../*|*//*|*/|*/*/*) die '配布元は OWNER/REPO の形で指定してください。' ;;
    */*) : ;;
    *) die '配布元は OWNER/REPO の形で指定してください。' ;;
  esac
  if [ "$release_version" = latest ]; then
    printf '最新の公開バージョンを確認しています…\n'
    resolved_url=$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
      --connect-timeout 20 --max-time 60 \
      --output /dev/null --write-out '%{url_effective}' "https://github.com/$repository/releases/latest") ||
      die '公開済みのリリースを取得できませんでした。まだ未公開の場合は --archive でローカル配布ファイルを指定してください。'
    case "$resolved_url" in
      https://github.com/*/*/releases/tag/*)
        release_version=${resolved_url##*/}
        ;;
      https://github.com/*/*/releases|https://github.com/*/*/releases/)
        die '公開済みのGitHub Releaseがありません。公開前は --archive dist/md2pdf-vVERSION-CPU.tar.gz で手元の配布ファイルを指定してください。'
        ;;
      *) die "最新リリースの転送先を確認できません: $resolved_url" ;;
    esac
  fi
  case "$release_version" in v[0-9]*|[0-9]*) : ;; *) die 'バージョンは v0.1.0 のように指定してください。' ;; esac
  case "$release_version" in *[!A-Za-z0-9.+-]*) die 'バージョンに使えない文字が含まれています。' ;; esac
  case "$release_version" in v*) : ;; *) release_version=v$release_version ;; esac
  archive_name=md2pdf-$release_version-$target.tar.gz
  archive=$work/$archive_name
  checksum_file=$work/SHA256SUMS
  release_url=https://github.com/$repository/releases/download/$release_version
  printf 'md2pdf %s (%s) を取得しています…\n' "$release_version" "$target"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$archive" "$release_url/$archive_name" || die '本体を取得できませんでした。'
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --output "$checksum_file" "$release_url/SHA256SUMS" || die 'チェックサムを取得できませんでした。'
fi

archive_name=$(basename "$archive")
case "$archive_name" in
  md2pdf-v*-$target.tar.gz) : ;;
  *) die "このCPU用の配布ファイルを指定してください: md2pdf-vVERSION-$target.tar.gz" ;;
esac
expected=$(awk -v name="$archive_name" '$2 == name || $2 == "*" name { print $1 }' "$checksum_file")
case "$expected" in ''|*[!0-9a-fA-F]*) die '配布ファイルのSHA256チェックサムが見つからないか不正です。' ;; esac
[ "${#expected}" -eq 64 ] || die 'SHA256チェックサムの長さが不正です。'
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
[ "$(printf '%s' "$expected" | tr A-F a-f)" = "$actual" ] || die 'チェックサムが一致しません。設置を中止しました。'

# Only the flat files emitted by package-release.sh are accepted.
tar -tzf "$archive" > "$work/contents" || die '配布ファイルを読み込めません。'
while IFS= read -r entry; do
  case "$entry" in md2pdf|browser.json|LICENSE|THIRD_PARTY_NOTICES.md) : ;; *) die "配布ファイル内の不正なパス: $entry" ;; esac
done < "$work/contents"
tar -tvzf "$archive" | awk 'substr($0, 1, 1) != "-" { exit 1 }' || die '配布ファイルには通常のファイルだけを含めてください。'
mkdir "$work/unpack"
tar -xzf "$archive" -C "$work/unpack"
for required in md2pdf browser.json; do
  [ -f "$work/unpack/$required" ] && [ ! -L "$work/unpack/$required" ] || die "配布ファイルに $required がありません。"
done
[ -x "$work/unpack/md2pdf" ] || die '実行ファイルの実行権限がありません。'

mkdir -p "$bin_dir" "$data_dir"
# Resolve aliases such as /tmp and /private/tmp before creating the command.
bin_dir=$(cd "$bin_dir" && pwd -P)
data_dir=$(cd "$data_dir" && pwd -P)
command_path=$bin_dir/md2pdf
[ "$bin_dir" != "$data_dir" ] || die '--bin-dir と --data-dir は別のフォルダを指定してください。'
if [ ! -f "$data_dir/.md2pdf-install" ]; then
  printf 'md2pdf installer\n' > "$data_dir/.md2pdf-install"
fi
stage=$(mktemp -d "$data_dir/.install.XXXXXX")
cp "$work/unpack/"* "$stage/"
printf '専用ブラウザを準備しています…\n'
MD2PDF_DATA_DIR="$data_dir" "$stage/md2pdf" setup || die '専用ブラウザの準備に失敗しました。既存のコマンドは変更していません。'
MD2PDF_DATA_DIR="$data_dir" "$stage/md2pdf" __install-record "$command_path" > "$stage/.md2pdf-install" || die 'インストール記録を作成できませんでした。'

link_stage=$bin_dir/.md2pdf-link.$$
ln -s "$data_dir/md2pdf" "$link_stage"
mv -f "$stage/browser.json" "$data_dir/browser.json"
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  if [ -f "$stage/$notice" ]; then mv -f "$stage/$notice" "$data_dir/$notice"; fi
done
mv -f "$stage/md2pdf" "$data_dir/md2pdf"
mv -f "$stage/.md2pdf-install" "$data_dir/.md2pdf-install"
mv -f "$link_stage" "$command_path"
link_stage=

printf '\nインストールしました: %s\n' "$command_path"
case ":${PATH:-}:" in
  *":$bin_dir:"*) printf '使い方: md2pdf memo.md\n' ;;
  *)
    printf 'このフォルダをPATHに追加してください: %s\n' "$bin_dir"
    printf 'すぐ使う場合: "%s" memo.md\n' "$command_path"
    ;;
esac
if [ -n "$existing_command" ] && [ "$existing_command" != "$command_path" ]; then
  printf '以前のコマンドも残っています: %s\nPATHの順序を確認してください。\n' "$existing_command"
fi
