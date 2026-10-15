"""Exercise rendered terminal cells and source preservation, rather than only conceal options."""

import json
import os
from pathlib import Path
import subprocess
import unittest

from test_vim import ROOT, VIM, VimSession, quoted


DEMO = '''# 阅读视图 visual_marker

- [ ] pending_marker
- [x] complete_marker
- [-] progress_marker
- [!] blocked_marker

| 项目 | 状态 |
| :--- | ---: |
| 中文 | ready |
| longer name | 7 |

> [!WARNING] Review
> quote_body
> another

<!-- hidden_comment_marker
other hidden text
-->

```python
print('[ ] literal <!-- visible_code_comment -->')
```

[documentation](https://example.com/long/path)
![caption](sample.png)

---

anchor_cursor
'''


VIRTUAL = subprocess.run(
    [VIM, '-Nu', 'NONE', '-i', 'NONE', '-n', '-es',
     '-c', 'call prop_type_add("Probe", {})',
     '-c', 'if prop_add(1, 1, {"type": "Probe", "text": "x"}) >= 0 | cquit | endif',
     '-c', 'qa!'], capture_output=True).returncode == 0


class MarkdownViewTests(VimSession):
    def child(self, document):
        return r'''
let child = term_start([''' + quoted(VIM) + ', "-Nu", ' + quoted(ROOT / '.vimrc') + r''',
      \ '-i', 'NONE', '-n', ''' + quoted(document) + r'''],
      \ {'term_rows': 38, 'term_cols': 110, 'hidden': 1})
function! WaitMarkdown(child, text) abort
  for attempt in range(150)
    call term_wait(a:child, 10)
    let screen = TerminalScreen(a:child)
    if stridx(screen, a:text) >= 0
      return screen
    endif
  endfor
  call assert_report('Markdown terminal missing ' . a:text . ': ' . screen)
  return screen
endfunction
call WaitMarkdown(child, 'anchor_cursor')
call term_sendkeys(child, 'G')
call WaitMarkdown(child, '30:1')
'''

    @unittest.skipUnless(VIRTUAL, 'full table layout needs Vim virtual text')
    def test_reading_source_and_insert_screens_show_distinct_ui(self):
        document = self.work / 'reader.md'
        document.write_text(DEMO)
        capture = self.work / 'capture.json'
        output = self.work / 'saved.md'
        self.terminal_vim(self.child(document) + r'''
let reading = TerminalScreen(child)
call assert_match('╭─ WARNING · Review', reading)
call assert_match('╭─ python', reading)
call assert_match('│ 项目        │  状态 │', reading)
call assert_match('│ 中文        │ ready │', reading)
call assert_match('├─────────────┼───────┤', reading)
call assert_match('╰─────────────┴───────╯', reading)
call assert_match('□\s\+pending_marker', reading)
call assert_match('✓\s\+complete_marker', reading)
call assert_match('◐\s\+progress_marker', reading)
call assert_notmatch('•', reading)
call assert_notmatch('hidden_comment_marker', reading)
call assert_match('visible_code_comment', reading)
call assert_notmatch('https://example.com/long/path', reading)
call assert_match('↗ documentation', reading)
call assert_match('▣ caption', reading)
let frames = {'reading': map(range(1, term_getsize(child)[0]), 'term_scrape(child, v:val)')}
for row in frames.reading
  for cell in row
    let cell.bold = term_getattr(cell.attr, 'bold')
    let cell.strike = term_getattr(cell.attr, 'strike')
    let cell.italic = term_getattr(cell.attr, 'italic')
  endfor
  let text = join(map(copy(row), 'v:val.chars'), '')
  if text =~# 'complete_marker'
    let first = filter(copy(row), 'v:val.chars ==# "c"')[0]
    call assert_equal(1, first.strike)
    call assert_equal('#565f89', first.fg)
  elseif text =~# '项目'
    let first = filter(copy(row), 'v:val.chars ==# "项"')[0]
    call assert_equal('#7dcfff', first.fg)
    call assert_equal('#24283b', first.bg)
  endif
endfor
call term_sendkeys(child, ' mr')
let source = WaitMarkdown(child, 'MD:source')
call assert_match('| 项目 | 状态 |', source)
call assert_true(stridx(source, '- [ ] pending_marker') >= 0)
call assert_true(stridx(source, '- [-] progress_marker') >= 0)
call assert_match('hidden_comment_marker', source)
call assert_match('https://example.com/long/path', source)
call assert_notmatch('╭─ WARNING', source)
let frames.source = map(range(1, term_getsize(child)[0]), 'term_scrape(child, v:val)')
call term_sendkeys(child, ' mr')
let restored = WaitMarkdown(child, 'MD:read')
call assert_match('╰─────────────┴───────╯', restored)
call term_sendkeys(child, '10G')
call WaitMarkdown(child, '10:1')
call assert_match('| 中文 | ready |', TerminalScreen(child))
call term_sendkeys(child, '$iedited_marker')
let editing = WaitMarkdown(child, 'edited_marker')
call assert_true(stridx(editing, '- [ ] pending_marker') >= 0)
call assert_match('hidden_comment_marker', editing)
call assert_notmatch('╭─ WARNING', editing)
call term_sendkeys(child, "\<Esc>G")
call WaitMarkdown(child, '30:')
let updated = WaitMarkdown(child, 'ready edited_marker │')
call assert_match('ready edited_marker', updated)
call term_sendkeys(child, ":write! ''' + str(output) + r'''\<CR>")
call term_wait(child, 80)
call writefile([json_encode(frames)], ''' + quoted(capture) + r''')
call term_sendkeys(child, ":qa!\<CR>")
call term_wait(child, 50)
''')
        saved = output.read_text()
        self.assertEqual(saved, DEMO.replace('| 中文 | ready |', '| 中文 | ready edited_marker|'))
        if destination := os.environ.get('VIM_MARKDOWN_NATIVE_CAPTURE'):
            Path(destination).write_bytes(capture.read_bytes())

    def test_view_never_changes_source_tick_and_clears_only_its_decorations(self):
        self.vim(r'''
enew
setfiletype markdown
let original = ['# Header', '', '| a | b |', '| --- | --- |', '| 中文 | value |',
      \ '', '- [x] done', '<!-- private -->', '', 'anchor']
call setline(1, original)
call cursor(10, 1)
let tick = b:changedtick
let unrelated = matchadd('Search', 'value')
call VimMarkdownViewRefresh()
call assert_equal(original, getline(1, '$'))
call assert_equal(tick, b:changedtick)
call assert_match('MD:read', VimMarkdownStatusLabel())
let table_matches = copy(w:vimrc_lite_markdown_view_matches['3'])
call cursor(9, 1)
call VimMarkdownViewRefresh()
call assert_equal(table_matches, w:vimrc_lite_markdown_view_matches['3'])
VimMarkdownRender
call assert_equal(tick, b:changedtick)
call assert_match('MD:source', VimMarkdownStatusLabel())
call assert_equal({}, w:vimrc_lite_markdown_view_matches)
call assert_equal([unrelated], map(getmatches(), 'v:val.id'))
call assert_equal([], filter(prop_list(3), 'v:val.type =~# "^VimMarkdownView_"'))
VimMarkdownRender
call assert_equal(original, getline(1, '$'))
call assert_equal(tick, b:changedtick)
enew
setfiletype python
call assert_equal('', VimMarkdownStatusLabel())
call assert_equal([unrelated], map(getmatches(), 'v:val.id'))
''')

    def test_mode_is_per_document_and_split_windows_remain_consistent(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['| a | b |', '| --- | --- |', '| x | y |', '', 'anchor'])
let source = bufnr('%')
call cursor(5, 1)
call VimMarkdownViewRefresh()
vsplit
let windows = win_findbuf(source)
call cursor(3, 1)
call VimMarkdownViewRefresh()
VimMarkdownRender
for window in windows
  call assert_equal(0, getwinvar(window, '&conceallevel'))
  call assert_equal({}, getwinvar(window, 'vimrc_lite_markdown_view_matches'))
endfor
call assert_equal([], filter(prop_list(1), 'v:val.type =~# "^VimMarkdownView_"'))
enew
setfiletype markdown
call setline(1, ['# Different document', '', 'anchor'])
call assert_equal(0, b:vimrc_lite_markdown_raw)
call assert_equal(2, &l:conceallevel)
execute 'buffer ' . source
call assert_equal(1, b:vimrc_lite_markdown_raw)
call assert_equal(0, &l:conceallevel)
VimMarkdownRender
for window in windows
  call assert_equal(2, getwinvar(window, '&conceallevel'))
endfor
''')

    def test_tree_resize_reuses_plan_and_table_decorations_at_final_width(self):
        document = self.work / 'tree-reader.md'
        original = ('# ' + 'long heading ' * 4 + '\n\n' + DEMO)
        document.write_text(original)
        self.terminal_vim(r'''
edit ''' + str(document) + r'''
normal! G
call VimMarkdownViewRefresh()
let source = bufnr('%')
let window = win_getid()
let plan = b:vimrc_lite_markdown_view_plan
let tick = b:changedtick
let table_line = search('^| 项目', 'nw')
let table_matches = copy(w:vimrc_lite_markdown_view_matches[string(table_line)])
let table_props = prop_list(table_line)
let wide_heading = plan.rows['1'].replace[0]
for round in range(3)
  call feedkeys(' e', 'xt')
  sleep 1m
  call assert_equal('netrw', &filetype)
  call assert_true(plan is getbufvar(source, 'vimrc_lite_markdown_view_plan'))
  let info = getwininfo(window)[0]
  call assert_equal(max([24, info.width - get(info, 'textoff', 4) - 1]), plan.width)
  call assert_true(strdisplaywidth(plan.rows['1'].replace[0]) < strdisplaywidth(wide_heading))
  call assert_equal(table_matches, getwinvar(window, 'vimrc_lite_markdown_view_matches')[string(table_line)])
  call assert_equal(table_props, prop_list(table_line, {'bufnr': source}))
  call assert_equal({}, get(w:, 'vimrc_lite_markdown_view_matches', {}))
  call feedkeys(' e', 'xt')
  sleep 1m
  call assert_equal(window, win_getid())
  call assert_true(plan is b:vimrc_lite_markdown_view_plan)
  call assert_equal(wide_heading, plan.rows['1'].replace[0])
  call assert_equal(table_matches, w:vimrc_lite_markdown_view_matches[string(table_line)])
  call assert_equal(table_props, prop_list(table_line))
  call assert_equal(tick, b:changedtick)
endfor
call assert_equal(readfile(expand('%')), getline(1, '$'))
''')

    def test_reflow_updates_cards_without_reparsing_or_touching_other_matches(self):
        self.terminal_vim(r'''
enew
setfiletype markdown
let original = ['# ' . repeat('Heading ', 7), '', '> [!NOTE] Card', '',
      \ '```python', repeat('x', 90), 'short', '```', '', '---', '',
      \ '| a | b |', '| --- | --- |', '| c | d |', '', 'anchor']
call setline(1, original)
call cursor(16, 1)
call VimMarkdownViewRefresh()
let source = bufnr('%')
let window = win_getid()
let plan = b:vimrc_lite_markdown_view_plan
let table_matches = copy(w:vimrc_lite_markdown_view_matches['12'])
let wide = deepcopy(plan.rows)
vnew
setfiletype text
vertical resize 60
call win_execute(window, 'call VimMarkdownViewRefresh()')
call assert_true(plan is getbufvar(source, 'vimrc_lite_markdown_view_plan'))
for line in ['1', '3', '5', '8', '10']
  call assert_true(strdisplaywidth(plan.rows[line].replace[0]) < strdisplaywidth(wide[line].replace[0]), line)
endfor
call assert_true(plan.rows['7'].fill < wide['7'].fill)
call assert_equal(table_matches, getwinvar(window, 'vimrc_lite_markdown_view_matches')['12'])
close
call VimMarkdownViewRefresh()
call assert_equal(wide, plan.rows)
call assert_equal(original, getline(1, '$'))
''')

    def test_inline_code_keeps_comment_and_link_literals_and_custom_tasks_toggle(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['`<!-- literal -->` `[label](path)`', '- [-] working', '- [!] blocked',
      \ '<!-- hidden --> visible', '', 'anchor'])
call cursor(6, 1)
call VimMarkdownViewRefresh()
call assert_false(has_key(w:vimrc_lite_markdown_view_matches, '1'))
call assert_true(has_key(w:vimrc_lite_markdown_view_matches, '4'))
2,3VimMarkdownTask
call assert_equal(['- [x] working', '- [x] blocked'], getline(2, 3))
2,3VimMarkdownTask
call assert_equal(['- [ ] working', '- [ ] blocked'], getline(2, 3))
''')

    def test_multiline_comments_do_not_render_fake_fences_or_tasks(self):
        self.vim(r'''
enew
setfiletype markdown
let original = ['<!--', '```python', '- [ ] hidden task', '# hidden heading', '-->',
      \ '# Real heading', '', 'anchor']
call setline(1, original)
call cursor(8, 1)
call VimMarkdownViewRefresh()
3VimMarkdownTask
call assert_equal(original, getline(1, '$'))
call cursor(1, 1)
normal ]h
call assert_equal(6, line('.'))
call assert_false(has_key(b:vimrc_lite_markdown_view_plan.rows, '2')
      \ && !empty(b:vimrc_lite_markdown_view_plan.rows['2'].replace))
VimMarkdownRender
call assert_equal(original, getline(1, '$'))
''')

    def test_table_keeps_literal_code_and_unclosed_fence_keeps_last_body_line(self):
        document = self.work / 'literal.md'
        document.write_text('| Name | Code |\n| --- | --- |\n| literal | `a*b*c` |\n\n'
                            '```python\nx = 1 # anchor_cursor\n---\n')
        self.terminal_vim(self.child(document).replace("'30:1'", "'7:1'") + r'''
call term_sendkeys(child, '4G')
call WaitMarkdown(child, '4:')
let screen = TerminalScreen(child)
call assert_match('a\*b\*c', screen)
call assert_match('---', screen)
call term_sendkeys(child, ":qa!\<CR>")
call term_wait(child, 50)
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
