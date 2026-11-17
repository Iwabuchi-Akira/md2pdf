# zsh completion for md2pdf. Load after compinit.
_md2pdf_markdown_files() {
  _alternative \
    'markdown-files:Markdownファイル:_path_files -g "(#i)*.(md|markdown)"' \
    'directories:ディレクトリ:_path_files -/'
}
_md2pdf_pdf_files() {
  _alternative \
    'pdf-files:PDFファイル:_path_files -g "(#i)*.pdf"' \
    'directories:ディレクトリ:_path_files -/'
}
_md2pdf() {
  local context line
  local -A opt_args

  _arguments -S \
    '(-h --help)'{-h,--help}'[ヘルプを表示]' \
    '(-V --version)'{-V,--version}'[バージョンを表示]' \
    '(-o --output)'{-o,--output}'[保存先を指定]:PDFファイル:_md2pdf_pdf_files' \
    '*:Markdownファイル:_md2pdf_markdown_files'
}
compdef _md2pdf md2pdf
