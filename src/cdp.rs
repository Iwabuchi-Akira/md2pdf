use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    fs,
    net::TcpStream,
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;
use tungstenite::{Message, WebSocket, stream::MaybeTlsStream};

pub struct Browser {
    child: Child,
    _profile: TempDir,
    socket: WebSocket<MaybeTlsStream<TcpStream>>,
    next_id: u64,
    session: Option<String>,
    events: Vec<Value>,
}

impl Browser {
    pub fn launch(executable: &Path, temp_root: &Path) -> Result<Self> {
        let profile = tempfile::tempdir_in(temp_root)?;
        let log = fs::File::create(profile.path().join("browser.log"))?;
        let child = Command::new(executable)
            .arg("--headless")
            .arg("--remote-debugging-address=127.0.0.1")
            .arg("--remote-debugging-port=0")
            .arg(format!("--user-data-dir={}", profile.path().display()))
            .args([
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-extensions",
                "--disable-sync",
                "--disable-dev-shm-usage",
                "--allow-file-access-from-files",
                "--force-color-profile=srgb",
                "about:blank",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log)
            .spawn()
            .with_context(|| format!("Chromiumを起動できません: {}", executable.display()))?;
        // Keep a guard before connecting so even a failed startup cleans up the child.
        let mut guard = ChildGuard(Some(child));
        let deadline = Instant::now() + Duration::from_secs(20);
        let address = loop {
            if let Ok(text) = fs::read_to_string(profile.path().join("DevToolsActivePort")) {
                let mut lines = text.lines();
                if let (Some(port), Some(path)) = (lines.next(), lines.next()) {
                    break format!("ws://127.0.0.1:{port}{path}");
                }
            }
            if guard.0.as_mut().unwrap().try_wait()?.is_some() || Instant::now() > deadline {
                let log =
                    fs::read_to_string(profile.path().join("browser.log")).unwrap_or_default();
                bail!("Chromiumの起動に失敗しました: {}", log.trim());
            }
            thread::sleep(Duration::from_millis(50));
        };
        let (mut socket, _) = tungstenite::connect(address.as_str())?;
        if let MaybeTlsStream::Plain(stream) = socket.get_mut() {
            stream.set_read_timeout(Some(Duration::from_secs(60)))?;
            stream.set_write_timeout(Some(Duration::from_secs(60)))?;
        }
        let mut browser = Self {
            child: guard.0.take().unwrap(),
            _profile: profile,
            socket,
            next_id: 0,
            session: None,
            events: Vec::new(),
        };
        let target = browser.call("Target.createTarget", json!({"url": "about:blank"}))?;
        let attached = browser.call(
            "Target.attachToTarget",
            json!({
                "targetId": target["targetId"], "flatten": true
            }),
        )?;
        browser.session = Some(
            attached["sessionId"]
                .as_str()
                .context("sessionId missing")?
                .into(),
        );
        browser.call("Page.enable", json!({}))?;
        browser.call("Page.setLifecycleEventsEnabled", json!({"enabled": true}))?;
        browser.call("Runtime.enable", json!({}))?;
        // Playwright supplies these platform fonts even when CSS does not name
        // a font (SVGs, monospace fallbacks, etc.). Keep the reference defaults.
        browser.call(
            "Page.setFontFamilies",
            serde_json::from_str(include_str!("../assets/font-families.json"))?,
        )?;
        browser.call("Emulation.setLocaleOverride", json!({"locale": "en-US"}))?;
        browser.call(
            "Emulation.setUserAgentOverride",
            json!({"userAgent": "", "acceptLanguage": "en-US"}),
        )?;
        browser.call(
            "Emulation.setDeviceMetricsOverride",
            json!({
                "width": 900, "height": 1200, "deviceScaleFactor": 1, "mobile": false
            }),
        )?;
        browser.call("Emulation.setEmulatedMedia", json!({"media": "print"}))?;
        Ok(browser)
    }

    fn read(&mut self) -> Result<Value> {
        loop {
            match self
                .socket
                .read()
                .context("Chromiumとの通信に失敗しました（最大待機60秒）")?
            {
                Message::Text(text) => return Ok(serde_json::from_str(&text)?),
                Message::Close(_) => bail!("Chromiumとの接続が切れました"),
                _ => {}
            }
        }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.next_id += 1;
        let id = self.next_id;
        let mut message = json!({"id": id, "method": method, "params": params});
        if let Some(session) = &self.session {
            message["sessionId"] = json!(session);
        }
        self.socket
            .send(Message::Text(message.to_string().into()))?;
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            let response = self.read()?;
            if response["id"].as_u64() == Some(id) {
                if !response["error"].is_null() {
                    bail!("{method}: {}", response["error"]);
                }
                return Ok(response["result"].clone());
            }
            if response["method"] == "Page.lifecycleEvent" {
                self.events.push(response);
            }
            if Instant::now() > deadline {
                bail!("{method}: Chromiumの応答がタイムアウトしました");
            }
        }
    }

    pub fn navigate(&mut self, url: &str) -> Result<()> {
        self.events.clear();
        let result = self.call("Page.navigate", json!({"url": url}))?;
        if let Some(error) = result["errorText"].as_str() {
            bail!("ページを開けません: {error}");
        }
        let loader = result["loaderId"]
            .as_str()
            .context("ページのloaderIdがありません")?;
        let session = self.session.clone();
        let loaded = |event: &Value| {
            event["sessionId"].as_str() == session.as_deref()
                && event["params"]["name"] == "load"
                && event["params"]["loaderId"] == loader
        };
        let deadline = Instant::now() + Duration::from_secs(60);
        loop {
            if self.events.iter().any(&loaded) {
                break;
            }
            let event = self.read()?;
            if event["method"] == "Page.lifecycleEvent" && loaded(&event) {
                break;
            }
            if Instant::now() > deadline {
                bail!("ページの読み込みがタイムアウトしました");
            }
        }
        Ok(())
    }

    pub fn evaluate(&mut self, expression: &str) -> Result<Value> {
        let result = self.call(
            "Runtime.evaluate",
            json!({
                "expression": expression, "awaitPromise": true, "returnByValue": true
            }),
        )?;
        if !result["exceptionDetails"].is_null() {
            let details = &result["exceptionDetails"];
            bail!(
                "{}",
                details["exception"]["description"]
                    .as_str()
                    .or(details["text"].as_str())
                    .unwrap_or("描画に失敗しました")
            );
        }
        Ok(result["result"]["value"].clone())
    }
}

impl Drop for Browser {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct ChildGuard(Option<Child>);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
