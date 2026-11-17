use anyhow::{Context, Result, bail};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{collections::HashMap, env, fs, io::Read, path::PathBuf, process::Command};

#[derive(Deserialize)]
struct Manifest {
    version: String,
    platforms: HashMap<String, Platform>,
}

#[derive(Deserialize)]
struct Platform {
    url: String,
    sha256: String,
    executable: String,
}

fn manifest() -> Result<(Manifest, String)> {
    let platform = match (env::consts::OS, env::consts::ARCH) {
        ("macos", "aarch64") => "aarch64-apple-darwin",
        _ => bail!("Apple SiliconのmacOS（arm64）専用です。Intel Macには対応していません"),
    };
    Ok((
        serde_json::from_str(include_str!("../assets/browser.json"))?,
        platform.into(),
    ))
}

pub fn data_dir() -> Result<PathBuf> {
    if let Some(path) = env::var_os("MD2PDF_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    if let Ok(executable) = env::current_exe().and_then(fs::canonicalize)
        && let Some(parent) = executable.parent()
        && parent.join("browser.json").is_file()
    {
        return Ok(parent.into());
    }
    let home = env::var_os("HOME").context("HOMEが設定されていません")?;
    Ok(PathBuf::from(home).join(".local/share/md2pdf"))
}

pub fn executable() -> Result<PathBuf> {
    if let Some(path) = env::var_os("MD2PDF_BROWSER_PATH") {
        let path = PathBuf::from(path);
        if !path.is_file() {
            bail!("指定されたChromiumが見つかりません: {}", path.display());
        }
        return Ok(path);
    }
    let (manifest, target) = manifest()?;
    let platform = manifest
        .platforms
        .get(&target)
        .context("ブラウザの設定がありません")?;
    let executable = data_dir()?
        .join("browser")
        .join(&manifest.version)
        .join(&platform.executable);
    if !executable.is_file() {
        bail!("専用Chromiumが未準備です。./install.sh を再実行してください");
    }
    Ok(executable)
}

pub fn setup() -> Result<()> {
    let (manifest, target) = manifest()?;
    let platform = manifest
        .platforms
        .get(&target)
        .context("ブラウザの設定がありません")?;
    let root = data_dir()?.join("browser");
    let destination = root.join(&manifest.version);
    let executable = destination.join(&platform.executable);
    if executable.is_file() {
        check_version(&executable, &manifest.version)?;
        println!("Chromium {} は準備済みです", manifest.version);
        return Ok(());
    }
    fs::create_dir_all(&root)?;
    let staging = tempfile::tempdir_in(&root)?;
    let archive = staging.path().join("browser.zip");
    eprintln!(
        "専用Chromium {} をダウンロードしています…",
        manifest.version
    );
    let status = Command::new("/usr/bin/curl")
        .args([
            "--fail",
            "--location",
            "--retry",
            "2",
            "--connect-timeout",
            "20",
            "--max-time",
            "600",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--output",
        ])
        .arg(&archive)
        .arg(&platform.url)
        .status()
        .context("curlを起動できません")?;
    if !status.success() {
        bail!("Chromiumのダウンロードに失敗しました。接続を確認して再実行してください");
    }
    let mut file = fs::File::open(&archive)?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    if format!("{:x}", hash.finalize()) != platform.sha256 {
        bail!("Chromiumのチェックサムが一致しません。インストールを中止しました");
    }
    let unpacked = staging.path().join("unpacked");
    fs::create_dir(&unpacked)?;
    let status = Command::new("/usr/bin/unzip")
        .arg("-q")
        .arg(&archive)
        .arg("-d")
        .arg(&unpacked)
        .status()?;
    if !status.success() || !unpacked.join(&platform.executable).is_file() {
        bail!("Chromiumの展開に失敗しました");
    }
    check_version(&unpacked.join(&platform.executable), &manifest.version)?;
    if destination.exists() {
        // Do not destroy a partially-installed or concurrently-created browser.
        if executable.is_file() {
            check_version(&executable, &manifest.version)?;
            return Ok(());
        }
        bail!(
            "不完全なブラウザフォルダがあります。次のフォルダを移動してから再実行してください: {}",
            destination.display()
        );
    }
    fs::rename(&unpacked, &destination)?;
    println!("Chromium {} の準備ができました", manifest.version);
    Ok(())
}

fn check_version(executable: &std::path::Path, expected: &str) -> Result<()> {
    let version = Command::new(executable)
        .arg("--version")
        .output()
        .context("Chromiumを実行できません")?;
    if !version.status.success()
        || !String::from_utf8_lossy(&version.stdout)
            .split_whitespace()
            .any(|part| part == expected)
    {
        bail!(
            "Chromiumのバージョンを確認できません: {}",
            executable.display()
        );
    }
    Ok(())
}
