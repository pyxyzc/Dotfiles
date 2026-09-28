#!/usr/bin/env python3
"""Measure whitespace trimming, including clean buffers and giant UTF-8 lines."""

import argparse
import json
from pathlib import Path
import statistics
import subprocess

from test_vim import ROOT, VimSession, quoted


def benchmark(config, lines, characters, rounds, legacy=False):
    session = VimSession()
    session.setUp()
    try:
        report = session.work / 'trim-metrics.json'
        progress = session.work / 'progress'
        body = r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
" 修改前的原生实现，仅用于独立基线对照，不更改工作树配置。
function! LegacyTrim() abort
  let view = winsaveview()
  let search = @/
  try
    keeppatterns %s/\s\+$//e
  finally
    let @/ = search
    call winrestview(view)
  endtry
endfunction
edit trim.txt
''' + f'let entry_count = {lines}\nlet characters = {characters}\n' \
            + f'let legacy = {int(legacy)}\nlet progress = {quoted(progress)}\n' + r'''
let cases = {'dense': repeat(['    example content  ' . "\t"], entry_count),
      \ 'clean': repeat(['    example content'], entry_count),
      \ 'long_clean': ['中文' . repeat(' ', characters) . '🙂'],
      \ 'long_dirty': ['中文' . repeat(' ', characters) . '🙂' . " \t"]}
let sparse = copy(cases.clean)
let sparse[entry_count / 2] .= '  '
let cases.sparse = sparse
let mixed = copy(cases.dense)
let mixed[entry_count / 2] = cases.long_dirty[0]
let cases.mixed = mixed
let expected_cases = {'dense': copy(cases.clean), 'clean': copy(cases.clean),
      \ 'sparse': copy(cases.clean), 'long_clean': copy(cases.long_clean),
      \ 'long_dirty': copy(cases.long_clean)}
let expected_cases.mixed = copy(cases.clean)
let expected_cases.mixed[entry_count / 2] = cases.long_clean[0]
let metrics = {}
for [name, original] in items(cases)
  let expected = expected_cases[name]
  let samples = []
''' + f'  for round in range({rounds})\n' + r'''
    %delete _
    call setline(1, original)
    let &undolevels = &undolevels
    setlocal nomodified
    let tick = b:changedtick
    call writefile(['trimming: ' . name], progress, 'S')
    let started = reltime()
    if legacy
      call LegacyTrim()
    else
      call call(function(editor . 'TrimWhitespace'), [])
    endif
    call add(samples, reltimefloat(reltime(started)) * 1000)
    call writefile(['validating: ' . name], progress, 'S')
    call assert_equal(expected, getline(1, '$'), name)
    if expected ==# original
      call assert_equal(tick, b:changedtick, name . ': no-op changed text')
      call assert_false(&modified, name . ': no-op set modified')
    else
      undo
      call assert_equal(original, getline(1, '$'), name . ': undo')
    endif
  endfor
  let metrics[name] = samples
endfor
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n'
        try:
            session.vim(body, config=config)
        except subprocess.TimeoutExpired as error:
            stage = progress.read_text().strip() if progress.exists() else 'preparation'
            raise RuntimeError(f'20-second benchmark deadline exceeded during {stage}') from error
        metrics = json.loads(report.read_text())
        return {'lines': lines, 'characters': characters, 'rounds': rounds, 'legacy': legacy,
                'timings': {name: {'median_ms': round(statistics.median(samples), 3),
                                   'max_ms': round(max(samples), 3)}
                            for name, samples in metrics.items()}}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--lines', type=int, default=100000)
    parser.add_argument('--characters', type=int, default=1000000)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--legacy', action='store_true', help='compare the previous native substitute implementation')
    args = parser.parse_args()
    if min(args.lines, args.characters, args.rounds) < 1:
        parser.error('lines, characters and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.lines, args.characters, args.rounds, args.legacy), indent=2))
