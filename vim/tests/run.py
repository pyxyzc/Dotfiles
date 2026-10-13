#!/usr/bin/env python3
"""Run the Vim suite, including when vim/ is copied as a standalone directory."""

from pathlib import Path
import subprocess
import sys

tests = Path(__file__).resolve().parent
command = [sys.executable, '-m', 'unittest']
command += sys.argv[1:] or ['discover', '-s', '.', '-p', 'test_*.py']
raise SystemExit(subprocess.run(command, cwd=tests).returncode)
