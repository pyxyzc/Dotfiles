#!/usr/bin/env python3
"""Real PTY Markdown latency, observed after redraw, with optional strict gates."""

import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import pty
import platform
import select
import socket
import statistics
import struct
import subprocess
import tempfile
import termios
import time

from test_vim import ROOT, VIM, quoted


def document(case, lines):
    beginning = ['# 中文标题', '- [ ] probe', '', '| 名称 | value |',
                 '| :--- | ---: |', '| 中文 | x |', '', 'paragraph']
    if case in ('long-line', 'syntax-stress'):
        text = 'a' * 120000 if case == 'long-line' else '*[x](`code`)* ' * 9000 + '<!-- end -->'
        return beginning + [text, '', '# end'], 9
    if case == 'long-code':
        return (beginning + ['```python'] + ['- literal code'] * lines + ['```', '# end'],
                10 + lines // 2)
    if case == 'large-table':
        return beginning[:6] + ['| 中文 | `a|b` |'] * 398 + ['', '# end'], 2
    pattern = ['## 中文章节', '', '段落 **强调** [链接](https://example.com/a).',
               '- [ ] task', '> [!NOTE]', '> quote', '', '```python',
               'x = "中文"', '```', '', '| 名称 | value |',
               '| :--- | ---: |', '| 中文 | `a|b` |', '']
    if case == 'headings':
        pattern = ['## 中文章节', 'paragraph', '### detail', '']
    if case == 'tables':
        pattern = ['| 名称 | value |', '| :--- | ---: |', '| 中文 | `a|b` |', '']
    return beginning + (pattern * (lines // len(pattern) + 1))[:lines] + ['# end'], 2


def summarize(values):
    ordered = sorted(values)
    return {'n': len(values), 'first_ms': round(values[0], 3),
            'median_ms': round(statistics.median(values), 3),
            'p95_ms': round(ordered[math.ceil(len(ordered) * .95) - 1], 3),
            'max_ms': round(ordered[-1], 3)}


class Session:
    def __init__(self, work, source, other, enabled, config, profile=None):
        self.listener = socket.socket(socket.AF_UNIX)
        endpoint = str(work / 'probe.sock')
        self.listener.bind(endpoint)
        self.listener.listen(1)
        self.connection = None
        self.pending = b''
        self.state = {}
        self.sequence = 0
        self.cookie = 0
        self.screen = bytearray()
        self.samples = {}
        self.upstream_errors = set()
        script = work / 'probe.vim'
        script.write_text(r'''
set nomore
let g:md_probe_channel = ch_open(''' + quoted('unix:' + endpoint) + r''',
      \ {'mode': 'raw'})
let g:md_probe_previous = reltime()
let g:md_probe_gap = 0.0
let g:md_probe_last = ''
let g:md_probe_cookie = 0
function! MdProbe(timer) abort
  let elapsed = reltimefloat(reltime(g:md_probe_previous)) * 1000
  let g:md_probe_previous = reltime()
  if elapsed > g:md_probe_gap
    let g:md_probe_gap = elapsed
  endif
  let text = getline('.')
  let index = get(b:, 'vimrc_lite_md_index', {})
  let value = {'name': expand('%:t'), 'lnum': line('.'), 'col': col('.'),
        \ 'mode': mode(1), 'lines': line('$'), 'length': strlen(text),
        \ 'prefix': strpart(text, 0, 80), 'tail': strpart(text, max([0, strlen(text) - 80])),
        \ 'tick': b:changedtick, 'modified': &modified, 'filetype': &filetype,
        \ 'windows': winnr('$'), 'conceal': &l:conceallevel, 'menu': pumvisible(),
        \ 'ready': get(index, 'complete', 1), 'cookie': g:md_probe_cookie}
  let value.preview = exists('*VimMarkdownPreviewInfo') ? VimMarkdownPreviewInfo() : {}
  let value.error = v:errmsg
  let encoded = json_encode(value)
  if encoded !=# g:md_probe_last
    let g:md_probe_last = encoded
    let value.gap_ms = g:md_probe_gap
    let value.batch_ms = get(index, 'max_batch_ms', 0) / 1000.0
    let value.fallbacks = get(index, 'fallbacks', 0)
    let v:errmsg = ''
    redraw
    call ch_sendraw(g:md_probe_channel, json_encode(value) . "\n")
  endif
endfunction
call timer_start(2, function('MdProbe'), {'repeat': -1})
''')
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        command = [VIM, '-Nu', str(config), '-i', 'NONE', '-n',
                   '--cmd', 'let g:vimrc_lite_osc52 = 0',
                   '--cmd', 'let g:vimrc_lite_clipboard_yank = 0',
                   '--cmd', 'let g:vimrc_lite_lsp = 0',
                   '--cmd', 'let g:vimrc_lite_local_config = 0',
                   '--cmd', 'let g:vimrc_lite_markdown = ' + str(int(enabled)),
                   '--cmd', 'autocmd VimEnter * source ' + str(script), str(source), str(other)]
        if profile:
            command[1:1] = ['--cmd', 'profile start ' + str(profile),
                            '--cmd', 'profile func *', '--cmd', 'profile file *']
        self.started = time.perf_counter()
        self.process = subprocess.Popen(command, cwd=work, stdin=slave, stdout=slave, stderr=slave,
                                        env=dict(os.environ, TERM='xterm-256color',
                                                 XDG_STATE_HOME=str(work / 'state')))
        os.close(slave)

    def wait(self, check, after=-1, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.process.poll() is None:
            readable = select.select([self.master, self.connection or self.listener], [], [], .002)[0]
            if self.master in readable:
                try:
                    self.screen.extend(os.read(self.master, 65536))
                except OSError:
                    pass
            if self.connection is None and self.listener in readable:
                self.connection, _ = self.listener.accept()
            elif self.connection in readable:
                self.pending += self.connection.recv(65536)
                while b'\n' in self.pending:
                    record, self.pending = self.pending.split(b'\n', 1)
                    self.state = json.loads(record)
                    self.sequence += 1
                    error = self.state.get('error', '')
                    if error:
                        if self.state['filetype'] == 'netrw' and error.startswith(('E31:', 'E225:')):
                            self.upstream_errors.add(error)
                        else:
                            raise AssertionError(error)
            if self.sequence > after and check(self.state):
                # Probe calls :redraw before reporting; drain its terminal output as well.
                while select.select([self.master], [], [], 0)[0]:
                    self.screen.extend(os.read(self.master, 65536))
                return self.state
        raise AssertionError(f'timeout: {self.state!r}; screen={bytes(self.screen[-1500:])!r}')

    def action(self, name, keys, check):
        before = self.sequence
        started = time.perf_counter()
        os.write(self.master, keys)
        result = self.wait(check, before)
        if name:
            self.samples.setdefault(name, []).append((time.perf_counter() - started) * 1000)
        return result

    def command(self, command):
        self.cookie += 1
        cookie = self.cookie
        return self.action(None, (':' + command + '\r:let g:md_probe_cookie = ' + str(cookie)
                                 + '\r').encode(), lambda s: s.get('cookie') == cookie
                           and s.get('mode') == 'n')

    def close(self):
        try:
            if self.process.poll() is None:
                os.write(self.master, b'\x1b:qa!\r')
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()
            if self.connection:
                self.connection.close()
            self.listener.close()
            os.close(self.master)


def benchmark(case='mixed', lines=1200, rounds=10, enabled=True, config=ROOT / '.vimrc',
              profile=None, preview=False, key_delay_ms=0):
    with tempfile.TemporaryDirectory(prefix='vim-markdown-latency-') as temporary:
        work = Path(temporary)
        text, edit_line = document(case, lines)
        source = work / 'sample.md'
        source.write_text('\n'.join(text) + '\n')
        other = work / 'other.md'
        other.write_text('# Other\nplain\n')
        session = Session(work, source, other, enabled, config, profile)
        try:
            session.wait(lambda s: s.get('name') == source.name and s.get('mode') == 'n')
            startup_ms = (time.perf_counter() - session.started) * 1000
            session.wait(lambda s: s.get('ready'))
            ready_ms = (time.perf_counter() - session.started) * 1000
            if preview:
                session.command('VimMarkdownPreview!')
                session.wait(lambda s: s.get('preview', {}).get('url'))
            for round_number in range(rounds):
                session.command('call cursor(' + str(edit_line) + ', 1)')
                original_length = session.state['length']
                session.action('insert_enter', b'A', lambda s: s['mode'].startswith('i'))
                for number, char in enumerate('latency_test'):
                    expected = original_length + number + 1
                    session.action('insert_key', char.encode(),
                                   lambda s: s['mode'].startswith('i') and s['length'] == expected)
                    if key_delay_ms:
                        time.sleep(key_delay_ms / 1000)
                session.action('insert_escape', b'\x1b', lambda s: s['mode'] == 'n')
                if case == 'long-code':
                    location = session.state['lnum']
                    session.action('code_enter', b'A\r', lambda s: s['lnum'] == location + 1
                                   and s['mode'].startswith('i'))
                    if session.state['prefix']:
                        raise AssertionError('Markdown continuation entered a code block')
                    session.action(None, b'\x1b', lambda s: s['mode'] == 'n')
                    tick = session.state['tick']
                    session.action(None, b'u', lambda s: s['tick'] > tick)
                session.command('call cursor(2, 1)')
                session.action('list_enter', b'A\r', lambda s: s['mode'].startswith('i')
                               and s['lnum'] == 3)
                if enabled and not session.state['prefix'].startswith('- [ ] '):
                    raise AssertionError('list continuation lost: ' + repr(session.state))
                session.action(None, b'\x1b', lambda s: s['mode'] == 'n')
                tick = session.state['tick']
                session.action('undo', b'u', lambda s: s['tick'] > tick and s['mode'] == 'n')
                session.action('save', b'\x13', lambda s: not s['modified'])
                session.command('call cursor(2, 1)')
                original_lines = session.state['lines']
                session.action('bracketed_paste', b'A\x1b[200~paste\n- literal\x1b[201~',
                               lambda s: s['lines'] == original_lines + 1
                               and s['prefix'] == '- literal')
                session.action(None, b'\x1b', lambda s: s['mode'] == 'n')
                tick = session.state['tick']
                session.action(None, b'u', lambda s: s['tick'] > tick
                               and s['lines'] == original_lines)
                session.command('call cursor(2, 1)')
                position = (session.state['lnum'], session.state['col'])
                session.action('move_down', b'j', lambda s: (s['lnum'], s['col']) != position)
                session.action('move_up', b'k', lambda s: (s['lnum'], s['col']) == position)
                old_line = session.state['lnum']
                session.action('scroll_down', b'\x04', lambda s: s['lnum'] > old_line)
                old_line = session.state['lnum']
                session.action('scroll_up', b'\x15', lambda s: s['lnum'] < old_line)
                if enabled:
                    old_conceal = session.state['conceal']
                    session.action('render_toggle', b' mr', lambda s: s['conceal'] != old_conceal)
                session.action('split_open', b' v', lambda s: s['windows'] == 2)
                session.action('split_close', b':close\r', lambda s: s['windows'] == 1
                               and s['mode'] == 'n')
                session.action('buffer_next', b'L', lambda s: s['name'] == other.name)
                session.action('buffer_previous', b'H', lambda s: s['name'] == source.name)
                session.action('tree_open', b' e', lambda s: s['filetype'] == 'netrw')
                session.action('tree_close', b' e', lambda s: s['name'] == source.name
                               and s['windows'] == 1)
                if enabled:
                    session.wait(lambda s: s['ready'])
                    session.action('outline_open', b' mo',
                                   lambda s: s['filetype'] == 'vimmarkdownoutline')
                    session.action('outline_close', b'q', lambda s: s['name'] == source.name
                                   and s['windows'] == 1)
                    session.command('call cursor(6, 1)')
                    session.command("call setline(6, '| 中文" + str(round_number) + " | x |')")
                    tick = session.state['tick']
                    session.action('table_align', b' mt', lambda s: s['tick'] > tick)
                    session.command('call cursor(1, 1)')
                    session.action('heading_next', b']h', lambda s: s['lnum'] > 1)
                    session.action('heading_previous', b'[h', lambda s: s['lnum'] == 1)
            # Observe a final completed index and include all measured background gaps.
            session.wait(lambda s: s['ready'])
            if preview:
                session.wait(lambda s: s['preview'].get('tick') == s['tick']
                             and not s['preview'].get('inflight'))
                from urllib.request import urlopen
                with urlopen(session.state['preview']['url'] + 'state', timeout=3) as response:
                    snapshot = json.load(response)
                    if 'latency_test' not in snapshot['text']:
                        raise AssertionError('preview snapshot lost typed content')
            session.command('let g:md_probe_done = 1')
            return {'case': case, 'enabled': enabled, 'preview': preview, 'lines': len(text),
                    'key_delay_ms': key_delay_ms,
                    'bytes': source.stat().st_size, 'rounds': rounds,
                    'startup_ms': round(startup_ms, 3), 'index_ready_ms': round(ready_ms, 3),
                    'max_loop_gap_ms': round(session.state['gap_ms'], 3),
                    'max_index_batch_ms': round(session.state['batch_ms'], 3),
                    'context_fallbacks': session.state['fallbacks'],
                    'upstream_netrw_errors': sorted(session.upstream_errors),
                    'operations': {name: summarize(values)
                                   for name, values in session.samples.items()}}
        finally:
            session.close()


def violations(result):
    failures = []
    for name, value in result['operations'].items():
        p95, maximum = (20, 50)
        if name == 'insert_escape':
            # Raw ESC inherits the configuration's terminal-sequence timeout twice.
            # Keep the absolute limit explicit; compare this sample with --disabled.
            p95, maximum = (90, 110)
        elif name == 'save':
            p95, maximum = (50, 100)
        elif name.startswith(('split_', 'buffer_', 'render_')):
            p95, maximum = (30, 80)
        elif name.startswith(('tree_', 'outline_', 'table_')):
            p95, maximum = (100, 150)
        if value['p95_ms'] > p95 or value['max_ms'] > maximum:
            failures.append(f'{name}: P95={value["p95_ms"]}, max={value["max_ms"]}')
    if result['max_index_batch_ms'] > 8:
        failures.append('index batch exceeds 8 ms scheduling tolerance')
    if result['context_fallbacks']:
        failures.append('context unavailable during ordinary editing')
    return failures


def matrix(config, rounds, output):
    """Run serially, retaining failures and the exact configuration fingerprints."""
    sources = [ROOT / '.vimrc', ROOT / 'vim-install.sh', ROOT / 'tests/markdown_latency.py',
               ROOT / 'tests/test_vim.py']
    sources += [ROOT / 'netrw-tools/autoload/netrw.vim']
    sources += sorted(ROOT.glob('*.vim'))
    sources += [ROOT / 'markdown' / name for name in
                ['preview.py', 'preview.js', 'preview.css', 'index.html', 'vendor/manifest.json']]
    report = {'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'platform': platform.platform(),
              'vim': subprocess.check_output([VIM, '--version'], text=True).splitlines()[0],
              'measurement': 'real PTY; redraw then Unix socket observation; 100x30; '
                             'LSP/clipboard/personal hooks disabled; no SSH or physical display',
              'source_sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in sources}, 'runs': []}
    cases = [('mixed', 1200, True, False, 0), ('mixed', 10000, True, False, 0),
             ('headings', 10000, True, False, 0), ('tables', 10000, True, False, 0),
             ('long-code', 10000, True, False, 0), ('long-line', 1200, True, False, 0),
             ('syntax-stress', 1200, True, False, 0), ('large-table', 400, True, False, 0),
             ('mixed', 10000, True, True, 0),
             ('mixed', 60000, True, True, 0),
             ('mixed', 1200, False, False, 0), ('mixed', 10000, False, False, 0),
             ('headings', 10000, False, False, 0), ('long-code', 10000, False, False, 0),
             ('mixed', 10000, True, False, 20), ('long-code', 10000, True, False, 80)]
    for case, lines, enabled, preview, delay in cases:
        try:
            result = benchmark(case, lines, rounds, enabled, config, preview=preview,
                               key_delay_ms=delay)
            result['violations'] = violations(result)
            print(json.dumps({'case': case, 'lines': lines, 'enabled': enabled,
                              'preview': preview, 'key_delay_ms': delay,
                              'typing_p95': result['operations']['insert_key']['p95_ms'],
                              'escape_p95': result['operations']['insert_escape']['p95_ms'],
                              'batch_max': result['max_index_batch_ms'],
                              'violations': result['violations']}, ensure_ascii=False), flush=True)
        except Exception as error:
            result = {'case': case, 'lines': lines, 'enabled': enabled, 'preview': preview,
                      'key_delay_ms': delay, 'error': str(error)}
            print(json.dumps({'case': case, 'error': str(error)[:500]}, ensure_ascii=False), flush=True)
        report['runs'].append(result)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    report['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report['passed'] = not any(run.get('error') or run.get('violations') for run in report['runs'])
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['mixed', 'headings', 'tables', 'long-code', 'long-line',
                                         'large-table', 'syntax-stress'],
                        default='mixed')
    parser.add_argument('--lines', type=int, default=1200)
    parser.add_argument('--rounds', type=int, default=10)
    parser.add_argument('--disabled', action='store_true')
    parser.add_argument('--strict', action='store_true')
    parser.add_argument('--preview', action='store_true')
    parser.add_argument('--key-delay-ms', type=int, default=0)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--matrix', action='store_true', help='serial stress and baseline matrix')
    args = parser.parse_args()
    if args.lines < 50 or args.rounds < 1 or not 0 <= args.key_delay_ms <= 1000:
        parser.error('lines must be >= 50; rounds positive; key delay 0..1000 ms')
    if args.matrix:
        if not args.output:
            parser.error('--matrix requires --output')
        report = matrix(args.config.resolve(), args.rounds, args.output)
        print('PASS' if report['passed'] else 'FAIL', args.output)
        raise SystemExit(1 if args.strict and not report['passed'] else 0)
    result = benchmark(args.case, args.lines, args.rounds, not args.disabled,
                       args.config.resolve(), args.profile, args.preview, args.key_delay_ms)
    result['violations'] = violations(result)
    output = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(output + '\n')
    print(output)
    raise SystemExit(1 if args.strict and result['violations'] else 0)
