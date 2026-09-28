#!/usr/bin/env python3
"""Stress automatic completion, measuring menu latency and main-loop timer gaps."""

import argparse
import json
from pathlib import Path

from test_vim import ROOT, VimSession, quoted


def benchmark(config, case, size, profile=None):
    session = VimSession()
    session.setUp()
    try:
        source = session.work / 'words.txt'
        if case == 'long-line':
            source.write_text('unmatched ' * size + 'alpha_tail\n')
        elif case == 'long-word':
            source.write_text('alpha_' + 'x' * size + '\nalpha_tail\n')
        elif case == 'sparse':
            source.write_text('unmatched word\n' * size + 'alpha_tail\n')
        elif case == 'current-line':
            source.write_text('alpha_tail\n')
        else:
            for index in range(size):
                (session.work / f'buffer_{index}.txt').write_text('unmatched word\n')
            source.write_text('alpha_tail\n')
        report = session.work / 'latency.json'
        body = ''
        if case == 'buffers':
            body += f'for index in range({size})\n' + r'''
  let buffer = bufadd('buffer_' . index . '.txt')
  call bufload(buffer)
  call setbufvar(buffer, '&buflisted', 1)
endfor
'''
        body += 'execute "edit " . fnameescape(' + quoted(source) + ')\nenew\n'
        if case == 'current-line':
            body += f"call setline(1, repeat('unmatched ', {size}))\n"
            body += "call assert_false(get(b:, 'vimrc_lite_large_file', 0))\n"
        body += r'''
let g:started = reltime()
let g:previous = g:started
let g:gaps = []
let g:found = 0
function! Observe(timer) abort
  call add(g:gaps, reltimefloat(reltime(g:previous)) * 1000)
  let g:previous = reltime()
  let elapsed = reltimefloat(reltime(g:started)) * 1000
  if pumvisible() && index(map(complete_info(['items']).items, 'v:val.word'), 'alpha_tail') >= 0
    let g:found = elapsed
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif elapsed > 6000
    call assert_report('tail candidate not found within 6 seconds; messages: ' . execute('messages'))
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(1, function('Observe'), {'repeat': -1})
''' + ("call feedkeys('Aal', 'xt!')\n" if case == 'current-line' else "call feedkeys('ial', 'xt!')\n") + r'''
let metrics = {'menu_ms': g:found, 'max_loop_gap_ms': sort(g:gaps, 'f')[-1],
      \ 'timer_ticks': len(g:gaps)}
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n'
        before = [] if profile is None else ['profile start ' + str(profile),
                                             'profile func *', 'profile file *']
        session.terminal_vim(body, config=config, before=before)
        return json.loads(report.read_text())
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--case', choices=['long-line', 'long-word', 'sparse', 'buffers', 'current-line'], required=True)
    parser.add_argument('--size', type=int, required=True,
                        help='number of repeated words, word bytes, lines, or buffers')
    parser.add_argument('--profile', type=Path)
    args = parser.parse_args()
    if args.size < 1:
        parser.error('size must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.case, args.size, args.profile), indent=2))
