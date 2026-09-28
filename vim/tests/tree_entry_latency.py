#!/usr/bin/env python3
"""Measure entry resolution in a large expanded tree, excluding netrw listing."""

import argparse
import json
from pathlib import Path
import statistics

from test_vim import ROOT, VimSession, quoted


def benchmark(config, entries, rounds):
    session = VimSession()
    session.setUp()
    try:
        report = session.work / 'entry-metrics.json'
        session.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
enew
let b:netrw_curdir = '/tree/nested'
let w:netrw_treetop = '/tree'
let w:netrw_liststyle = 3
call setline(1, ['tree/', '| nested/', '| | sibling/'])
''' + f"call append('$', repeat(['| | | unrelated.txt'], {entries}))\n" + r'''
call append('$', '| | target 中文.txt')
call cursor(line('$'), 5)
normal! zz
let view = winsaveview()
let @/ = 'saved search'
let expected = {'name': 'target 中文.txt', 'path': '/tree/nested/target 中文.txt', 'dir': 0}
let samples = []
''' + f'for round in range({rounds})\n' + r'''
  let started = reltime()
  let entry = call(function(tree . 'Entry'), [])
  call add(samples, reltimefloat(reltime(started)) * 1000)
  call assert_equal(expected, entry)
  call assert_equal(view, winsaveview())
  call assert_equal('saved search', @/)
endfor
''' + f'call writefile([json_encode(samples)], {quoted(report)}, "S")\n', config=config)
        samples = json.loads(report.read_text())
        return {'entries': entries, 'rounds': rounds,
                'entry_median_ms': round(statistics.median(samples), 3),
                'entry_max_ms': round(max(samples), 3)}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--entries', type=int, default=100000)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if min(args.entries, args.rounds) < 1:
        parser.error('entries and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.entries, args.rounds), indent=2))
