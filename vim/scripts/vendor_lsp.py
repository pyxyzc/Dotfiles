#!/usr/bin/env python3
"""Rebuild, verify, or upgrade vim-lsp using a checked archive and local patches."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'patches/vim-lsp/manifest.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(archive, destination, manifest):
    if digest(archive) != manifest['archive_sha256']:
        raise ValueError('Archive SHA-256 mismatch')
    prefix = 'vim-lsp-' + manifest['commit']
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != prefix or '..' in parts:
                raise ValueError('Archive has an unexpected root or unsafe path')
            if len(parts) < 2 or parts[1] not in manifest['paths']:
                continue
            path = destination.joinpath(*parts[1:])
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source:
                    path.write_bytes(source.read())
            else:
                raise ValueError('Curated source contains a link or special file')
    for path in manifest['paths']:
        if not (destination / path).exists():
            raise ValueError('Missing curated source: ' + path)
    for item in manifest['patches']:
        patch = ROOT / item['path']
        if digest(patch) != item['sha256']:
            raise ValueError('Patch SHA-256 mismatch: ' + item['path'])
        # Git needs no repository for applying a patch to a plain directory.
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=destination,
                       check=True, capture_output=True, text=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=destination,
                       check=True, capture_output=True, text=True)


def contents(directory):
    paths = list(directory.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise ValueError('Vendored source contains a symlink')
    return {str(path.relative_to(directory)): digest(path)
            for path in paths if path.is_file() and path.relative_to(directory) != Path('SOURCE.md')}


def accept_latency(before, after, max_regression):
    for metric in before:
        if metric == 'startup_to_ready' or metric.startswith('initialize'):
            continue
        bound = max(100, before[metric]['median_ms'] * max_regression)
        if after[metric]['median_ms'] > bound:
            raise ValueError('LSP latency regression: ' + metric)


def validate(plugin, work, max_regression):
    config = work / 'config'
    shutil.copytree(ROOT, config, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.rmtree(config / 'vendor/vim-lsp')
    shutil.copytree(plugin, config / 'vendor/vim-lsp')
    shutil.copyfile(ROOT / 'vendor/vim-lsp/SOURCE.md', config / 'vendor/vim-lsp/SOURCE.md')
    subprocess.run([sys.executable, str(config / 'tests/run.py')], check=True)
    for binary in ['clangd', 'pyright-langserver']:
        if not shutil.which(binary):
            raise ValueError('Performance acceptance requires ' + binary)
    sys.path.insert(0, str(ROOT / 'tests'))
    from lsp_latency import benchmark
    for language in ['cpp', 'python']:
        before = benchmark(language, ROOT / '.vimrc', 5, True)
        after = benchmark(language, config / '.vimrc', 5, True)
        print(json.dumps({'language': language, 'before': before, 'after': after}), flush=True)
        accept_latency(before, after, max_regression)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['verify', 'stage', 'upgrade'])
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--commit', help='Full upstream commit; defaults to the manifest')
    parser.add_argument('--sha256', help='Expected archive digest; defaults to the manifest')
    parser.add_argument('--output', type=Path, help='Destination for stage')
    parser.add_argument('--max-regression', type=float, default=2.0)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    if bool(args.commit) != bool(args.sha256):
        parser.error('Specify --commit and --sha256 together')
    if args.commit:
        if not re.fullmatch('[0-9a-f]{40}', args.commit) or not re.fullmatch('[0-9a-f]{64}', args.sha256):
            parser.error('Use a complete commit and SHA-256 digest')
        manifest.update(commit=args.commit, archive_sha256=args.sha256)
    if not math.isfinite(args.max_regression) or args.max_regression < 1:
        parser.error('--max-regression must be at least 1')
    if args.action == 'stage' and (not args.output or args.output.exists()):
        parser.error('stage requires an --output path that does not exist')
    if args.action == 'verify' and args.commit:
        parser.error('verify uses the current manifest')
    with tempfile.TemporaryDirectory(prefix='vim-lsp-rebuild-') as temporary:
        work = Path(temporary)
        plugin = work / 'plugin'
        plugin.mkdir()
        build(args.archive.resolve(), plugin, manifest)
        if args.action == 'verify':
            if contents(plugin) != contents(ROOT / 'vendor/vim-lsp'):
                raise ValueError('Vendored snapshot differs from the replayed patches')
            print('Verified: archive, patches, and complete vendored source match')
        elif args.action == 'stage':
            shutil.copytree(plugin, args.output)
            print('Staged: ' + str(args.output))
        else:
            validate(plugin, work, args.max_regression)
            source = (ROOT / 'vendor/vim-lsp/SOURCE.md').read_text()
            source = source.replace(json.loads(MANIFEST.read_text())['commit'], manifest['commit'])
            source = source.replace(json.loads(MANIFEST.read_text())['archive_sha256'],
                                    manifest['archive_sha256'])
            (plugin / 'SOURCE.md').write_text(source)
            # Keep rollback on the destination filesystem until both artifacts are published.
            vendor = ROOT / 'vendor/vim-lsp'
            with tempfile.TemporaryDirectory(prefix='.vim-lsp-upgrade-', dir=vendor.parent) as staging:
                staging = Path(staging)
                shutil.copytree(plugin, staging / 'new')
                old_manifest = MANIFEST.read_bytes()
                os.replace(vendor, staging / 'old')
                try:
                    os.replace(staging / 'new', vendor)
                    metadata = staging / 'manifest.json'
                    metadata.write_text(json.dumps(manifest, indent=2) + '\n')
                    os.replace(metadata, MANIFEST)
                except BaseException:
                    if vendor.exists():
                        shutil.rmtree(vendor)
                    os.replace(staging / 'old', vendor)
                    MANIFEST.write_bytes(old_manifest)
                    raise
            print('Upgraded after full regressions and real Unicode LSP performance acceptance')
            print('Install with: bash vim-install.sh --config-only')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, 'stderr', None)
        raise SystemExit(detail or str(error))
