#!/usr/bin/env python3
"""Measure real netrw directory listing, reopening, refresh and direct startup."""

import argparse
import json
from pathlib import Path

from test_vim import ROOT, VimSession, quoted


def benchmark(config, files, direct=False, profile=None, child_files=1, native_listing=False,
              native_tree=False):
    session = VimSession()
    session.setUp()
    try:
        directory = session.work / 'listing'
        directory.mkdir()
        for index in range(files):
            (directory / f'file_{index:06d}.txt').touch()
        (directory / 'nested').mkdir()
        (directory / 'nested' / 'child.txt').touch()
        for index in range(1, child_files):
            (directory / 'nested' / f'child_{index:06d}.txt').touch()
        (directory / '.hidden').touch()
        report = session.work / 'metrics.json'
        before = ['let g:tree_started = reltime()']
        if native_listing:
            before += ['let g:vimrc_lite_netrw_fast_listing = 0']
        if native_tree:
            before += ['let g:vimrc_lite_netrw_fast_tree = 0']
        if profile:
            before += ['profile start ' + str(profile), 'profile func *', 'profile file *']
        body = r'''
" 此时所有 VimEnter 处理已经结束，包含 PTY 发送探针脚本的交接开销。
let metrics = {'startup_ready_ms': reltimefloat(reltime(g:tree_started)) * 1000}
function! Measure(name, keys) abort
  let started = reltime()
  call feedkeys(a:keys, 'xt')
  redraw
  let g:metrics[a:name] = reltimefloat(reltime(started)) * 1000
endfunction
'''
        if not direct:
            body += 'execute "cd " . fnameescape(' + quoted(directory) + ')\n'
            body += "call Measure('first_open_ms', ' e')\n"
        body += r'''
call assert_equal('netrw', &filetype)
''' + f"call assert_true(search('file_{files - 1:06d}.txt', 'w') > 0)\n" + r'''
call Measure('refresh_ms', 'R')
call assert_true(search('nested/', 'w') > 0)
call Measure('expand_ms', "\<CR>")
call assert_true(search('child.txt', 'w') > 0)
call Measure('expanded_refresh_ms', 'R')
call assert_true(search('child.txt', 'nw') > 0)
let hidden_before = search('\.hidden', 'nw') > 0
call Measure('hidden_ms', 'H')
call assert_notequal(hidden_before, search('\.hidden', 'nw') > 0)
'''
        if not direct:
            body += "call Measure('close_ms', ' e')\ncall Measure('reopen_ms', ' e')\n"
        else:
            body += r'''
call Measure('direct_close_ms', ' e')
call assert_equal(1, winnr('$'))
call assert_notequal('netrw', &filetype)
'''
        body += f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n'
        session.terminal_vim(body, config=config, before=before,
                             args=[str(directory)] if direct else [])
        return json.loads(report.read_text())
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--files', type=int, default=10000)
    parser.add_argument('--child-files', type=int, default=1)
    parser.add_argument('--native-listing', action='store_true')
    parser.add_argument('--native-tree', action='store_true')
    parser.add_argument('--direct', action='store_true')
    parser.add_argument('--profile', type=Path)
    args = parser.parse_args()
    if args.files < 1 or args.child_files < 1:
        parser.error('files and child-files must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.files, args.direct, args.profile,
                               args.child_files, args.native_listing, args.native_tree), indent=2))
