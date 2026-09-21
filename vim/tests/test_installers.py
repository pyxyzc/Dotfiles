#!/usr/bin/env python3
"""Mocked installer checks for the tmux and lazygit scripts.

Every test runs in a temporary directory with fake commands on PATH; nothing
touches the real system, downloads from the network, or installs software.
"""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which("bash")


def write_exec(path, body):
    path.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class InstallerCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotfiles-installer-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.target = self.work / "target"
        self.target.mkdir()
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin}{os.pathsep}{self.env['PATH']}"

    def run_script(self, script, *args, expected=0):
        result = subprocess.run(
            [BASH, str(ROOT / script), *args],
            cwd=self.work, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result


class TmuxInstallerTests(InstallerCase):
    def setUp(self):
        super().setUp()
        self.marker = self.work / "tmux-ready"
        self.env["TMUX_MARKER"] = str(self.marker)
        write_exec(self.bin / "tmux", '[[ -f "${TMUX_MARKER:-}" ]] && exit 0\nexit 1\n')
        write_exec(self.bin / "apt-get", 'touch "${TMUX_MARKER:-/dev/null}"\nexit 0\n')
        write_exec(
            self.bin / "git",
            'dest="${@: -1}"\nmkdir -p -- "$dest"\ntouch "$dest/tpm"\n',
        )

    def test_help_exits_cleanly(self):
        result = self.run_script("tmux/tmux-install.sh", "--help")
        self.assertIn("--config-only", result.stdout)

    def test_config_only_copies_and_backs_up(self):
        (self.target / ".tmux.conf").write_text("old config\n", encoding="utf-8")
        self.run_script("tmux/tmux-install.sh", "--config-only", "--target-dir", str(self.target))
        installed = (self.target / ".tmux.conf").read_text(encoding="utf-8")
        self.assertEqual(installed, (ROOT / "tmux" / ".tmux.conf").read_text(encoding="utf-8"))
        self.assertEqual(len(list(self.target.glob(".tmux.conf.bak.*"))), 1)
        self.assertFalse((self.target / ".bashrc").exists())
        self.assertFalse((self.target / ".tmux").exists())

    def test_config_only_is_idempotent(self):
        self.run_script("tmux/tmux-install.sh", "--config-only", "--target-dir", str(self.target))
        second = self.run_script(
            "tmux/tmux-install.sh", "--config-only", "--target-dir", str(self.target)
        )
        self.assertIn("已是最新", second.stdout)
        self.assertEqual(list(self.target.glob(".tmux.conf.bak.*")), [])

    def test_package_manager_lang_and_tpm(self):
        (self.target / ".bashrc").write_text("export FOO=1\n", encoding="utf-8")
        self.run_script("tmux/tmux-install.sh", "--target-dir", str(self.target))
        self.assertTrue(self.marker.exists())
        self.assertEqual((self.target / ".tmux.conf").exists(), True)
        self.assertEqual((self.target / ".tmux/plugins/tpm/tpm").exists(), True)
        bashrc = (self.target / ".bashrc").read_text(encoding="utf-8")
        self.assertIn("export FOO=1", bashrc)
        self.assertEqual(bashrc.count("# >>> tmux-lang >>>"), 1)
        self.assertEqual(len(list(self.target.glob(".bashrc.bak.*"))), 1)

    def test_lang_block_is_idempotent(self):
        (self.target / ".bashrc").write_text("export FOO=1\n", encoding="utf-8")
        self.run_script("tmux/tmux-install.sh", "--target-dir", str(self.target))
        first = (self.target / ".bashrc").read_text(encoding="utf-8")
        second = self.run_script("tmux/tmux-install.sh", "--target-dir", str(self.target))
        self.assertIn("TPM 已安装", second.stdout)
        self.assertEqual((self.target / ".bashrc").read_text(encoding="utf-8"), first)
        self.assertEqual(first.count("# >>> tmux-lang >>>"), 1)
        self.assertEqual(len(list(self.target.glob(".bashrc.bak.*"))), 1)

    def test_existing_lang_setting_is_respected(self):
        (self.target / ".bashrc").write_text("export LANG=en_US.UTF-8\n", encoding="utf-8")
        result = self.run_script("tmux/tmux-install.sh", "--target-dir", str(self.target))
        self.assertIn("LANG 已设置", result.stdout)
        bashrc = (self.target / ".bashrc").read_text(encoding="utf-8")
        self.assertNotIn("# >>> tmux-lang >>>", bashrc)
        self.assertEqual(list(self.target.glob(".bashrc.bak.*")), [])


class LazyGitInstallerTests(InstallerCase):
    def setUp(self):
        super().setUp()
        self.local = self.work / "localbin"
        self.env["MOCK_ARCH"] = "x86_64"
        self.env["MOCK_HASH"] = "deadbeef"
        self.env["MOCK_CHECKSUM_HASH"] = "deadbeef"
        self.env["MOCK_ASSET"] = "lazygit_0.65.1_linux_x86_64.tar.gz"
        self.env["MOCK_CURL_MARKER"] = str(self.work / "curl-called")
        write_exec(
            self.bin / "uname",
            'case "${1:-}" in\n'
            '  -m) echo "${MOCK_ARCH:-x86_64}" ;;\n'
            '  -s) echo Linux ;;\n'
            '  *) echo Linux ;;\n'
            'esac\n',
        )
        write_exec(
            self.bin / "curl",
            'out=""\nurl=""\n'
            'while (( $# )); do\n'
            '  case "$1" in\n'
            '    -o) out="$2"; shift 2 ;;\n'
            '    -*) shift ;;\n'
            '    *) url="$1"; shift ;;\n'
            '  esac\n'
            'done\n'
            '[[ -n "${MOCK_CURL_MARKER:-}" ]] && touch "$MOCK_CURL_MARKER"\n'
            'if [[ "$url" == *checksums.txt ]]; then\n'
            '  printf "%s  %s\\n" "${MOCK_CHECKSUM_HASH}" "${MOCK_ASSET}" > "$out"\n'
            'else\n'
            '  printf "fake archive\\n" > "$out"\n'
            'fi\n',
        )
        write_exec(
            self.bin / "tar",
            'dest=""\n'
            'while (( $# )); do\n'
            '  case "$1" in\n'
            '    -C) dest="$2"; shift 2 ;;\n'
            '    *) shift ;;\n'
            '  esac\n'
            'done\n'
            'mkdir -p -- "$dest"\n'
            'printf "#!/bin/sh\\necho \\"lazygit version v${MOCK_VERSION:-0.65.1}\\"\\n" > "$dest/lazygit"\n'
            'chmod +x "$dest/lazygit"\n',
        )
        write_exec(self.bin / "sha256sum", 'printf "%s  %s\\n" "${MOCK_HASH}" "$1"\n')

    def test_help_exits_cleanly(self):
        result = self.run_script("lazygit/lazygit-install.sh", "--help")
        self.assertIn("--bin-dir", result.stdout)

    def test_installs_pinned_version_with_checksum(self):
        result = self.run_script(
            "lazygit/lazygit-install.sh", "--bin-dir", str(self.local)
        )
        self.assertIn("校验通过", result.stdout)
        binary = self.local / "lazygit"
        self.assertTrue(binary.is_file())
        self.assertTrue(os.access(binary, os.X_OK))

    def test_checksum_mismatch_aborts(self):
        self.env["MOCK_HASH"] = "1111"
        self.env["MOCK_CHECKSUM_HASH"] = "2222"
        result = self.run_script(
            "lazygit/lazygit-install.sh", "--bin-dir", str(self.local), expected=1
        )
        self.assertIn("校验失败", result.stderr + result.stdout)
        self.assertFalse((self.local / "lazygit").exists())

    def test_unsupported_architecture_aborts(self):
        self.env["MOCK_ARCH"] = "riscv64"
        result = self.run_script(
            "lazygit/lazygit-install.sh", "--bin-dir", str(self.local), expected=1
        )
        self.assertIn("不支持的架构", result.stderr + result.stdout)
        self.assertFalse((self.local / "lazygit").exists())

    def test_existing_matching_version_is_skipped(self):
        self.local.mkdir()
        binary = self.local / "lazygit"
        write_exec(binary, 'echo "lazygit version v0.65.1"\n')
        marker = Path(self.env["MOCK_CURL_MARKER"])
        result = self.run_script(
            "lazygit/lazygit-install.sh", "--bin-dir", str(self.local)
        )
        self.assertIn("已安装，跳过", result.stdout)
        self.assertFalse(marker.exists())

    def test_existing_binary_is_backed_up(self):
        self.local.mkdir()
        write_exec(self.local / "lazygit", 'echo "lazygit version v0.0.1"\n')
        self.run_script("lazygit/lazygit-install.sh", "--bin-dir", str(self.local))
        self.assertEqual(len(list(self.local.glob("lazygit.bak.*"))), 1)

    def test_version_override_uses_requested_asset(self):
        self.env["MOCK_ASSET"] = "lazygit_0.70.0_linux_x86_64.tar.gz"
        result = self.run_script(
            "lazygit/lazygit-install.sh", "--version", "0.70.0", "--bin-dir", str(self.local)
        )
        self.assertIn("LazyGit 0.70.0", result.stdout)
        self.assertTrue((self.local / "lazygit").is_file())


if __name__ == "__main__":
    unittest.main(verbosity=2)
