#!/usr/bin/env python3
"""Measure reference-list readiness through an offline LSP peer."""

import argparse
import json
from pathlib import Path
import statistics

from test_lsp import LspFixture, WAIT
from test_vim import ROOT, quoted


def benchmark(config, references=1000, rounds=3, loaded=False):
    session = LspFixture()
    session.setUp()
    try:
        target = session.source if loaded else session.target
        prefix = '说明 = "中文🙂𝄞é"; '
        target.write_text((prefix + 'target\n') * references)
        character = len(prefix.encode('utf-16-le')) // 2
        locations = [{'uri': target.as_uri(), 'range': {
            'start': {'line': row, 'character': character},
            'end': {'line': row, 'character': character + 6}}}
            for row in reversed(range(references))]
        responses = session.work / 'responses.json'
        responses.write_text(json.dumps({'results': {
            'textDocument/references': locations + locations[:5]}}))
        command = session.command + ['--response-config', str(responses)]
        report = session.work / 'times.json'
        session.vim(WAIT + r'''
call lsp#enable()
execute 'edit ' . fnameescape(''' + quoted(session.source) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let samples = []
for round in range(''' + str(rounds) + r''')
  call setqflist([], 'r')
  let started = reltime()
  VimLspReferences
  call WaitFor({-> &buftype ==# 'quickfix'})
  call add(samples, reltimefloat(reltime(started)) * 1000)
  let items = getqflist()
  call assert_equal(''' + str(references) + r''', len(items))
  call assert_equal(range(1, ''' + str(references) + r'''), map(copy(items), 'v:val.lnum'))
  call assert_equal(''' + str(len(prefix.encode()) + 1) + r''', items[0].col)
  call assert_equal(''' + str(len(prefix.encode()) + 7) + r''', items[-1].end_col)
  call feedkeys('q', 'xt')
endfor
call writefile([json_encode(samples)], ''' + quoted(report) + r''')
''', config=config, before=[
            'let g:vimrc_lite_context = 0',
            'let g:vimrc_lite_lsp_pyright_cmd = ' + json.dumps(command)], timeout=120)
        samples = json.loads(report.read_text())
        return {'first_ms': round(samples[0], 3),
                'median_ms': round(statistics.median(samples), 3),
                'max_ms': round(max(samples), 3)}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--references', type=int, default=1000)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--loaded', action='store_true')
    args = parser.parse_args()
    if args.references < 1 or args.rounds < 1:
        parser.error('references and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.references,
                               args.rounds, args.loaded), indent=2))
