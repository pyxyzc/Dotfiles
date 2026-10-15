#!/usr/bin/env python3
"""Measure Markdown Space-e latency through deferred layout and terminal redraw."""

import argparse
import json
from pathlib import Path
from statistics import median

from test_vim import ROOT, VimSession, quoted


SECTION = '''# Heading {index}

- [ ] pending task
- [x] finished task

| 项目 | 状态 |
| :--- | ---: |
| 中文 | ready |
| longer name | 7 |

> [!WARNING] Review
> quote_body
<!-- hidden comment -->

end
'''


def benchmark(config, sections=80, rounds=5, document=None, profile=None):
    session = VimSession()
    session.setUp()
    try:
        if document is None:
            document = session.work / 'reader.md'
            document.write_text(''.join(SECTION.format(index=i) for i in range(sections)))
        report = session.work / 'metrics.json'
        body = "execute 'edit ' . fnameescape(" + quoted(document) + ')\n' + r'''
normal! G
redraw!
let source = bufnr('%')
let metrics = {'lines': line('$'), 'open_ms': [], 'close_ms': [], 'open_widths': []}
'''
        if profile:
            body += "execute 'profile start ' . " + quoted(profile) + '\nprofile func *\n'
        body += 'for round in range(' + str(rounds) + ')\n' + r'''
  let started = reltime()
  call feedkeys(' e', 'xt')
  call assert_equal('netrw', &filetype)
  " sleep 允许零延迟的窗口重排计时器执行；把这部分工作计入可用时间。
  sleep 1m
  while execute('VimTreeListStatus') !~# 'no listings running'
    if reltimefloat(reltime(started)) > 5
      throw 'tree listing did not finish'
    endif
    sleep 1m
  endwhile
  redraw!
  call add(metrics.open_ms, reltimefloat(reltime(started)) * 1000)
  let info = getwininfo(win_findbuf(source)[0])[0]
  call add(metrics.open_widths, {'actual': max([24, info.width - get(info, 'textoff', 4) - 1]),
        \ 'rendered': get(getbufvar(source, 'vimrc_lite_markdown_view_plan', {}), 'width', -1)})
  let started = reltime()
  call feedkeys(' e', 'xt')
  sleep 1m
  redraw!
  call add(metrics.close_ms, reltimefloat(reltime(started)) * 1000)
  call assert_equal('markdown', &filetype)
endfor
'''
        if profile:
            body += 'profile pause\n'
        body += 'call writefile([json_encode(metrics)], ' + quoted(report) + ', "S")\n'
        session.terminal_vim(body, config=config)
        metrics = json.loads(report.read_text())
        metrics['reopen_median_ms'] = median(metrics['open_ms'][1:])
        metrics['close_median_ms'] = median(metrics['close_ms'])
        return metrics
    finally:
        session.doCleanups()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / '.vimrc')
    parser.add_argument('--document', type=Path)
    parser.add_argument('--sections', type=int, default=80)
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--profile', type=Path)
    args = parser.parse_args()
    if args.sections < 1 or args.rounds < 2:
        parser.error('sections must be positive; rounds must be at least two')
    print(json.dumps(benchmark(args.config.resolve(), args.sections, args.rounds,
                               args.document.resolve() if args.document else None,
                               args.profile.resolve() if args.profile else None), indent=2))
