"""Isolated installer regressions; system commands are mocked."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tests'))
from installer_support import InstallerCase, ROOT, write_exec

import os
import shutil

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
