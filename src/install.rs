use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    env, fs,
    path::{Path, PathBuf},
};

const MARKER: &str = ".md2pdf-install";

#[derive(Serialize, Deserialize)]
struct Record {
    app: String,
    data_dir: PathBuf,
    commands: BTreeSet<PathBuf>,
}

fn recorded_commands(root: &Path) -> Result<BTreeSet<PathBuf>> {
    let marker = root.join(MARKER);
    if !marker.exists() {
        return Ok(BTreeSet::new());
    }
    let text = fs::read_to_string(marker)?;
    if text == "md2pdf installer\n" {
        return Ok(BTreeSet::new());
    }
    let record: Record = serde_json::from_str(&text).context("インストール記録を読み込めません")?;
    if record.app != "md2pdf" || record.data_dir != root {
        bail!("インストール記録と設置先が一致しません");
    }
    Ok(record.commands)
}

fn candidates(root: &Path) -> Result<BTreeSet<PathBuf>> {
    let mut paths = recorded_commands(root)?;
    // Also discover commands from the original installer, before records existed.
    if let Some(path) = env::var_os("PATH") {
        paths.extend(env::split_paths(&path).map(|dir| dir.join("md2pdf")));
    }
    if let Ok(executable) = env::current_exe() {
        paths.insert(executable);
    }
    if let Some(home) = env::var_os("HOME") {
        paths.insert(PathBuf::from(home).join(".local/bin/md2pdf"));
    }
    Ok(paths)
}

fn owned_command(path: &Path, executable: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink())
        && fs::canonicalize(path).is_ok_and(|target| target == executable)
}

/// Called only by install.sh. Print the next record; installation commits it
/// only after browser setup and all validation have succeeded.
pub fn record(command: &Path) -> Result<()> {
    let root = fs::canonicalize(crate::browser::data_dir()?)?;
    let executable = root.join("md2pdf");
    let mut commands = candidates(&root)?;
    commands.retain(|path| owned_command(path, &executable));
    if !command.is_absolute() || command.file_name().is_none_or(|name| name != "md2pdf") {
        bail!("コマンドの設置先が不正です");
    }
    commands.insert(command.into());
    println!(
        "{}",
        serde_json::to_string_pretty(&Record {
            app: "md2pdf".into(),
            data_dir: root,
            commands
        })?
    );
    Ok(())
}

struct Removal {
    root: PathBuf,
    commands: BTreeSet<PathBuf>,
    entries: Vec<PathBuf>,
}

impl Removal {
    fn plan(
        root: &Path,
        executable: &Path,
        candidates: BTreeSet<PathBuf>,
        home: Option<&Path>,
    ) -> Result<Self> {
        if root.parent().is_none()
            || home == Some(root)
            || root == env::temp_dir().canonicalize().unwrap_or_default()
            || !root.join(MARKER).is_file()
            || executable != root.join("md2pdf")
            || !root.join("browser.json").is_file()
        {
            bail!(
                "管理対象のインストール先を確認できません: {}",
                root.display()
            );
        }
        // Only remove files/directories owned by this tool. An unrelated file
        // in a custom data directory must never be swept up by recursive removal.
        let mut entries = Vec::new();
        for entry in fs::read_dir(root)? {
            let entry = entry?;
            let name = entry.file_name();
            if matches!(
                name.to_str(),
                Some(
                    "md2pdf"
                        | "browser.json"
                        | "browser"
                        | "tmp"
                        | "LICENSE"
                        | "THIRD_PARTY_NOTICES.md"
                        | ".md2pdf-install"
                )
            ) || name.to_string_lossy().starts_with(".install.")
            {
                entries.push(entry.path());
            }
        }
        // Keep the runnable uninstaller and its record until other removals
        // succeed, so filesystem errors can be retried via the installed binary.
        entries.sort_by_key(|path| {
            let priority = match path.file_name().and_then(|name| name.to_str()) {
                Some("md2pdf") => 2,
                Some(MARKER) => 1,
                _ => 0,
            };
            (priority, path.clone())
        });
        let commands = candidates
            .into_iter()
            .filter(|path| owned_command(path, executable))
            .collect();
        Ok(Self {
            root: root.into(),
            commands,
            entries,
        })
    }

    fn execute(&self, dry_run: bool) -> Result<()> {
        for path in self.commands.iter().chain(self.entries.iter()) {
            println!(
                "{}: {}",
                if dry_run { "削除予定" } else { "削除" },
                path.display()
            );
        }
        if dry_run {
            return Ok(());
        }
        // Delete external command symlinks first, while their targets still exist.
        for command in &self.commands {
            // Recheck in case another program replaced the link after planning.
            if owned_command(command, &self.root.join("md2pdf")) {
                fs::remove_file(command)
                    .with_context(|| format!("削除できません: {}", command.display()))?;
            }
        }
        for path in &self.entries {
            let meta = fs::symlink_metadata(path)?;
            if meta.is_dir() && !meta.file_type().is_symlink() {
                fs::remove_dir_all(path)?;
            } else {
                fs::remove_file(path)?;
            }
        }
        if fs::read_dir(&self.root)?.next().is_none() {
            fs::remove_dir(&self.root)?;
        } else {
            println!(
                "ツール以外のファイルがあるためフォルダを残しました: {}",
                self.root.display()
            );
        }
        println!("md2pdfをアンインストールしました");
        Ok(())
    }
}

pub fn uninstall(dry_run: bool) -> Result<()> {
    // Derive ownership from the actual executable, never from an environment
    // override that might point at another installation or an arbitrary folder.
    let executable = fs::canonicalize(env::current_exe()?)?;
    let root = executable.parent().context("インストール先がありません")?;
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .and_then(|p| fs::canonicalize(p).ok());
    let removal = Removal::plan(root, &executable, candidates(root)?, home.as_deref())?;
    removal.execute(dry_run)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn removes_all_owned_files_and_links_but_preserves_outputs_and_other_apps() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().join("custom data");
        fs::create_dir_all(root.join("browser/old-version"))?;
        let root = fs::canonicalize(root)?;
        fs::create_dir_all(root.join("tmp/crashed-run"))?;
        for name in [
            "md2pdf",
            "browser.json",
            MARKER,
            "THIRD_PARTY_NOTICES.md",
            "browser/old-version/cache",
            "tmp/crashed-run/page.html",
        ] {
            fs::write(root.join(name), "test")?;
        }
        let executable = root.join("md2pdf");
        let link = dir.path().join("command");
        symlink(&executable, &link)?;
        let elsewhere = dir.path().join("other-app");
        fs::write(&elsewhere, "keep")?;
        let foreign_link = dir.path().join("foreign-command");
        symlink(&elsewhere, &foreign_link)?;
        // A symlink inside our directory must not cause removal of its target.
        symlink(&elsewhere, root.join("LICENSE"))?;
        let output = dir.path().join("report.pdf");
        fs::write(&output, "keep")?;
        let plan = Removal::plan(
            &root,
            &executable,
            BTreeSet::from([link.clone(), foreign_link.clone()]),
            None,
        )?;
        plan.execute(true)?;
        assert!(root.exists() && link.exists());
        plan.execute(false)?;
        assert!(!root.exists() && fs::symlink_metadata(link).is_err());
        assert!(output.exists() && foreign_link.exists() && elsewhere.exists());
        Ok(())
    }

    #[test]
    fn refuses_unmanaged_directory() -> Result<()> {
        let dir = tempfile::tempdir()?;
        fs::write(dir.path().join("md2pdf"), "test")?;
        assert!(
            Removal::plan(
                dir.path(),
                &dir.path().join("md2pdf"),
                BTreeSet::new(),
                None
            )
            .is_err()
        );
        Ok(())
    }

    #[test]
    fn preserves_unrelated_files_in_custom_data_directory() -> Result<()> {
        let dir = tempfile::tempdir()?;
        for name in ["md2pdf", "browser.json", MARKER, "personal.txt"] {
            fs::write(dir.path().join(name), "keep")?;
        }
        Removal::plan(
            dir.path(),
            &dir.path().join("md2pdf"),
            BTreeSet::new(),
            None,
        )?
        .execute(false)?;
        assert!(dir.path().join("personal.txt").exists());
        assert!(!dir.path().join("md2pdf").exists());
        Ok(())
    }
}
