# md2pdf

日本語・数式・図表を含むMarkdownを、A4・ページ番号付きのPDFに変換するApple Silicon搭載Mac専用CLIです。
Intel Macには対応していません。
ヒラギノを使った日本語の組版と、KaTeXによる数式の描画に対応します。

本体はRust製です。利用者側でRust、Cargo、Node.js、Homebrewをインストールする必要はありません。
ビルド済み本体と専用Chromiumをインストーラーが取得します。

## インストール

> 現在は初期実装です。以下の通常インストールには、管理者によるGitHub Releaseの作成が必要です。
> 公開前に手元で試す手順は「開発・ローカル検証」を参照してください。

`公開済みのGitHub Releaseがありません` と表示される場合、通常の自動ダウンロードはまだ利用できません。
手元に作成済みの配布ファイルがある場合は `./install.sh --archive dist/配布ファイル名.tar.gz` で設置できます。

GitHubの「Code → Download ZIP」でリポジトリを取得して展開し、そのフォルダで実行します。

```sh
./install.sh
```

Gitがある場合は、次の方法でも取得できます。

```sh
git clone https://github.com/Iwabuchi-Akira/md2pdf.git
cd md2pdf
./install.sh
```

Apple Silicon搭載Macであることを確認し、GitHub Releasesから本体を取得します。
本体と専用ChromiumのSHA256を検証してから設置します。ブラウザのダウンロードは約100MBです。
専用ブラウザは普段使うChromeとは別に管理し、PDFの再現性のためバージョンを固定します。

標準の配置先：

```text
~/.local/bin/md2pdf                 コマンド
~/.local/share/md2pdf/              本体・バージョン情報・ライセンス
~/.local/share/md2pdf/browser/      専用Chromium
```

管理者権限は不要です。`~/.local/bin` がPATHにない場合は、シェルの設定ファイル
（macOS標準のzshなら `~/.zshrc`）に次を追加してください。

```sh
export PATH="$HOME/.local/bin:$PATH"
```

既存の同名コマンドや参考元のインストールは自動で置き換えません。
別の保存先は `--prefix DIR`、コマンドと本体の保存先を個別に選ぶ場合は
`--bin-dir DIR --data-dir DIR` を指定できます。
意図的な移行時のみ `--force` を指定してください。別の場所にある旧コマンドは残るので、PATHの順序も確認してください。

## 使い方

```sh
md2pdf memo.md
md2pdf "日本語 メモ.md" -o "提出用.pdf"
md2pdf notes/a.md notes/b.md
md2pdf --help
md2pdf --version
```

標準では入力と同じフォルダに、拡張子を `.pdf` に変えて保存します。同名のPDFは上書きします。
入力のMarkdownと画像は変更しません。`-o` / `--output` は1ファイルのときだけ指定できます。
相対パスは実行中のフォルダが基準です。オプションのようなファイル名は `md2pdf -- -memo.md` で指定できます。

対応内容：

- 見出し、段落、箇条書き、表、コード、リンク、日本語、ローカル・リモート画像。
- KaTeXの数式：`\(...\)`、`\[...\]`、`$...$`、`$$...$$`。
- 入力Markdownの場所を基準とする相対画像パス。
- 同時に変換するMarkdown同士のリンクを、出力PDFへのリンクに変更。

生のHTMLは文字として表示します。Mermaid、Vue部品、独自LaTeXパッケージは対象外です。
ローカルの文章と画像だけなら、初回インストール後はネット接続なしで変換できます。
リモート画像を含む場合は読み込みにネット接続が必要です。

## PDFのデザイン

デザインは同梱の `assets/print.css` で定義しています。A4、四辺18mmの余白、本文10pt、行間1.75、
中央下部のページ番号を使用し、長い数式は本文幅に収まるように縮小します。
Markdown-it 14.3.3、KaTeX 0.19.1、Chromium 151.0.7922.34を使用しています。

macOSのヒラギノを優先します。OS・フォントのバージョンが違う環境での完全な画素一致は保証しません。
PDFの生成日時などの内部情報も変わるため、互換性はページ数・描画画像で確認します。
日本語・数式・表・コード・SVG画像・リンクを含む検証用文書を `tests/fixtures/` に収録しています。

## 更新と削除

更新時は新しいリポジトリを取得し、もう一度 `./install.sh` を実行します。
特定バージョンは `./install.sh --version v0.1.0` のように指定します。
専用Chromiumは必要なバージョンが準備済みなら再ダウンロードしません。

コマンドからアンインストールできます。削除前に対象だけ確認することもできます。

```sh
md2pdf uninstall --dry-run
md2pdf uninstall
```

設置したコマンド、本体、ライセンス・管理情報、専用Chromium（全バージョンとキャッシュ）、
変換用の一時ファイルを削除します。カスタム設置先と、更新前に設置したコマンドの場所も記録して削除します。
変換用一時ファイルは専用の設置先内で管理し、途中終了で残った分もアンインストールの対象にします。

入力Markdown、生成したPDF、ダウンロードしたリポジトリや配布アーカイブは利用者のファイルとして残します。
専用フォルダに別のファイルを置いた場合も、それは削除しません。PATHを手動で設定した場合、
共有のPATH設定や親フォルダは変更しません。

## 開発・ローカル検証

開発する側にはRustが必要です。利用者のPCでビルドする必要はありません。

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
./scripts/test-install.sh
./scripts/test-release-resolution.sh
cargo build --release --locked --target aarch64-apple-darwin
./scripts/package-release.sh aarch64-apple-darwin
./scripts/test-uninstall.sh target/aarch64-apple-darwin/release/md2pdf
```

初回のダウンロードから含めて手元の配布ファイルを試す場合：

```sh
./install.sh \
  --archive dist/md2pdf-v0.1.0-aarch64-apple-darwin.tar.gz \
  --prefix "$PWD/tmp/local-install"
./tmp/local-install/bin/md2pdf tests/fixtures/sample.md -o tmp/sample.pdf
```

既存の `md2pdf` がPATHにある場合、この隔離した保存先への検証インストールでも停止します。
保存先を確認した上で `--force` を追加すると、旧コマンドは変更せずに別の場所へ設置できます。

本体を直接実行する場合は、`MD2PDF_DATA_DIR` で専用ブラウザの保存先を指定できます。
`MD2PDF_BROWSER_PATH` は開発時だけ、既知のChromium実行ファイルを指定するための設定です。

```sh
MD2PDF_DATA_DIR="$PWD/tmp/dev-data" ./target/aarch64-apple-darwin/release/md2pdf setup
MD2PDF_DATA_DIR="$PWD/tmp/dev-data" ./target/aarch64-apple-darwin/release/md2pdf memo.md
```

参考元との比較には、開発時のみNode.js、参考元の依存パッケージ、Popplerを使います。
次のスクリプトはHTMLと、両ツールが出力したPDFの全ページの画素を96 DPIで比較します。

```sh
MD2PDF_BROWSER_PATH="/専用Chromiumの実行ファイル" \
  node scripts/compare-reference.cjs /参考元のmd2pdf \
  target/aarch64-apple-darwin/release/md2pdf
```

インストール済み本体のエラー処理を検証する場合：

```sh
node scripts/test-conversion.cjs tmp/local-install/bin/md2pdf
```

日本語・空白入りの相対パス、入れ子の出力先、不正数式・画像読込失敗時の既存PDF保持を確認します。

## 配布する側の手順

`Cargo.toml` のバージョンと同じ `vVERSION` タグをGitHubへpushすると、
GitHub ActionsがApple Silicon版をビルドして、チェックサム付きのGitHub Releaseを作成します。
ワークフローを手動実行した場合はビルド確認だけを行い、Releaseは公開しません。
実行ファイルをGit履歴へ入れる必要はありません。

描画ライブラリは `assets/vendor/` に収録し、実行ファイルに埋め込みます。
出典とライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。
ブラウザを更新するときは `assets/browser.json` のURL・実際に取得したZIPのSHA256を更新し、
参考元との描画比較をやり直してください。
