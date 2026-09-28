#!/usr/bin/env python3
"""Measure the configured Vim client against locally installed clangd/Pyright."""

import argparse
import json
from pathlib import Path
import shutil
import statistics

from test_vim import ROOT, VimSession, quoted


def benchmark(language, config, rounds, unicode_prefix=False):
    session = VimSession()
    session.setUp()
    try:
        work = session.work
        session.env['HOME'] = str(work)
        cpp = language == 'cpp'
        call_prefix = ('    /* 🙂𝄞é */ return ' if cpp else '    note = "🙂𝄞é"; return ') if unicode_prefix else '    return '
        source = work / ('main.cpp' if cpp else 'main.py')
        source.write_text('int target() {\n    return 42;\n}\nint main() {\n' + call_prefix + 'target();\n}\n'
                          if cpp else 'def target():\n    return 42\n\ndef caller():\n' + call_prefix + 'target()\n')
        if cpp:
            (work / 'compile_commands.json').write_text(json.dumps([
                {'directory': str(work), 'file': str(source),
                 'arguments': ['clang++', '-std=c++17', '-c', str(source)]}]))
        else:
            (work / 'pyrightconfig.json').write_text('{"include":["main.py"],"typeCheckingMode":"off"}')
        report = work / 'latency.json'
        settings = ['let g:lsp_probe_start = reltime()',
                    'autocmd User lsp_buffer_enabled let g:lsp_probe_ready = '
                    'reltimefloat(reltime(g:lsp_probe_start)) * 1000']
        if cpp:
            settings += ['let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps([shutil.which('clangd'), '--background-index'])]
        else:
            settings += ['let g:vimrc_lite_lsp_pyright_cmd = ' + json.dumps([shutil.which('pyright-langserver'), '--stdio'])]
        body = r'''
function! Wait(Check) abort
  let started = reltime()
  while !a:Check()
    if reltimefloat(reltime(started)) > 5
      throw 'language server operation timed out'
    endif
    sleep 1m
  endwhile
endfunction
call Wait({-> &omnifunc ==# 'lsp#complete'})
let metrics = {'startup_to_ready': [g:lsp_probe_ready],
      \ 'definition_after_edit': [], 'hover': [], 'references': [], 'completion': []}
" 隔离手动语义补全的响应，避免自动单词菜单被误算作服务器结果。
augroup vimrc_lite_completion
  autocmd!
augroup END
function! CompletionReady(timer) abort
  if pumvisible()
    let words = map(complete_info(['items']).items, 'v:val.word')
    call assert_false(empty(filter(words, 'stridx(v:val, g:completion_name) == 0')), string(words))
    call add(g:metrics.completion, reltimefloat(reltime(g:completion_started)) * 1000)
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif reltimefloat(reltime(g:completion_started)) > 5
    call assert_report('manual completion timed out')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
''' + f'for round in range({rounds})\n' + r'''
  let name = 'target_round' . round
  " 每轮整体下移，旧服务器快照会跳到错误行，不能误算成成功同步。
  call append(0, '')
  let definition_line = round + 2
  let use_line = definition_line + 4
''' + ('  call setline(definition_line, "int " . name . "() {")\n' if cpp else
       '  call setline(definition_line, "def " . name . "():")\n') + (
       f'  let prefix = {quoted(call_prefix)}\n'
       f'  let use = prefix . name . {quoted("();" if cpp else "()")}\n') + r'''
  call setline(use_line, use)
  call cursor(use_line, strlen(prefix) + 1)
  let started = reltime()
  call feedkeys('gd', 'xt')
  call Wait({-> line('.') == g:definition_line})
  call add(metrics.definition_after_edit, reltimefloat(reltime(started)) * 1000)
  call assert_match(name, getline('.'))
  call cursor(use_line, strlen(prefix) + 1)
  let started = reltime()
  call feedkeys('K', 'xt')
  call Wait({-> lsp#document_hover_preview_winid() > 0})
  call add(metrics.hover, reltimefloat(reltime(started)) * 1000)
  call popup_clear()
  call setqflist([], 'r')
  let started = reltime()
  call feedkeys('gr', 'xt')
  call Wait({-> len(getqflist()) >= 2})
  call add(metrics.references, reltimefloat(reltime(started)) * 1000)
  cclose
  call setline(use_line, prefix . 'tar')
  call cursor(use_line, strlen(prefix) + 3)
  let g:completion_name = name
  let g:completion_started = reltime()
  call timer_start(1, function('CompletionReady'), {'repeat': -1})
  call feedkeys("A\<C-x>\<C-o>", 'xt!')
  call setline(use_line, use)
endfor
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n'
        session.terminal_vim(body, args=[str(source)], before=settings, config=config)
        values = json.loads(report.read_text())
        return {name: {'first_ms': round(samples[0], 2),
                       'median_ms': round(statistics.median(samples), 2),
                       'max_ms': round(max(samples), 2)} for name, samples in values.items()}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--language', choices=['cpp', 'python'], action='append')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--unicode', action='store_true', help='put non-BMP and combining characters before requests')
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('rounds must be positive')
    for language in args.language or ['cpp', 'python']:
        binary = 'clangd' if language == 'cpp' else 'pyright-langserver'
        if not shutil.which(binary):
            parser.error('missing executable: ' + binary)
        print(language, json.dumps(benchmark(language, args.config.resolve(), args.rounds, args.unicode)), flush=True)
