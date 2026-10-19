#!/usr/bin/env python3
"""Time opening a file with saved pins, including exact and relocated anchors."""

import argparse
import hashlib
import json
from pathlib import Path
import statistics

from test_vim import ROOT, VimSession, quoted


def benchmark(config, lines=100000, pins=1, rounds=5, changed=False):
    session = VimSession()
    session.setUp()
    try:
        (session.work / '.git').mkdir()
        source = session.work / 'pinned.txt'
        content = [f'line {index}' for index in range(lines)]
        digest = hashlib.sha256('\n'.join(content).encode()).hexdigest()
        records = []
        expected = []
        for index in range(pins):
            row = (index + 1) * lines // (pins + 1)
            records.append({'line': row + 1, 'text': content[row], 'hash': digest,
                            'before': content[max([0, row - 2]):row],
                            'after': content[row + 1:row + 3]})
            expected.append(row + 1 + int(changed))
        source.write_text(('external change\n' if changed else '')
                          + '\n'.join(content) + '\n')
        state = session.work / 'state/vim-lite/pins'
        state.mkdir(parents=True)
        key = hashlib.sha256(str(session.work).encode()).hexdigest()
        (state / (key + '.json')).write_text(json.dumps({
            'version': 1, 'root': str(session.work), 'files': {str(source): records}}))
        report = session.work / 'times.json'
        session.vim(r'''
let samples = []
for round in range(''' + str(rounds) + r''')
  let started = reltime()
  edit pinned.txt
  call add(samples, reltimefloat(reltime(started)) * 1000)
  let properties = prop_list(1, {'types': ['VimrcLitePinAnchor'], 'end_lnum': -1})
  call assert_equal(''' + str(expected) + r''', sort(map(properties, 'v:val.lnum'), 'n'))
  call assert_false(&modified)
  bwipeout
endfor
call writefile([json_encode(samples)], ''' + quoted(report) + r''')
''', config=config, before=['let g:vimrc_lite_lsp = 0'], timeout=120)
        samples = json.loads(report.read_text())
        return {'first_ms': round(samples[0], 3),
                'median_ms': round(statistics.median(samples), 3),
                'max_ms': round(max(samples), 3)}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--lines', type=int, default=100000)
    parser.add_argument('--pins', type=int, default=1)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--changed', action='store_true')
    args = parser.parse_args()
    if args.lines < 1 or not 1 <= args.pins <= args.lines or args.rounds < 1:
        parser.error('lines and rounds must be positive; pins must be between 1 and lines')
    print(json.dumps(benchmark(args.config.resolve(), args.lines, args.pins,
                               args.rounds, args.changed), indent=2))
