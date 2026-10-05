#!/usr/bin/env python3
"""Measure real PTY editor interactions against observed Vim state (milliseconds)."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import statistics
import struct
import subprocess
import tempfile
import termios
import time

from operation_latency import ROOT, quote
from test_vim import VIM


def benchmark(config, rounds=5, profile=None, completion_lines=0):
    with tempfile.TemporaryDirectory(prefix='vim-editor-latency-') as temporary:
        work = Path(temporary)
        source = work / 'main.cpp'
        source.write_text('int main() {\n    return 0;\n}\n')
        other = work / 'other.txt'
        other.write_text(''.join(f'alpha_{index:08d}\n' for index in range(completion_lines))
                         if completion_lines else 'alpha alphabet\n')
        subprocess.run(['git', 'init', '-q', str(work)], check=True)
        subprocess.run(['git', '-C', str(work), 'add', '.'], check=True)
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        script = work / 'probe.vim'
        script.write_text(r'''
set nomore shell=/bin/sh
call setqflist([{'filename': 'main.cpp', 'lnum': 2, 'text': 'latency probe'}])
let g:probe_channel = ch_open(''' + quote('127.0.0.1:' + str(listener.getsockname()[1])) + r''',
      \ {'mode': 'raw'})
let g:probe_last = ''
function! Probe(timer) abort
  let value = json_encode({'name': expand('%:t'), 'line': getline('.'),
        \ 'lnum': line('.'), 'col': col('.'), 'mode': mode(1), 'modified': &modified,
        \ 'filetype': &filetype, 'windows': winnr('$'), 'tabs': tabpagenr('$'),
        \ 'menu': pumvisible(), 'buftype': &buftype, 'commentstring': &commentstring,
        \ 'winid': win_getid(),
        \ 'terminal_status': &buftype ==# 'terminal' ? term_getstatus(bufnr('%')) : ''})
  if value !=# g:probe_last
    call ch_sendraw(g:probe_channel, value . "\n")
    let g:probe_last = value
  endif
endfunction
call timer_start(2, function('Probe'), {'repeat': -1})
''')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        command = [VIM, '-Nu', str(config), '-i', 'NONE', '-n',
                   '--cmd', 'let g:vimrc_lite_osc52 = 0',
                   '--cmd', 'let g:vimrc_lite_clipboard_yank = 0',
                   '--cmd', 'let g:vimrc_lite_lsp = 0',
                   '--cmd', 'autocmd VimEnter * source ' + str(script), str(source), str(other)]
        if profile:
            command[1:1] = ['--cmd', 'profile start ' + str(profile),
                            '--cmd', 'profile func *', '--cmd', 'profile file *']
        process = subprocess.Popen(command, cwd=work,
                                   env=dict(os.environ, TERM='xterm-256color',
                                            XDG_STATE_HOME=str(work / 'state')),
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        connection = None
        pending = b''
        state = {}
        screen = bytearray()
        sequence = 0
        samples = {}

        def wait(check, after=-1):
            nonlocal connection, pending, state, sequence
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and process.poll() is None:
                readable = select.select([master, connection or listener], [], [], .002)[0]
                if master in readable:
                    try:
                        screen.extend(os.read(master, 65536))
                    except OSError:
                        pass
                if connection is None and listener in readable:
                    connection, _ = listener.accept()
                elif connection in readable:
                    pending += connection.recv(65536)
                    while b'\n' in pending:
                        record, pending = pending.split(b'\n', 1)
                        state = json.loads(record)
                        sequence += 1
                if sequence > after and check(state):
                    return
            raise AssertionError(f'timed out: {state!r}; terminal={bytes(screen[-1000:])!r}')

        def action(name, keys, check):
            before = sequence
            started = time.perf_counter()
            os.write(master, keys)
            wait(check, before)
            if name:
                samples.setdefault(name, []).append((time.perf_counter() - started) * 1000)

        try:
            wait(lambda s: s.get('name') == source.name)
            for _ in range(rounds):
                action(None, b':2\r', lambda s: s['lnum'] == 2 and s['mode'] == 'n')
                action('insert_key', b'A ', lambda s: s['mode'].startswith('i') and s['line'].endswith(' '))
                action('insert_escape', b'\x1b', lambda s: s['mode'] == 'n')
                original = state['line']
                token = state['commentstring'].partition('%s')[0].strip()
                if not token:
                    raise AssertionError('C++ commentstring has no comment prefix')
                action('comment', b'gcc', lambda s: s['line'].lstrip().startswith(token))
                action('uncomment', b'gcc', lambda s: s['line'] == original)
                action('trim_whitespace', b' bw', lambda s: not s['line'].endswith(' '))
                action('save', b'\x13', lambda s: not s['modified'] and s['mode'] == 'n')
                action('buffer_next', b'L', lambda s: s['name'] == other.name)
                action('buffer_previous', b'H', lambda s: s['name'] == source.name)
                action('split', b' v', lambda s: s['windows'] == 2)
                action('close_split', b':close\r', lambda s: s['windows'] == 1 and s['mode'] == 'n')
                action('tree_open', b' e', lambda s: s['filetype'] == 'netrw')
                action('tree_close', b' e', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('terminal_open', b' ;', lambda s: s['buftype'] == 'terminal' and s['mode'] == 't')
                action('terminal_exit', b'exit\r', lambda s: s['name'] == source.name and s['tabs'] == 1)
                action('quickfix_open', b' xQ', lambda s: s['filetype'] == 'qf')
                action('quickfix_close', b' xQ', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('help_open', b':help help\r', lambda s: s['filetype'] == 'help')
                action('help_close', b'q', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('keys_open', b' ?', lambda s: s['buftype'] == 'nofile' and s['windows'] == 2)
                action('keys_close', b'q', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('health_open', b' ch', lambda s: s['buftype'] == 'nofile' and s['windows'] == 2)
                action('health_close', b'q', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('terminal_toggle_open', b' tt', lambda s: s['buftype'] == 'terminal' and s['mode'] == 't')
                action('terminal_toggle_hide', b'\x07', lambda s: s['name'] == source.name and s['windows'] == 1)
                action('terminal_toggle_reopen', b' tt', lambda s: s['buftype'] == 'terminal' and s['mode'] == 't')
                action('terminal_toggle_exit', b'exit\r', lambda s: s['name'] == source.name and s['windows'] == 1)
                previous_window = state['winid']
                action('session_save_restore', b':VimSessionSave\r:VimSessionLoad\r',
                       lambda s: s['name'] == source.name and s['winid'] != previous_window)
                action('dashboard_open', b':Dashboard\r', lambda s: s['filetype'] == 'vimdashboard')
                action('dashboard_return', b' 1', lambda s: s['name'] == source.name)
                if completion_lines:
                    action('automatic_completion', b'Goal', lambda s: s['menu'])
                    action('completion_cancel', b'\x05\x1b', lambda s: s['mode'] == 'n')
                action('command_enter', b':', lambda s: s['mode'] == 'c')
                action('command_escape', b'\x1b', lambda s: s['mode'] == 'n')
            os.write(master, b':qa!\r')
            process.wait(timeout=3)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if connection is not None:
                connection.close()
            listener.close()
            os.close(master)
        return {name: {'first_ms': round(values[0], 2),
                       'median_ms': round(statistics.median(values), 2),
                       'max_ms': round(max(values), 2)} for name, values in samples.items()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--completion-lines', type=int, default=0,
                        help='load this many unique words in another buffer and time completion')
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('rounds must be positive')
    if args.completion_lines < 0:
        parser.error('completion-lines must be nonnegative')
    print(json.dumps(benchmark(args.config.resolve(), args.rounds, args.profile,
                               args.completion_lines), indent=2))
