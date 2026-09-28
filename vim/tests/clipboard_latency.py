#!/usr/bin/env python3
"""Time OSC 52 encoding and copying into an isolated, continuously drained PTY."""

import argparse
import base64
import json
from pathlib import Path
import re
import statistics

from test_vim import ROOT, VimSession, quoted


def benchmark(config, lines, rounds):
    session = VimSession()
    session.setUp()
    try:
        source = session.work / 'copy.txt'
        contents = '中文 copy 0123456789\n' * lines
        source.write_text(contents)
        report = session.work / 'metrics.json'
        body = r'''
let clipboard = matchstr(execute('command VimCopyContent'), '<SNR>\d\+_')
let text = join(getline(1, '$'), "\n") . "\n"
let encoded = system('base64', text)
call assert_equal(0, v:shell_error)
let metrics = {'base64_ms': [], 'strip_regex_ms': [], 'strip_split_ms': [],
      \ 'systemlist_ms': [], 'encode_ms': [], 'copy_to_pty_ms': []}
''' + f'for round in range({rounds})\n' + r'''
  let started = reltime()
  call system('base64', text)
  call add(metrics.base64_ms, reltimefloat(reltime(started)) * 1000)
  let started = reltime()
  let stripped = substitute(encoded, '[\r\n]', '', 'g')
  call add(metrics.strip_regex_ms, reltimefloat(reltime(started)) * 1000)
  let started = reltime()
  let joined = join(split(encoded, '[\r\n]'), '')
  call add(metrics.strip_split_ms, reltimefloat(reltime(started)) * 1000)
  call assert_equal(sha256(stripped), sha256(joined))
  let started = reltime()
  let native_joined = join(systemlist('base64', text), '')
  call add(metrics.systemlist_ms, reltimefloat(reltime(started)) * 1000)
  call assert_equal(sha256(stripped), sha256(native_joined))
  let started = reltime()
  call call(function(clipboard . 'Osc52'), [text])
  call add(metrics.encode_ms, reltimefloat(reltime(started)) * 1000)
  let g:vimrc_lite_osc52 = 1
  let started = reltime()
  VimCopyContent
  call add(metrics.copy_to_pty_ms, reltimefloat(reltime(started)) * 1000)
  call assert_equal(sha256(text), sha256(getreg('"')))
endfor
''' + f'call writefile([json_encode(metrics)], {quoted(report)}, "S")\n'
        output = session.terminal_vim(body, config=config, args=[str(source)], controlling_tty=True)
        payloads = re.findall(rb'\x1b]52;c;([A-Za-z0-9+/=]*)\x07', output)
        assert len(payloads) == rounds, f'expected {rounds} complete OSC frames, got {len(payloads)}'
        for payload in payloads:
            assert base64.b64decode(payload, validate=True) == contents.encode(), 'OSC payload differs from source'
        metrics = json.loads(report.read_text())
        return {'payload_bytes': len(contents.encode()), 'validated_frames': len(payloads),
                'timings': {name: {'median_ms': round(statistics.median(samples), 3),
                                   'max_ms': round(max(samples), 3)} for name, samples in metrics.items()}}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--lines', type=int, default=100000)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if min(args.lines, args.rounds) < 1:
        parser.error('lines and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.lines, args.rounds), indent=2))
