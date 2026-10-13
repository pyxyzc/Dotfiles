"""Isolated installer regressions; system commands are mocked."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tests'))
from installer_support import InstallerCase, ROOT, write_exec

import os
import shutil

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
