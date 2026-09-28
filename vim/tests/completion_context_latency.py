#!/usr/bin/env python3
"""Measure prefix extraction and repeated context checks on unsaved long lines."""

import argparse
import json
from pathlib import Path
import statistics

from test_vim import ROOT, VimSession, quoted


def benchmark(config, size, rounds):
    session = VimSession()
    session.setUp()
    try:
        report = session.work / 'context.json'
        session.vim(r'''
let completion = ScriptPrefix('/completion.vim$')
enew
''' + f'let size = {size}\nlet rounds = {rounds}\n' + r'''
let metrics = {}
for [name, text, prefix] in [['short_prefix', repeat('unmatched ', size) . 'alX', 'al'],
      \ ['long_prefix', ' ' . repeat('中', size) . 'X', repeat('中', size)]]
  let cold = []
  let warm = []
  for iteration in range(rounds)
    call setline(1, text)
    call cursor(1, strlen(text))
    let started = reltime()
    let context = call(function(completion . 'Context'), [])
    call add(cold, reltimefloat(reltime(started)) * 1000)
    call assert_equal(sha256(prefix), sha256(context[3]), name)
    let started = reltime()
    let repeated = call(function(completion . 'Context'), [])
    call add(warm, reltimefloat(reltime(started)) * 1000)
    call assert_equal(context, repeated)
  endfor
  let metrics[name . '_cold'] = cold
  let metrics[name . '_warm'] = warm
endfor
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n', config=config)
        metrics = json.loads(report.read_text())
        return {name: {'median_ms': round(statistics.median(samples), 3),
                       'max_ms': round(max(samples), 3)} for name, samples in metrics.items()}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--size', type=int, default=100000)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if min(args.size, args.rounds) < 1:
        parser.error('size and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.size, args.rounds), indent=2))
