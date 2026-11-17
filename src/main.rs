mod browser;
mod cdp;
mod install;

use anyhow::{Context, Result, bail};
use base64::Engine;
use include_dir::{Dir, include_dir};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    env,
    ffi::OsString,
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
};
use url::Url;

static ASSETS: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/assets");

const USAGE: &str = "使い方:
  md2pdf <Markdownファイル> [別のファイル ...]
  md2pdf <Markdownファイル> -o <保存先.pdf>
  md2pdf setup
  md2pdf uninstall [--dry-run]

元のMarkdownと同じ場所にPDFを保存します。同名PDFは上書きします。
-o / --output は1ファイルの変換時に指定できます。
初回は md2pdf setup で専用Chromiumを準備してください。
--help / -h    ヘルプ
--version / -V バージョン";

#[derive(Debug)]
struct Job {
    file: PathBuf,
    target: PathBuf,
    source: String,
    body: String,
    page: PathBuf,
}

fn absolute(path: &Path, cwd: &Path) -> PathBuf {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    };
    let mut result = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                result.pop();
            }
            other => result.push(other),
        }
    }
    result
}

fn plan(args: &[OsString], cwd: &Path) -> Result<Vec<Job>> {
    let mut inputs = Vec::new();
    let mut output = None;
    let mut positional = false;
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if !positional && arg == "--" {
            positional = true;
        } else if !positional && (arg == "-o" || arg == "--output") {
            index += 1;
            if output.is_some()
                || index == args.len()
                || args[index].to_string_lossy().starts_with('-')
            {
                bail!("-o / --output の後に保存先.pdfを指定してください");
            }
            output = Some(absolute(Path::new(&args[index]), cwd));
        } else if !positional && arg.to_string_lossy().starts_with('-') {
            bail!("不明なオプション: {}", arg.to_string_lossy());
        } else {
            let file = absolute(Path::new(arg), cwd);
            if !inputs.contains(&file) {
                inputs.push(file);
            }
        }
        index += 1;
    }
    if inputs.is_empty() {
        bail!("{USAGE}");
    }
    if let Some(output) = &output
        && (inputs.len() != 1 || !extension_is(output, "pdf"))
    {
        bail!("-o / --output は1ファイルの変換時に、拡張子.pdfの保存先を指定してください");
    }
    let mut targets = HashSet::new();
    let mut jobs = Vec::new();
    for file in inputs {
        if !file.is_file() {
            bail!("ファイルが見つかりません: {}", file.display());
        }
        if !extension_is(&file, "md") && !extension_is(&file, "markdown") {
            bail!("Markdownファイルではありません: {}", file.display());
        }
        let target = output.clone().unwrap_or_else(|| file.with_extension("pdf"));
        if !targets.insert(target.clone()) {
            bail!("保存先が重複しています: {}", target.display());
        }
        let source = fs::read_to_string(&file)
            .with_context(|| format!("読み込めません: {}", file.display()))?;
        jobs.push(Job {
            file,
            target,
            source,
            body: String::new(),
            page: PathBuf::new(),
        });
    }
    Ok(jobs)
}

fn extension_is(path: &Path, extension: &str) -> bool {
    path.extension()
        .is_some_and(|value| value.eq_ignore_ascii_case(extension))
}

fn file_url(path: &Path) -> Result<String> {
    Ok(Url::from_file_path(path)
        .map_err(|_| anyhow::anyhow!("不正なパス: {}", path.display()))?
        .into())
}

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
}

fn scaffold(file: &Path, assets: &Path) -> Result<String> {
    let base = Url::from_directory_path(file.parent().context("入力の親フォルダがありません")?)
        .map_err(|_| anyhow::anyhow!("不正な入力パス"))?;
    let title = file.file_stem().unwrap_or_default().to_string_lossy();
    Ok(format!(
        "<!doctype html><html lang=\"ja\"><head><meta charset=\"utf-8\"><title>{}</title>\
         <base href=\"{}\"><link rel=\"stylesheet\" href=\"{}\"><style>{}</style>\
         <script src=\"{}\"></script><script src=\"{}\"></script><script src=\"{}\"></script>\
         </head><body></body></html>",
        escape(&title),
        escape(base.as_str()),
        escape(&file_url(&assets.join("vendor/katex/katex.min.css"))?),
        include_str!("../assets/print.css"),
        escape(&file_url(&assets.join("vendor/markdown-it.min.js"))?),
        escape(&file_url(&assets.join("vendor/katex/katex.min.js"))?),
        escape(&file_url(&assets.join("render.js"))?),
    ))
}

fn convert(mut jobs: Vec<Job>) -> Result<()> {
    let executable = browser::executable()?;
    let temp_root = browser::data_dir()?.join("tmp");
    fs::create_dir_all(&temp_root)?;
    let temporary = tempfile::tempdir_in(&temp_root)?;
    let assets = temporary.path().join("assets");
    fs::create_dir(&assets)?;
    ASSETS.extract(&assets)?;
    let mut browser = cdp::Browser::launch(&executable, temporary.path())?;
    let mut targets = serde_json::Map::new();
    for job in &jobs {
        targets.insert(file_url(&job.file)?, json!(file_url(&job.target)?));
    }
    // Validate and render every document before writing any output, like the reference.
    for (index, job) in jobs.iter_mut().enumerate() {
        job.page = temporary.path().join(format!("{index}.html"));
        fs::write(&job.page, scaffold(&job.file, &assets)?)?;
        browser.navigate(&file_url(&job.page)?)?;
        let expression = format!(
            "window.md2pdfRender({}, {}, {})",
            serde_json::to_string(&job.source)?,
            serde_json::to_string(&file_url(&job.file)?)?,
            Value::Object(targets.clone())
        );
        let rendered = browser
            .evaluate(&expression)
            .with_context(|| format!("{}", job.file.display()))?;
        job.body = rendered.as_str().context("HTMLを取得できません")?.into();
    }
    for job in jobs {
        browser.navigate(&file_url(&job.page)?)?;
        browser.evaluate(&format!(
            "(async () => {{ document.body.innerHTML = {}; await window.md2pdfPreparePrint(); return true; }})()",
            serde_json::to_string(&job.body)?))
            .with_context(|| format!("{}", job.file.display()))?;
        let response = browser.call("Page.printToPDF", json!({
            "paperWidth": 8.27, "paperHeight": 11.7,
            "printBackground": true, "preferCSSPageSize": true,
            "marginTop": 18.0 / 25.4, "marginBottom": 18.0 / 25.4,
            "marginLeft": 18.0 / 25.4, "marginRight": 18.0 / 25.4,
            "displayHeaderFooter": true, "headerTemplate": "<span></span>",
            "footerTemplate": "<div style=\"width:100%;text-align:center;font-size:8px;color:#718096\"><span class=\"pageNumber\"></span> / <span class=\"totalPages\"></span></div>",
            "generateTaggedPDF": true, "generateDocumentOutline": true,
        }))?;
        let pdf = base64::engine::general_purpose::STANDARD
            .decode(response["data"].as_str().context("PDFを取得できません")?)?;
        let parent = job
            .target
            .parent()
            .context("保存先の親フォルダがありません")?;
        fs::create_dir_all(parent)?;
        let mut staging = tempfile::NamedTempFile::new_in(parent)?;
        staging.write_all(&pdf)?;
        staging.flush()?;
        staging
            .persist(&job.target)
            .with_context(|| format!("保存できません: {}", job.target.display()))?;
        println!("保存しました: {}", job.target.display());
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args_os().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("{USAGE}");
        return Ok(());
    }
    if args.len() == 1 && (args[0] == "--version" || args[0] == "-V") {
        println!("md2pdf {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if args.first().is_some_and(|arg| arg == "__install-record") {
        if args.len() != 2 {
            bail!("インストール記録の引数が不正です");
        }
        return install::record(Path::new(&args[1]));
    }
    if args.first().is_some_and(|arg| arg == "uninstall") {
        let dry_run = args.len() == 2 && args[1] == "--dry-run";
        if args.len() != 1 && !dry_run {
            bail!("使い方: md2pdf uninstall [--dry-run]");
        }
        return install::uninstall(dry_run);
    }
    if args.first().is_some_and(|arg| arg == "setup") {
        if args.len() != 1 {
            bail!("使い方: md2pdf setup");
        }
        return browser::setup();
    }
    convert(plan(&args, &env::current_dir()?)?)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn plans_deduplicated_inputs_and_explicit_output() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::write(dir.path().join("日本語 メモ.md"), "# test")?;
        let jobs = plan(
            &arguments(&["日本語 メモ.md", "./日本語 メモ.md"]),
            dir.path(),
        )?;
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].target, dir.path().join("日本語 メモ.pdf"));
        let jobs = plan(
            &arguments(&["日本語 メモ.md", "-o", "nested/report.pdf"]),
            dir.path(),
        )?;
        assert_eq!(jobs[0].target, dir.path().join("nested/report.pdf"));
        Ok(())
    }

    #[test]
    fn rejects_conflicting_outputs_before_conversion() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::write(dir.path().join("a.md"), "a")?;
        fs::write(dir.path().join("a.markdown"), "b")?;
        assert!(plan(&arguments(&["a.md", "a.markdown"]), dir.path()).is_err());
        assert!(plan(&arguments(&["a.md", "-o", "a.md"]), dir.path()).is_err());
        assert!(
            plan(
                &arguments(&["a.md", "a.markdown", "-o", "out.pdf"]),
                dir.path()
            )
            .is_err()
        );
        assert!(plan(&arguments(&["a.md", "--invalid"]), dir.path()).is_err());
        Ok(())
    }

    #[test]
    fn double_dash_allows_option_like_filename() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::write(dir.path().join("-memo.md"), "a")?;
        assert!(plan(&arguments(&["--", "-memo.md"]), dir.path()).is_ok());
        Ok(())
    }
}
