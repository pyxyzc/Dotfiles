#!/usr/bin/env python3
"""Real-key PTY benchmark. All fixtures/state stay in a temporary directory."""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import re
import select
import shutil
import socket
import statistics
import struct
import subprocess
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def benchmark(config, rounds=30, files=10000, suffix='.cpp', size=0, split=False,
              lsp=True, modes=('ff', 'fp', 'fr'), profile=None, query_cycles=3,
              key_delay_ms=0):
    with tempfile.TemporaryDirectory(prefix='vim-search-latency-') as directory:
        work = Path(directory)
        project = work / 'project'
        project.mkdir()
        (project / '.git').mkdir()
        for number in range(files):
            (project / f'entry_{number:05d}.txt').touch()
        target = project / ('unique_target' + suffix)
        target.write_text('int benchmark_unique = 1;\n' + '/* padding */\n' * (size // 14))
        second = project / ('unique_second' + suffix)
        second.write_text('int benchmark_second = 2;\n')
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        address = '127.0.0.1:' + str(listener.getsockname()[1])
        startup = work / 'startup'
        script = work / 'probe.vim'
        script.write_text(r'''
set nomore
let v:oldfiles = [''' + quote(target) + ', ' + quote(second) + r''']
let g:probe_last = ''
let g:probe_channel = ch_open(''' + quote(address) + r''', {'mode': 'raw'})
let g:probe_debug = ''' + ('1' if profile else '0') + r'''
let g:probe_search_sid = str2nr(matchstr(execute('command VimFind'), '<SNR>\zs\d\+'))
function! Probe(timer) abort
  let terminals = filter(getbufinfo(), 'getbufvar(v:val.bufnr, "&buftype") ==# "terminal"')
  let screen = ''
  let phase = {}
  if !empty(terminals)
    let terminal = terminals[0].bufnr
    let screen = join(map(range(1, term_getsize(terminal)[0]),
          \ 'term_getline(terminal, v:val)'), "\n")
    if g:probe_debug && exists('*getscriptinfo')
      let active = get(getscriptinfo({'sid': g:probe_search_sid})[0].variables, 'active', {})
      let phase = {'status': get(active, 'status', 'unknown'), 'closed': get(active, 'closed', 0),
            \ 'finish_timer': get(active, 'finish_timer', -1),
            \ 'job': string(term_getjob(terminal)),
            \ 'channel': ch_info(job_getchannel(term_getjob(terminal)))}
    endif
  endif
  let value = json_encode({'terminal': !empty(terminals), 'screen': screen,
        \ 'path': expand('%:p'), 'line': getline(1), 'mode': mode(1),
        \ 'filetype': &filetype, 'foldmethod': &foldmethod, 'phase': phase})
  if value !=# g:probe_last
    call ch_sendraw(g:probe_channel, value . "\n")
    let g:probe_last = value
  endif
endfunction
call timer_start(2, function('Probe'), {'repeat': -1})
''')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        env = dict(os.environ, TERM='xterm-256color', XDG_STATE_HOME=str(work / 'history'))
        command = ['vim', '-Nu', str(config), '-i', 'NONE', '-n',
                   '--cmd', 'let g:vimrc_lite_clipboard_yank = 0',
                   '--cmd', 'let g:vimrc_lite_osc52 = 0',
                   '--cmd', f'autocmd VimEnter * call writefile([], {quote(startup)})']
        if not lsp:
            command += ['--cmd', 'let g:vimrc_lite_lsp = 0']
        if profile:
            command += ['--cmd', "execute 'profile start ' . fnameescape(" + quote(profile) + ')',
                        '--cmd', 'profile func *']
        process = subprocess.Popen(command, cwd=project, env=env,
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = bytearray()
        connection = None
        pending = b''
        current_state = {}

        def pump():
            nonlocal connection, pending, current_state
            readable = select.select([master, connection or listener], [], [], 0.001)[0]
            if master in readable:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    pass
            if connection is None and listener in readable:
                connection, _ = listener.accept()
            elif connection in readable:
                pending += connection.recv(65536)
                while b'\n' in pending:
                    record, pending = pending.split(b'\n', 1)
                    current_state = json.loads(record)

        def wait(check, timeout=8, label=''):
            deadline = time.monotonic() + timeout
            diagnosed = False
            while time.monotonic() < deadline and process.poll() is None:
                pump()
                current = current_state
                if check(current):
                    return current
                if profile and label and not diagnosed and time.monotonic() > deadline - timeout + .5:
                    diagnosed = True
                    rows = subprocess.check_output(
                        ['ps', '-eo', 'pid,ppid,stat,wchan:30,args'], text=True).splitlines()[1:]
                    owned = {process.pid}
                    while True:
                        found = {int(row.split(None, 2)[0]) for row in rows
                                 if int(row.split(None, 2)[1]) in owned}
                        if found <= owned:
                            break
                        owned |= found
                    print('SLOW', label, {key: current.get(key) for key in ('terminal', 'path', 'mode', 'phase')},
                          '\n' + '\n'.join(row for row in rows if int(row.split(None, 1)[0]) in owned),
                          flush=True)
            raise AssertionError(f'timed out; state={current!r}; output={bytes(output[-1000:])!r}')

        def send(keys):
            os.write(master, keys)

        def type_query(query, erase=0):
            if not key_delay_ms:
                start = time.perf_counter()
                send(b'\x7f' * erase + query.encode())
                return start
            send(b'\x7f' * erase)
            for index, character in enumerate(query):
                start = time.perf_counter()
                send(character.encode())
                if index + 1 < len(query):
                    deadline = start + key_delay_ms / 1000
                    while time.perf_counter() < deadline:
                        pump()
            # Human typing time is excluded; measure from the final keystroke.
            return start

        samples = {mode: {key: [] for key in
                         ('startup', 'results', 'preview', 'reload', 'reload_preview', 'preview_switch', 'open',
                          'edit_key', 'open_edit')}
                   for mode in ('ff', 'fp', 'fr')}
        try:
            wait(lambda _: startup.exists())
            send(f':source {script}\r'.encode())
            wait(lambda s: bool(s))
            if split:
                send(b':vsplit\r')
            for mode, prompt in [('ff', 'Files>'), ('fp', 'Live grep>'), ('fr', 'Recent>')]:
                if mode not in modes:
                    continue
                for attempt in range(rounds + 1):
                    # Start from an unloaded target every time, retaining the Vim process.
                    send(b':silent! %bwipeout!\r')
                    wait(lambda s: not s.get('terminal') and s.get('path') != str(target))
                    start = time.perf_counter()
                    send((' ' + mode).encode())
                    wait(lambda s: prompt in s.get('screen', ''))
                    samples[mode]['startup'].append((time.perf_counter() - start) * 1000)
                    if mode == 'fr':
                        wait(lambda s: 'int benchmark_unique' in s.get('screen', ''))
                        start = time.perf_counter()
                        send(b'\x0b')
                        wait(lambda s: 'int benchmark_second' in s.get('screen', ''))
                        samples[mode]['preview_switch'].append((time.perf_counter() - start) * 1000)
                        send(b'\x0a')
                        wait(lambda s: 'int benchmark_unique' in s.get('screen', ''))
                    query = 'benchmark_unique' if mode == 'fp' else 'unique_target'
                    query_start = type_query(query)
                    wait(lambda s: bool(re.search(r'\b1/\d+\b', s.get('screen', '')))
                         and prompt + ' ' + query in s.get('screen', '')
                         and ('unique_target' in s.get('screen', '') or mode == 'fp'))
                    samples[mode]['results'].append((time.perf_counter() - query_start) * 1000)
                    if mode != 'ff':
                        wait(lambda s: 'int benchmark_unique' in s.get('screen', ''))
                        samples[mode]['preview'].append((time.perf_counter() - query_start) * 1000)
                    if mode == 'fp':
                        # Reuse the same fzf process: reload throttling can grow
                        # over time even when the first query is fast.
                        for _ in range(query_cycles):
                            for word in ('second', 'unique'):
                                replacement = 'benchmark_' + word
                                start = type_query(replacement, erase=len(query))
                                wait(lambda s: 'unique_' + ('target' if word == 'unique' else 'second')
                                     in s.get('screen', '')
                                     and 'Live grep> ' + replacement in s.get('screen', '')
                                     and bool(re.search(r'\b1/1\b', s.get('screen', ''))))
                                samples[mode]['reload'].append((time.perf_counter() - start) * 1000)
                                wait(lambda s: 'int benchmark_' + word in s.get('screen', ''))
                                samples[mode]['reload_preview'].append((time.perf_counter() - start) * 1000)
                                query = replacement
                    start = time.perf_counter()
                    send(b'\r')
                    wait(lambda s: not s.get('terminal') and s.get('path') == str(target),
                         label=mode + ':open')
                    editing_start = time.perf_counter()
                    samples[mode]['open'].append((editing_start - start) * 1000)
                    send(b'iX')
                    wait(lambda s: 'X' in s.get('line', '') and s.get('mode', '').startswith('i'))
                    samples[mode]['edit_key'].append((time.perf_counter() - editing_start) * 1000)
                    samples[mode]['open_edit'].append((time.perf_counter() - start) * 1000)
                    send(b'\x03')
                    wait(lambda s: s.get('mode') == 'n')
                print(mode, json.dumps({key: {
                    'first_ms': round(values[0], 2),
                    'median_ms': round(statistics.median(values[1:]), 2),
                    'p95_ms': round(sorted(values[1:])[math.ceil(len(values[1:]) * .95) - 1], 2),
                    'max_ms': round(max(values), 2),
                } for key, values in samples[mode].items() if values}), flush=True)
            send(b':qa!\r')
            process.wait(timeout=3)
            return samples
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            if connection is not None:
                connection.close()
            listener.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--rounds', type=int, default=30)
    parser.add_argument('--files', type=int, default=10000)
    parser.add_argument('--size', type=int, default=0)
    parser.add_argument('--no-lsp', action='store_true')
    parser.add_argument('--mode', action='append', choices=['ff', 'fp', 'fr'])
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--query-cycles', type=int, default=3,
                        help='alternate live queries within each picker to catch reload throttling')
    parser.add_argument('--max-ms', type=float,
                        help='fail if any measured latency, including first use, reaches this limit')
    parser.add_argument('--key-delay-ms', type=float, default=0,
                        help='type query characters separately; latency starts at the last key')
    args = parser.parse_args()
    if args.rounds < 1 or args.files < 0 or args.size < 0 or args.query_cycles < 0:
        parser.error('rounds must be positive; files, size and query cycles must be nonnegative')
    if args.max_ms is not None and args.max_ms <= 0:
        parser.error('max-ms must be positive')
    if args.key_delay_ms < 0:
        parser.error('key-delay-ms must be nonnegative')
    for executable in ('vim', 'fzf', 'gawk', 'rg'):
        if not shutil.which(executable):
            parser.error('missing executable: ' + executable)
    if not (shutil.which('fd') or shutil.which('fdfind')):
        parser.error('missing executable: fd/fdfind')
    samples = benchmark(args.config.resolve(), args.rounds, args.files, size=args.size,
                        lsp=not args.no_lsp, modes=args.mode or ('ff', 'fp', 'fr'),
                        profile=args.profile, query_cycles=args.query_cycles,
                        key_delay_ms=args.key_delay_ms)
    if args.max_ms is not None:
        failures = [f'{mode}.{metric}: {max(values):.2f} ms'
                    for mode, metrics in samples.items() for metric, values in metrics.items()
                    if values and max(values) >= args.max_ms]
        if failures:
            raise SystemExit('FAIL (limit ' + str(args.max_ms) + ' ms): ' + '; '.join(failures))
        print(f'PASS: every measured latency < {args.max_ms:g} ms', flush=True)
