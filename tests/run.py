#!/usr/bin/env python3
"""Run isolated Dotfiles suites without installing packages or downloading tools."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=['all', 'vim', 'tmux', 'lazygit'], default='all')
    parser.add_argument('test', nargs='*', help='Optional unittest names within one suite')
    args = parser.parse_args()
    if args.test and args.suite == 'all':
        parser.error('Select one --suite when specifying test names')
    suites = ['vim', 'tmux', 'lazygit'] if args.suite == 'all' else [args.suite]
    failed = []
    for suite in suites:
        print(f'Running {suite} tests', flush=True)
        tests = ROOT / suite / 'tests'
        command = [sys.executable, '-m', 'unittest']
        command += args.test or ['discover', '-s', '.', '-p', 'test_*.py']
        if subprocess.run(command, cwd=tests).returncode:
            failed.append(suite)
    if failed:
        print('Failed suites: ' + ', '.join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
