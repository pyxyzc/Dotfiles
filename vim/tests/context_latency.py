#!/usr/bin/env python3
"""Measure cached statusline lookups with an offline LSP peer, in milliseconds.

The fixture exercises many sibling functions, repeated positions, scope changes
and long Unicode lines. Measurements exclude terminal and network transport.
"""

import argparse
import json
from pathlib import Path
import statistics

from test_lsp import LspFixture, WAIT
from test_vim import ROOT, quoted


def node(name, kind, start, end, children=()):
    return {'name': name, 'kind': kind,
            'range': {'start': {'line': start, 'character': 0},
                      'end': {'line': end, 'character': 5}},
            'selectionRange': {'start': {'line': start, 'character': 9},
                               'end': {'line': start, 'character': 9 + len(name)}},
            'children': list(children)}


def benchmark(config, functions=1000, length=50000, rounds=5):
    session = LspFixture()
    session.setUp()
    try:
        source = session.source.with_suffix('.cpp')
        rows = ['class Root {']
        methods = []
        for index in range(functions):
            start = len(rows)
            name = f'f{index:05d}'
            rows += [f'    void {name}() {{', '        int first = 1;',
                     '        int second = 2;', '    }']
            methods.append(node(name, 6, start, start + 3))
        positions = {'same_position': [[3, 1], [3, 1]],
                     'same_scope_rows': [[3, 1], [4, 1]],
                     'different_scopes': [[3, 1], [functions * 4 - 1, 1]]}
        for name, text in [('long_ascii', 'x' * length),
                           ('long_unicode', '中🙂e\u0301' * max([1, length // 5]))]:
            start = len(rows)
            body = '        const char *value = "' + text + '";'
            rows += [f'    void {name}() {{', body, '        return;', '    }']
            methods.append(node(name, 6, start, start + 3))
            size = len(body.encode('utf-8'))
            positions[name] = [[start + 2, size - 1], [start + 2, size]]
        rows.append('};')
        source.write_text('\n'.join(rows) + '\n')
        root = node('Root', 5, 0, len(rows) - 1, methods)
        root['selectionRange'] = {'start': {'line': 0, 'character': 6},
                                  'end': {'line': 0, 'character': 10}}
        responses = session.work / 'responses.json'
        responses.write_text(json.dumps({'results': {'textDocument/documentSymbol': [root]}}))
        command = session.command + ['--response-config', str(responses)]
        report = session.work / 'context-metrics.json'
        body = WAIT + r'''
call lsp#enable()
execute 'edit ' . fnameescape(''' + quoted(source) + r''')
call cursor(3, 1)
call WaitFor({-> VimContextLabel() ==# ':Root:f00000'})
let positions = ''' + json.dumps(positions) + r'''
let metrics = {}
for [name, points] in items(positions)
  let samples = []
  let lookup_count = name =~# '^long_' ? 20 : 1000
  for round in range(''' + str(rounds) + r''')
    let started = reltime()
    for iteration in range(lookup_count)
      call cursor(points[iteration % 2])
      let label = VimContextLabel()
      if label !~# '^:Root:'
        throw 'missing context for ' . name
      endif
    endfor
    call add(samples, reltimefloat(reltime(started)) * 1000 / lookup_count)
  endfor
  let metrics[name] = samples
endfor
call assert_equal([], popup_list())
call writefile([json_encode(metrics)], ''' + quoted(report) + r''', 'S')
'''
        session.vim(body, config=config, before=[
            'let g:vimrc_lite_large_file_bytes = 0',
            'let g:vimrc_lite_lsp_diagnostics = 0',
            'let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps(command)], timeout=60)
        metrics = json.loads(report.read_text())
        return {name: {'median_ms': round(statistics.median(values), 4),
                       'max_ms': round(max(values), 4)}
                for name, values in metrics.items()}
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--functions', type=int, default=1000)
    parser.add_argument('--length', type=int, default=50000)
    parser.add_argument('--rounds', type=int, default=5)
    args = parser.parse_args()
    if min(args.functions, args.length, args.rounds) < 1:
        parser.error('functions, length and rounds must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.functions, args.length,
                               args.rounds), indent=2))
