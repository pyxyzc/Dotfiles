"""Offline archive integrity and patch replay failure gates."""

import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

from test_vim import ROOT

sys.path.insert(0, str(ROOT / 'scripts'))
from vendor_lsp import accept_latency, build, contents


class VendorTests(unittest.TestCase):
    def test_slow_warm_operation_fails_acceptance_while_startup_is_reported_separately(self):
        before = {'startup_to_ready': {'median_ms': 200}, 'definition': {'median_ms': 20}}
        after = {'startup_to_ready': {'median_ms': 5000}, 'definition': {'median_ms': 25}}
        accept_latency(before, after, 2)
        after['definition']['median_ms'] = 101
        with self.assertRaisesRegex(ValueError, 'definition'):
            accept_latency(before, after, 2)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vim-vendor-replay-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.archive = self.work / 'source.tar.gz'
        self.commit = 'a' * 40
        self.output = self.work / 'output'
        self.output.mkdir()

    def archive_with(self, path, data=b'upstream\n'):
        with tarfile.open(self.archive, 'w:gz') as archive:
            entry = tarfile.TarInfo('vim-lsp-' + self.commit + '/' + path)
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        return {'commit': self.commit, 'archive_sha256': hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                'paths': ['README.md'], 'patches': []}

    def test_rebuild_matches_source_and_ignores_only_provenance_file(self):
        manifest = self.archive_with('README.md')
        build(self.archive, self.output, manifest)
        self.assertEqual((self.output / 'README.md').read_bytes(), b'upstream\n')
        baseline = contents(self.output)
        (self.output / 'SOURCE.md').write_text('local provenance\n')
        self.assertEqual(contents(self.output), baseline)
        (self.output / 'README.md').write_text('changed\n')
        self.assertNotEqual(contents(self.output), baseline)

    def test_corrupt_archive_aborts_before_extracting(self):
        manifest = self.archive_with('README.md')
        self.archive.write_bytes(self.archive.read_bytes() + b'corruption')
        with self.assertRaisesRegex(ValueError, 'Archive SHA-256'):
            build(self.archive, self.output, manifest)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_archive_escape_is_rejected(self):
        manifest = self.archive_with('../../escape')
        with self.assertRaisesRegex(ValueError, 'unsafe path'):
            build(self.archive, self.output, manifest)
        self.assertFalse((self.work / 'escape').exists())

    def test_changed_patch_is_rejected(self):
        manifest = self.archive_with('README.md')
        patch = self.work / 'local.patch'
        patch.write_text('changed patch\n')
        manifest['patches'] = [{'path': str(patch), 'sha256': '0' * 64}]
        with self.assertRaisesRegex(ValueError, 'Patch SHA-256'):
            build(self.archive, self.output, manifest)

    def test_conflicting_patch_aborts_and_does_not_modify_source(self):
        manifest = self.archive_with('README.md')
        patch = self.work / 'local.patch'
        patch.write_text('diff --git a/README.md b/README.md\n'
                         '--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n'
                         '-different upstream\n+local patch\n')
        manifest['patches'] = [{'path': str(patch), 'sha256': hashlib.sha256(patch.read_bytes()).hexdigest()}]
        with self.assertRaises(subprocess.CalledProcessError):
            build(self.archive, self.output, manifest)
        self.assertEqual((self.output / 'README.md').read_text(), 'upstream\n')
