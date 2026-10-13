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


ROOT = Path(__file__).resolve().parents[1]
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
        # Even an older installer that ignores --target-dir must stay isolated.
        self.env["HOME"] = str(self.work / "home")
        Path(self.env["HOME"]).mkdir()

    def run_script(self, script, *args, expected=0):
        result = subprocess.run(
            [BASH, str(ROOT / script), *args],
            cwd=self.work, env=self.env,
            capture_output=True, text=True, timeout=30,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result
