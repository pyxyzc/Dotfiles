#!/usr/bin/env python3
"""Time process creation to a post-VimEnter probe redraw in a real PTY.

Every sample starts a new Vim. This does not wait for language-server readiness
or include a physical terminal's display/network delay. The probe includes
timer scheduling and temporary-file handoff, so it is an upper bound on the
initial screen's readiness rather than pure vimrc parsing time.
"""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import select
import statistics
import struct
import subprocess
import tempfile
import termios
import time

from test_vim import ROOT, VIM, quoted


def benchmark(config, rounds=5, files=1000):
    with tempfile.TemporaryDirectory(prefix='vim-startup-latency-') as temporary:
        work = Path(temporary).resolve()
        directory = work / 'project'
        directory.mkdir()
        source = directory / 'main.py'
        source.write_text('def main():\n    return 42\n')
        large = work / 'large.py'
        large.write_text('value = 42\n' * 200000)
        for number in range(files):
            (directory / f'entry_{number:05d}.txt').touch()
        report = work / 'ready.json'
        script = work / 'probe.vim'
        script.write_text(r'''
set nomore
function! StartupProbe(timer) abort
  redraw
  call writefile([json_encode({'filetype': &filetype, 'error': v:errmsg})],
        \ ''' + quoted(report) + r''', 'S')
endfunction
autocmd VimEnter * call timer_start(0, function('StartupProbe'))
''')
        scenarios = {'baseline': ('NONE', [], ''),
                     'home': (str(config), [], 'vimdashboard'),
                     'python': (str(config), [str(source)], 'python'),
                     'large_file': (str(config), [str(large)], 'text'),
                     'directory': (str(config), [str(directory)], 'netrw')}
        metrics = {}
        for name, (vimrc, arguments, filetype) in scenarios.items():
            samples = []
            errors = set()
            for _ in range(rounds):
                report.unlink(missing_ok=True)
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
                command = [VIM, '-Nu', vimrc, '-i', 'NONE', '-n',
                           '--cmd', 'let g:vimrc_lite_osc52 = 0',
                           '--cmd', 'let g:vimrc_lite_clipboard_yank = 0',
                           '--cmd', 'source ' + str(script), *arguments]
                started = time.perf_counter()
                process = subprocess.Popen(
                    command, cwd=work, stdin=slave, stdout=slave, stderr=slave,
                    env=dict(os.environ, TERM='xterm-256color',
                             XDG_STATE_HOME=str(work / 'state')))
                os.close(slave)
                output = bytearray()
                try:
                    deadline = started + 10
                    while not report.exists():
                        if process.poll() is not None or time.perf_counter() > deadline:
                            raise AssertionError(f'{name}: startup failed: {bytes(output[-1000:])!r}')
                        if select.select([master], [], [], .001)[0]:
                            output.extend(os.read(master, 65536))
                    elapsed = (time.perf_counter() - started) * 1000
                    state = json.loads(report.read_text())
                    assert state['filetype'] == filetype, (name, state)
                    if state['error']:
                        errors.add(state['error'])
                    samples.append(elapsed)
                    os.write(master, b':qa!\r')
                    process.wait(timeout=3)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
            metrics[name] = {'first_ms': round(samples[0], 2),
                             'median_ms': round(statistics.median(samples), 2),
                             'p95_ms': round(sorted(samples)[math.ceil(rounds * .95) - 1], 2),
                             'max_ms': round(max(samples), 2)}
            if errors:
                metrics[name]['startup_errors'] = sorted(errors)
        return metrics


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--files', type=int, default=1000)
    args = parser.parse_args()
    if args.rounds < 1 or args.files < 0:
        parser.error('rounds must be positive; files must be nonnegative')
    print(json.dumps(benchmark(args.config.resolve(), args.rounds, args.files), indent=2))
