#!/usr/bin/env python3
"""Test real Tab completion in a clean zsh PTY; never execute completed commands."""
import codecs
import os
from pathlib import Path
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "target/aarch64-apple-darwin/release/md2pdf").resolve()
with tempfile.TemporaryDirectory(prefix="md2pdf-completion-") as directory:
    root = Path(directory)
    installed = root / "installed"
    installed.mkdir()
    shutil.copy2(binary, installed / "md2pdf")
    shutil.copy2(Path(__file__).resolve().parents[1] / "assets/browser.json", installed / "browser.json")
    (installed / ".md2pdf-install").write_text("md2pdf installer\n")
    subprocess.run([str(installed / "md2pdf"), "__install-completion"],
                   env={**os.environ, "ZDOTDIR": str(root / "zsh")}, check=True, capture_output=True)
    script = installed / "completion.zsh"
    assert "completion" not in subprocess.check_output([str(binary), "--help"], text=True)
    removed = subprocess.run([str(binary), "completion", "zsh"], capture_output=True)
    assert removed.returncode != 0 and not removed.stdout
    subprocess.run(["/bin/zsh", "-n", str(script)], check=True)
    for name in ["note.md", "REPORT.MARKDOWN", "日本語 メモ.md", "other.txt", "report.pdf"]:
        (root / name).touch()
    (root / "nested").mkdir()
    child, fd = pty.fork()
    if child == 0:
        os.chdir(root)
        env = os.environ.copy()
        env.pop("FPATH", None)
        env["ZDOTDIR"] = directory
        env["TERM"] = "xterm-256color"
        os.execve("/bin/zsh", ["zsh", "-f"], env)

    pending = ""
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")

    def until(pattern, timeout=10):
        global pending
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, pending, re.S)
            if match:
                pending = pending[match.end():]
                return match
            if select.select([fd], [], [], 0.1)[0]:
                pending += decoder.decode(os.read(fd, 65536))
        raise AssertionError(f"Timed out waiting for {pattern!r}: {pending!r}")

    try:
        # ZLE dumps the edited buffer then aborts the line. This checks actual
        # _arguments/_files behavior without running conversion.
        init = (
            "PS1='PROMPT> '; RPROMPT=''; autoload -Uz compinit; compinit -D; "
            f"source {shlex.quote(str(script))}; "
            "_dump_md2pdf_buffer() { print -r -- \"__BUFFER__${BUFFER}__END__\"; zle send-break; }; "
            "zle -N _dump_md2pdf_buffer; bindkey '^X^T' _dump_md2pdf_buffer; "
            "bindkey '^I' complete-word; print READY_TO_TEST\n"
        )
        os.write(fd, init.encode())
        until(r"\r?\nREADY_TO_TEST\r?\n")
        # Wait for ZLE's bracketed-paste enable sequence before sending control
        # keys, which macOS otherwise interprets in canonical terminal mode.
        until(r"PROMPT>.*?\x1b\[\?2004h")
        cases = [
            ("md2pdf se", "md2pdf se"),
            ("md2pdf un", "md2pdf un"),
            ("md2pdf --out", "md2pdf --output"),
            ("md2pdf uninstall --d", "md2pdf uninstall --d"),
            ("md2pdf setup no", "md2pdf setup note.md"),
            ("md2pdf co", "md2pdf co"),
            ("md2pdf no", "md2pdf note.md"),
            ("md2pdf REP", "md2pdf REPORT.MARKDOWN"),
            ("md2pdf -o rep", "md2pdf -o report.pdf"),
            ("md2pdf note.md ne", "md2pdf note.md nested/"),
            ("md2pdf other", "md2pdf other"),
            ("md2pdf note.md --d", "md2pdf note.md --d"),
            ("md2pdf -- --out", "md2pdf -- --out"),
        ]
        for entered, expected in cases:
            os.write(fd, (entered + "\t\x18\x14").encode())
            actual = until(r"__BUFFER__(.*?)__END__").group(1).rstrip()
            assert actual == expected, (entered, actual, expected)
            until(r"PROMPT>.*?\x1b\[\?2004h")
        os.write(fd, "md2pdf 日本\t\x18\x14".encode())
        actual = until(r"__BUFFER__(.*?)__END__").group(1)
        assert "日本語" in actual and "メモ.md" in actual, actual
        print(f"Completion checks passed: {len(cases) + 1} actual Tab cases.")
    finally:
        os.close(fd)
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.waitpid(child, 0)
