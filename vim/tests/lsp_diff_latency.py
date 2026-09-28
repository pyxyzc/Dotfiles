#!/usr/bin/env python3
"""Measure fallback LSP diff cost and verify each change reconstructs the document."""

import argparse
import json
from pathlib import Path
import statistics

from mock_lsp import offset
from test_vim import ROOT, VimSession, quoted


def benchmark(config, characters, lines, rounds):
    session = VimSession()
    session.setUp()
    try:
        long = '中🙂é' * characters
        old = ['unchanged'] * lines + [long]
        cases = {
            'long_line_tail': (old, old[:-1] + [long + 'X']),
            'long_line_head': (old, old[:-1] + ['X' + long]),
            'identical': (old, old),
        }
        metrics = {}
        for name, (before, after) in cases.items():
            source = session.work / 'case.json'
            source.write_text(json.dumps([before, after], ensure_ascii=False))
            report = session.work / 'diff.json'
            session.vim('let documents = json_decode(join(readfile(' + quoted(source) + '), "\\n"))\n'
                        'let times = []\n' + f'for round in range({rounds})\n' + r'''
  let started = reltime()
  let change = lsp#utils#diff#compute(documents[0], documents[1])
  call add(times, reltimefloat(reltime(started)) * 1000)
endfor
''' + f'call writefile([json_encode([times, change])], {quoted(report)}, "S")\n', config=config)
            times, change = json.loads(report.read_text())
            text = '\n'.join(before) + '\n'
            start = offset(text, change['range']['start'])
            end = offset(text, change['range']['end'])
            assert text[:start] + change['text'] + text[end:] == '\n'.join(after) + '\n', name
            assert len(text[start:end].encode('utf-16-le')) // 2 == change['rangeLength'], name
            metrics[name] = {'median_ms': round(statistics.median(times), 3),
                             'max_ms': round(max(times), 3),
                             'replacement_bytes': len(change['text'].encode())}
        return metrics
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--characters', type=int, default=5000,
                        help='number of four-codepoint Unicode groups on the long line')
    parser.add_argument('--lines', type=int, default=10000)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if min(args.characters, args.rounds) < 1 or args.lines < 0:
        parser.error('characters and rounds must be positive; lines must be nonnegative')
    print(json.dumps(benchmark(args.config.resolve(), args.characters, args.lines, args.rounds), indent=2))
