#!/usr/bin/env python3
"""Measure which-key input through a real PTY and observed Vim state (ms)."""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import select
import signal
import socket
import statistics
import struct
import subprocess
import tempfile
import termios
import time

from test_vim import ROOT, VIM, quoted


def menu_shown(state, prefix):
    label = prefix.replace('<Space>', 'SPC ').rstrip()
    return (state['keys']['popup'] > 0 and state['keys']['prefix'] == prefix
            and state['popup_title'].startswith(label + '  /'))


class KeySession:
    """A test-only 2 ms observer; the editor feature itself never polls."""

    def __init__(self, enabled=True, delay=100, timeoutlen=1000, config=None, before=(),
                 columns=100, rows=30):
        self.temp = tempfile.TemporaryDirectory(prefix='vim-which-key-')
        self.work = Path(self.temp.name)
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.connection = None
        self.pending = b''
        self.state = {}
        self.history = []
        self.screen = bytearray()
        self.sequence = 0
        self.command_id = 0
        source = self.work / 'input.txt'
        source.write_text('one two three four five\nsecond line\nthird line\n')
        script = self.work / 'probe.vim'
        script.write_text(r'''
set nomore
let g:key_hits = 0
let g:key_register = ''
let g:key_expression = 0
let g:key_command = 0
function! KeyHit() abort
  let g:key_hits += v:count1
  let g:key_register = v:register
endfunction
function! KeyExpression() abort
  let g:key_expression += 1
  return 'l'
endfunction
nnoremap <silent> <leader>ua :<C-u>call KeyHit()<CR>
xnoremap <silent> <leader>ua U
nnoremap <expr> <leader>ue KeyExpression()
nmap <leader>ur <leader>ua
nnoremap <leader>uv <Plug>(KeyTest)
nnoremap <Plug>(KeyTest) :<C-u>call KeyHit()<CR>
let g:key_channel = ch_open(''' + quoted('127.0.0.1:' + str(self.listener.getsockname()[1])) + r''',
      \ {'mode': 'raw'})
let g:key_last = ''
function! KeyProbe(timer) abort
  let status = VimWhichKeyStatus()
  let popup = status.popup
  let value = json_encode({'mode': mode(1), 'hits': g:key_hits, 'register': g:key_register,
        \ 'expression': g:key_expression, 'command': g:key_command, 'keys': status,
        \ 'popup_lines': popup ? getbufline(winbufnr(popup), 1, '$') : [],
        \ 'popup_title': popup ? get(getbufline(winbufnr(popup), 1), 0, '') : '',
        \ 'popup_position': popup ? popup_getpos(popup) : {},
        \ 'timeout': [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen],
        \ 'screen_size': [&columns, &lines],
        \ 'lnum': line('.'), 'col': col('.'), 'lines': getline(1, '$'),
        \ 'filetype': &filetype, 'buffer': bufnr('%'), 'windows': winnr('$'),
        \ 'error': v:errmsg})
  if value !=# g:key_last
    call ch_sendraw(g:key_channel, value . "\n")
    let g:key_last = value
  endif
endfunction
VimWhichKeyRefresh
call timer_start(2, function('KeyProbe'), {'repeat': -1})
''')
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        command = [VIM, '-Nu', str(config or ROOT / '.vimrc'), '-i', 'NONE', '-n',
                   '--cmd', 'let g:vimrc_lite_local_config = 0',
                   '--cmd', 'let g:vimrc_lite_lsp = 0',
                   '--cmd', 'let g:vimrc_lite_osc52 = 0',
                   '--cmd', 'let g:vimrc_lite_clipboard_yank = 0',
                   '--cmd', f'let g:vimrc_lite_which_key = {int(enabled)}',
                   '--cmd', f'let g:vimrc_lite_which_key_delay = {delay}',
                   '--cmd', f'set timeout timeoutlen={timeoutlen}',
                   '--cmd', 'autocmd VimEnter * source ' + str(script)]
        for setting in before:
            command += ['--cmd', setting]
        self.process = subprocess.Popen(
            command + [str(source)], cwd=self.work, stdin=slave, stdout=slave, stderr=slave,
            env=dict(os.environ, TERM='xterm-256color', XDG_STATE_HOME=str(self.work / 'state')),
        )
        os.close(slave)
        self.wait(lambda state: state.get('command') == 0)

    def _read(self, timeout):
        readable = select.select([self.master, self.connection or self.listener], [], [], timeout)[0]
        if self.master in readable:
            try:
                self.screen.extend(os.read(self.master, 65536))
            except OSError:
                pass
        if self.connection is None and self.listener in readable:
            self.connection, _ = self.listener.accept()
        elif self.connection is not None and self.connection in readable:
            self.pending += self.connection.recv(65536)
            while b'\n' in self.pending:
                record, self.pending = self.pending.split(b'\n', 1)
                self.state = json.loads(record)
                self.sequence += 1
                self.history.append((time.perf_counter(), self.state))

    def wait(self, check, after=-1, timeout=4):
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline and self.process.poll() is None:
            self._read(.002)
            if self.sequence > after and check(self.state):
                if self.state['error']:
                    raise AssertionError(self.state)
                return self.state
        raise AssertionError(f'timed out: {self.state!r}; terminal={bytes(self.screen[-500:])!r}')

    def pump(self, seconds):
        deadline = time.perf_counter() + seconds
        while time.perf_counter() < deadline:
            self._read(min(.002, max(0, deadline - time.perf_counter())))

    def resize(self, columns, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, columns, 0, 0))
        self.process.send_signal(signal.SIGWINCH)
        self.wait(lambda state: state['screen_size'] == [columns, rows])

    def send(self, keys):
        os.write(self.master, keys.encode() if isinstance(keys, str) else keys)

    def action(self, keys, check):
        before = self.sequence
        started = time.perf_counter()
        self.send(keys)
        self.wait(check, after=before)
        return (time.perf_counter() - started) * 1000

    def command(self, command):
        self.command_id += 1
        request = self.command_id
        self.action(':execute ' + quoted(command) + f' | let g:key_command = {request}\r',
                    lambda state: state['command'] == request and state['mode'] == 'n')

    def close(self):
        if self.process.poll() is None:
            self.send(b'\x1b:qa!\r')
            try:
                self.process.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.connection is not None:
            self.connection.close()
        self.listener.close()
        os.close(self.master)
        self.temp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def summary(values):
    return {'first_ms': round(values[0], 3),
            'median_ms': round(statistics.median(values), 3),
            'p95_ms': round(sorted(values)[math.ceil(len(values) * .95) - 1], 3),
            'max_ms': round(max(values), 3)}


def benchmark(rounds=30, delay=200, mappings=0):
    result = {}
    for enabled in (False, True):
        with KeySession(enabled=enabled, delay=delay) as session:
            if mappings:
                session.command(f"for index in range({mappings}) | "
                                "execute 'nnoremap <Space>u' . index . "
                                "'z :let g:key_hits += 1<CR>' | endfor")
                session.command('VimWhichKeyRefresh')
            samples = {'burst_mapping': [], 'split_mapping': [], 'ordinary_motion': [],
                       'insert_key': [], 'cancel': []}
            if enabled:
                samples.update({'popup': [], 'visible_mapping': [], 'subgroup': []})
            for _ in range(rounds):
                hits = session.state['hits']
                samples['burst_mapping'].append(session.action(
                    b' ua', lambda state: state['hits'] == hits + 1))
                session.send(b' ')
                session.pump(.01)
                hits = session.state['hits']
                samples['split_mapping'].append(session.action(
                    b'ua', lambda state: state['hits'] == hits + 1))
                session.command('call cursor(1, 1)')
                samples['ordinary_motion'].append(session.action(
                    b'l', lambda state: state['col'] == 2 and state['mode'] == 'n'))
                session.send(b'A')
                session.wait(lambda state: state['mode'] == 'i')
                old = session.state['lines'][0]
                samples['insert_key'].append(session.action(
                    b'x', lambda state: state['lines'][0] == old + 'x'))
                session.action(b'\x1b', lambda state: state['mode'] == 'n')
                if enabled:
                    samples['popup'].append(session.action(
                        b' ', lambda state: state['keys']['popup'] > 0))
                    samples['subgroup'].append(session.action(
                        b'u', lambda state: menu_shown(state, '<Space>u')))
                    hits = session.state['hits']
                    samples['visible_mapping'].append(session.action(
                        b'a', lambda state: state['hits'] == hits + 1
                        and not state['keys']['pending']))
                session.send(b' ')
                session.pump(.01)
                samples['cancel'].append(session.action(
                    b'\x1b', lambda state: not state['keys']['pending'] and state['mode'] == 'n'))
            result['enabled' if enabled else 'disabled'] = {
                name: summary(values) for name, values in samples.items()}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rounds', type=int, default=30)
    parser.add_argument('--delay', type=int, default=200)
    parser.add_argument('--mappings', type=int, default=0, help='additional leader mappings')
    args = parser.parse_args()
    if args.rounds < 1 or args.delay < 0 or args.mappings < 0:
        parser.error('rounds must be positive; delay and mappings must be nonnegative')
    print(json.dumps(benchmark(args.rounds, args.delay, args.mappings), indent=2))
