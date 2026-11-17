#!/bin/sh
# Use the installed binary's ownership records; no build tools are required.
set -eu

usage() {
  cat <<'EOF'
使い方: ./uninstall.sh [オプション]
  --dry-run       削除対象だけ表示
  --prefix DIR    インストール時の設置先ルート (標準: ~/.local)
  --data-dir DIR  インストール時の本体の設置先を指定
  -h, --help      この説明を表示

インストール先にあるuninstall.shは、その設置先を標準で削除します。
入力Markdown、生成PDF、取得したリポジトリは削除しません。
EOF
}

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 の値が必要です。"; }

prefix=
data_dir=
dry_run=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) need_value "$@"; prefix=$2; shift 2 ;;
    --data-dir) need_value "$@"; data_dir=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "不明なオプション: $1" ;;
  esac
done

if [ -z "$data_dir" ]; then
  script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
  if [ -n "$prefix" ]; then
    data_dir=$prefix/share/md2pdf
  elif [ -f "$script_dir/.md2pdf-install" ] && [ -f "$script_dir/browser.json" ]; then
    data_dir=$script_dir
  else
    data_dir=${HOME:?HOMEが未設定です}/.local/share/md2pdf
  fi
fi
case "$data_dir" in /*) : ;; *) data_dir=$PWD/$data_dir ;; esac

# Never let a symlinked binary redirect removal to a different installation.
[ ! -L "$data_dir" ] || die '本体の設置先にシンボリックリンクは使えません。'
if [ ! -e "$data_dir" ]; then
  printf 'md2pdfはインストールされていません: %s\n' "$data_dir"
  exit 0
fi
[ -d "$data_dir" ] && [ -f "$data_dir/.md2pdf-install" ] &&
  [ -f "$data_dir/browser.json" ] && [ -f "$data_dir/md2pdf" ] &&
  [ -x "$data_dir/md2pdf" ] && [ ! -L "$data_dir/md2pdf" ] ||
  die "管理対象のインストール先を確認できません: $data_dir"

set --
if [ "$dry_run" -eq 1 ]; then set -- --dry-run; fi
# exec lets the script and its installed binary safely remove themselves.
exec "$data_dir/md2pdf" __uninstall "$@"
