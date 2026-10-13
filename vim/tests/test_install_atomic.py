"""Install replacement failures preserve files, directories, and personal hooks."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_vim import ROOT


class AtomicInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vim-atomic-install-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.target = self.work / 'target'
        self.target.mkdir()

    def install(self, fail_target=None, interrupt=False):
        env = os.environ.copy()
        if fail_target:
            shims = self.work / 'bin'
            shims.mkdir()
            shim = shims / 'mv'
            failure = 'kill -TERM "$PPID"; exit 143' if interrupt else 'exit 74'
            shim.write_text('#!/usr/bin/env bash\n'
                            'if [[ "${@: -1}" == "$VIM_ATOMIC_FAIL_TARGET" && '
                            '"$*" == *".tmp."* ]]; then ' + failure + '; fi\n'
                            'exec ' + shutil.which('mv') + ' "$@"\n')
            shim.chmod(0o755)
            env['PATH'] = str(shims) + os.pathsep + env['PATH']
            env['VIM_ATOMIC_FAIL_TARGET'] = str(fail_target)
        return subprocess.run(['bash', str(ROOT / 'vim-install.sh'), '--config-only',
                               '--target-dir', str(self.target)], env=env,
                              capture_output=True, text=True, timeout=20)

    def test_file_move_failure_keeps_original_config(self):
        config = self.target / '.vimrc'
        config.write_text('old configuration\n')
        result = self.install(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), 'old configuration\n')
        self.assertFalse(list(self.target.rglob('*.tmp.*')))

    def test_directory_move_failure_restores_old_plugin(self):
        plugin = self.target / '.vim/vendor/vim-lsp'
        plugin.mkdir(parents=True)
        (plugin / 'old.txt').write_text('old plugin\n')
        result = self.install(plugin)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((plugin / 'old.txt').read_text(), 'old plugin\n')
        self.assertFalse(list(self.target.rglob('*.tmp.*')))
        self.assertFalse(list(self.target.rglob('*.rollback.*')))

    def test_directory_move_failure_restores_symlink(self):
        external = self.work / 'external'
        external.mkdir()
        (external / 'keep.txt').write_text('keep\n')
        parent = self.target / '.vim/vendor'
        parent.mkdir(parents=True)
        plugin = parent / 'vim-lsp'
        plugin.symlink_to(external, target_is_directory=True)
        result = self.install(plugin)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(plugin.is_symlink())
        self.assertEqual((external / 'keep.txt').read_text(), 'keep\n')

    def test_signal_in_missing_target_window_restores_old_plugin(self):
        plugin = self.target / '.vim/vendor/vim-lsp'
        plugin.mkdir(parents=True)
        (plugin / 'old.txt').write_text('old plugin\n')
        result = self.install(plugin, interrupt=True)
        self.assertEqual(result.returncode, 143)
        self.assertEqual((plugin / 'old.txt').read_text(), 'old plugin\n')
        self.assertFalse(list(self.target.rglob('*.rollback.*')))

    def test_personal_hooks_survive_repeated_install(self):
        vim = self.target / '.vim'
        vim.mkdir()
        for name in ['settings.vim', 'mappings.vim']:
            (vim / name).write_text('" personal\n')
        for _ in range(2):
            result = self.install()
            self.assertEqual(result.returncode, 0, result.stderr)
        for name in ['settings.vim', 'mappings.vim']:
            self.assertEqual((vim / name).read_text(), '" personal\n')
