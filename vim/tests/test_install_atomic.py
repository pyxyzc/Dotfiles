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
        obsolete = self.target / '.vim/which-key.vim'
        obsolete.parent.mkdir()
        obsolete.write_text('old module\n')
        markdown = obsolete.parent / 'markdown.vim'
        markdown.write_text('old markdown module\n')
        resources = obsolete.parent / 'markdown'
        resources.mkdir()
        (resources / 'preview.py').write_text('old preview\n')
        snippets = obsolete.parent / 'vendor/vim-vsnip'
        snippets.mkdir(parents=True)
        (snippets / 'old.txt').write_text('old snippets\n')
        result = self.install(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), 'old configuration\n')
        self.assertEqual(obsolete.read_text(), 'old module\n')
        self.assertEqual(markdown.read_text(), 'old markdown module\n')
        self.assertEqual((resources / 'preview.py').read_text(), 'old preview\n')
        self.assertEqual((snippets / 'old.txt').read_text(), 'old snippets\n')
        self.assertFalse(list(self.target.rglob('*.tmp.*')))

    def test_upgrade_removes_markdown_and_preserves_symlink_targets(self):
        vim = self.target / '.vim'
        (vim / 'vendor').mkdir(parents=True)
        modules = [vim / name for name in (
            'markdown.vim', 'markdown-view.vim', 'markdown-reader.vim',
            'markdown-notes.vim', 'markdown-snippets.vim', 'markdown-images.vim')]
        directories = [vim / 'markdown', vim / 'vendor/vim-vsnip']
        for path in modules:
            path.write_text('old module\n')
        for path in directories:
            path.mkdir()
            (path / 'old.txt').write_text('old resource\n')
        external = self.work / 'external'
        external.mkdir()
        keep = external / 'keep.txt'
        keep.write_text('keep\n')
        for mode in ('files', 'symlinks', 'dangling', 'repeat'):
            with self.subTest(mode=mode):
                if mode in ('symlinks', 'dangling'):
                    for path in modules:
                        path.symlink_to(keep if mode == 'symlinks' else external / 'missing')
                    for path in directories:
                        path.symlink_to(external if mode == 'symlinks' else external / 'missing',
                                        target_is_directory=True)
                result = self.install()
                self.assertEqual(result.returncode, 0, result.stderr)
                for path in modules + directories:
                    self.assertFalse(path.exists() or path.is_symlink(), str(path))
                self.assertEqual(keep.read_text(), 'keep\n')

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
