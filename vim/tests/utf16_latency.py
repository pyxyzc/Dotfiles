#!/usr/bin/env python3
"""Measure UTF-16 fallback conversions on long Unicode lines."""

import argparse
import json
import statistics

from test_vim import VimSession, quoted


def benchmark(size, rounds, reference=False):
    session = VimSession()
    session.setUp()
    try:
        report = session.work / 'utf16.json'
        session.vim(f'let size = {size}\nlet rounds = {rounds}\nlet reference = {int(reference)}\n' + r'''
" Prior full-list scan, with the same legacy decoder, for reproducible comparison.
function! Reference(text, target) abort
  let characters = exists('*str2list') ? str2list(a:text, 1)
        \ : lsp#utils#utf16#_codepoints_legacy(a:text)
  let units = 0
  let bytes = 0
  for codepoint in characters
    let width = codepoint > 0xffff ? 2 : 1
    if units + width > a:target | break | endif
    let units += width
    let bytes += codepoint < 0x80 ? 1 : codepoint < 0x800 ? 2 : codepoint < 0x10000 ? 3 : 4
  endfor
  return bytes
endfunction
let text = repeat('中🙂é', size)
let metrics = {}
for [name, units, expected] in [['start', 0, 0], ['near_start', 3, 7],
      \ ['end', size * 5, strlen(text)]]
  let times = []
  for iteration in range(rounds)
    let started = reltime()
    let result = reference ? Reference(text, units) : lsp#utils#utf16#_byteidx_fallback(text, units)
    call add(times, reltimefloat(reltime(started)) * 1000)
    call assert_equal(expected, result)
  endfor
  let metrics[name] = times
endfor
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n')
        return {name: {'median_ms': round(statistics.median(times), 3),
                       'max_ms': round(max(times), 3)}
                for name, times in json.loads(report.read_text()).items()}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', type=int, default=5000)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--reference', action='store_true', help='measure the prior full-list scan')
    args = parser.parse_args()
    if min(args.size, args.rounds) < 1:
        parser.error('size and rounds must be positive')
    print(json.dumps(benchmark(args.size, args.rounds, args.reference), indent=2))
