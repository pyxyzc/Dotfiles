#!/usr/bin/env python3
"""Repeatable local microbenchmarks; excludes terminal/network transport time."""

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

from test_vim import VIM


ROOT = Path(__file__).resolve().parents[1]


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def benchmark(config, buffers=200, functions=1000, bulk_lines=100000):
    with tempfile.TemporaryDirectory(prefix='vim-operations-') as temporary:
        work = Path(temporary)
        cpp = work / 'objects.cpp'
        cpp.write_text(''.join(
            f'int function_{i}() {{\n  // a comment with {{ braces }}\n'
            '  const char *text = "ignored { brace }";\n  return 42;\n}\n'
            for i in range(functions)))
        python = work / 'objects.py'
        python.write_text(''.join(
            f'def function_{i}():\n    if ready:\n        return 42\n\n'
            for i in range(functions)))
        tracked = work / 'tracked.txt'
        tracked.write_text(''.join(f'line {i}\n' for i in range(10000)))
        bulk = work / 'bulk.txt'
        bulk.write_text('    example content   \n' * bulk_lines)
        subprocess.run(['git', 'init', '-q', str(work)], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'add', 'tracked.txt'], check=True)
        report = work / 'metrics.json'
        script = work / 'benchmark.vim'
        script.write_text(r'''
set nomore
let metrics = {}
function! Measure(name, command, count) abort
  let times = []
  for iteration in range(a:count)
    let started = reltime()
    execute a:command
    call add(times, reltimefloat(reltime(started)) * 1000)
  endfor
  let g:metrics[a:name] = get(g:metrics, a:name, []) + times
endfunction
let prefix = matchstr(maparg("\<C-w>", 'n'), '<SNR>\d\+_')
''' + f'''
for number in range({buffers})
  execute 'badd /virtual/project/package' . number . '/src/main.py'
endfor
call Measure('buffer_bar_cold', 'call ' . prefix . 'BufferLine()', 1)
call Measure('buffer_bar_warm', 'call ' . prefix . 'BufferLine()', 100)
edit {cpp}
''' + r'''
let object = matchstr(maparg('af', 'x'), '<SNR>\d\+_')
call Measure('cpp_object_cold', 'call ' . object . "CObject('function', 3)", 1)
call Measure('cpp_object_warm', 'call ' . object . "CObject('function', 3)", 5)
call Measure('cpp_object_last', 'call ' . object . "CObject('function', line('$') - 1)", 5)
''' + f'edit {python}\n' + r'''
call Measure('python_object_cold', 'call ' . object . "PythonObject('function', 3)", 1)
call Measure('python_object_warm', 'call ' . object . "PythonObject('function', 3)", 5)
call Measure('python_object_last', 'call ' . object . "PythonObject('function', line('$') - 1)", 5)
''' + f'edit {tracked}\n' + r'''
call setline(5, 'changed')
call setline(9995, 'changed again')
let git = matchstr(maparg(']c', 'n'), '<SNR>\d\+_')
call Measure('git_hunks_cold', 'call ' . git . 'Hunks()', 1)
call Measure('git_hunks_warm', 'call ' . git . 'Hunks()', 20)
''' + f'edit! {bulk}\n' + r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
for round in range(3)
  let &undolevels = &undolevels
  call Measure('range_comment', 'call ' . editor . "ToggleComments(1, line('$'))", 1)
  call assert_equal('    # example content   ', getline(1))
  let &undolevels = &undolevels
  call Measure('range_uncomment', 'call ' . editor . "ToggleComments(1, line('$'))", 1)
  call assert_equal('    example content   ', getline(1))
endfor
call Measure('range_trim', 'call ' . editor . 'TrimWhitespace()', 1)
call assert_equal('    example content', getline('$'))
let clipboard = matchstr(execute('command VimCopyPath'), '<SNR>\d\+_')
call Measure('osc52_encode', 'call ' . clipboard . 'Osc52(join(getline(1, "$"), "\n"))', 1)
let &undolevels = &undolevels
call Measure('range_clear', 'call ' . editor . 'ClearBuffer()', 1)
call assert_equal([''], getline(1, '$'))
call Measure('range_undo', 'undo', 1)
call assert_equal('    example content', getline('$'))
call Measure('range_save', 'write', 1)
if !empty(v:errors)
  cquit
endif
''' + f'call writefile([json_encode(metrics)], {quote(report)}, "s")\nqa!\n')
        command = [VIM, '-Nu', str(config), '-i', 'NONE', '-n', '-es',
                   '--cmd', 'let g:vimrc_lite_lsp = 0',
                   '--cmd', 'let g:vimrc_lite_osc52 = 0']
        environment = dict(os.environ, XDG_STATE_HOME=str(work / 'state'))
        startup = []
        for _ in range(10):
            started = time.perf_counter()
            subprocess.run(command + ['-c', 'qa!'], cwd=work, check=True,
                           capture_output=True, timeout=10, env=environment)
            startup.append((time.perf_counter() - started) * 1000)
        subprocess.run(command + ['-S', str(script)], cwd=work, check=True,
                       capture_output=True, timeout=120, env=environment)
        values = json.loads(report.read_text())
        values['startup_process'] = startup
        return {name: {'median_ms': round(statistics.median(samples), 3),
                       'max_ms': round(max(samples), 3)}
                for name, samples in values.items()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--buffers', type=int, default=200)
    parser.add_argument('--functions', type=int, default=1000)
    parser.add_argument('--bulk-lines', type=int, default=100000)
    args = parser.parse_args()
    if args.buffers < 1 or args.functions < 1 or args.bulk_lines < 1:
        parser.error('buffers, functions and bulk-lines must be positive')
    print(json.dumps(benchmark(args.config.resolve(), args.buffers, args.functions,
                              args.bulk_lines), indent=2))
