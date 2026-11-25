"""Behavior checks for native Markdown editing, structure and lifecycle."""

from test_vim import ROOT, VimSession, quoted
import random


WAIT = r'''
function! WaitMd() abort
  call VimMarkdownIndexChanged()
  for attempt in range(1000)
    if get(b:vimrc_lite_md_index, 'complete', 0)
      return
    endif
    sleep 2m
  endfor
  call assert_report('Markdown index did not finish')
endfunction
'''


class MarkdownTests(VimSession):
    def md(self, body, before=None):
        self.vim(WAIT + '\nnew sample.md\n' + body, before=before)

    def test_display_and_navigation_never_modify_source(self):
        self.md(r'''
call setline(1, ['# 中文标题', '', '- [ ] 任务', '> 引用',
      \ '[链接](https://example.com)', '```python', 'print("你好")', '```'])
call WaitMd()
setlocal nomodified
let original = getline(1, '$')
let tick = b:changedtick
let undo = undotree()
let properties = exists('*prop_list') ? prop_list(1) : []
let matches = getmatches()
for attempt in range(10)
  normal! j
  VimMarkdownRender
endfor
vsplit
vertical resize 35
wincmd p
close
call assert_equal(original, getline(1, '$'))
call assert_equal(tick, b:changedtick)
call assert_equal(undo, undotree())
call assert_equal(0, &modified)
call assert_equal(matches, getmatches())
call assert_equal(properties, exists('*prop_list') ? prop_list(1) : [])
call assert_equal('VimMarkdownH1', synIDattr(synID(1, 4, 1), 'name'))
call assert_equal('VimMarkdownCode', synIDattr(synID(7, 2, 1), 'name'))
''')

    def test_lists_quotes_tasks_and_empty_exit(self):
        for line, expected in [('- 中文', ['- 中文', '- next']),
                               ('  9) item', ['  9) item', '  10) next']),
                               ('- [x] done', ['- [x] done', '- [ ] next']),
                               ('> > - [!] item', ['> > - [!] item', '> > - [ ] next']),
                               ('> quote', ['> quote', '> next']),
                               ('- ', ['', 'next']), ('> ', ['', 'next'])]:
            with self.subTest(line=line):
                self.md('call setline(1, ' + quoted(line) + r''')
call WaitMd()
call feedkeys("A\<CR>next\<Esc>", 'xt')
call assert_equal(''' + str(expected).replace('\\', '\\\\') + r''', getline(1, '$'))
''')

    def test_fences_frontmatter_comments_and_unclosed_blocks(self):
        self.md(r'''
call setline(1, ['---', 'title: x', '---', '# 正文', '````python', '- literal',
      \ '```', '# fake', '````', '<!--', '# hidden', '- hidden', '-->',
      \ '~~~', '- literal', '~~~', '`<!--`', '# visible', '<!-- inline -->', '# final'])
call WaitMd()
call assert_equal([4, 18, 20], map(copy(VimMarkdownHeaders()), 'v:val.line'))
for lnum in [2, 6, 8, 11, 12, 15]
  call assert_equal(1, VimMarkdownContext(lnum), string(lnum))
endfor
for lnum in [4, 17, 18, 20]
  call assert_equal(0, VimMarkdownContext(lnum), string(lnum))
endfor
call cursor(6, 1)
call feedkeys("A\<CR>plain\<Esc>", 'xt')
call assert_equal('plain', getline(7))
call setline(10, 'not a closing fence')
call WaitMd()
call assert_equal([4], map(copy(VimMarkdownHeaders()), 'v:val.line'))
''')

    def test_context_revalidates_after_immediate_edits_and_line_insertion(self):
        self.md(r'''
call setline(1, ['# start'] + repeat(['paragraph'], 140) + ['- item', '# end'])
call WaitMd()
call setline(130, '```')
call cursor(142, 1)
call feedkeys("A\<CR>literal\<Esc>", 'xt')
call assert_equal('literal', getline(143))
call WaitMd()
call assert_equal([1], map(copy(VimMarkdownHeaders()), 'v:val.line'))
call setline(130, 'paragraph')
call WaitMd()
call assert_equal([1, 144], map(copy(VimMarkdownHeaders()), 'v:val.line'))
call append(1, ['new line', 'another'])
call WaitMd()
call assert_equal([1, 146], map(copy(VimMarkdownHeaders()), 'v:val.line'))
''')

    def test_task_range_preserves_code_and_one_undo(self):
        self.md(r'''
call setline(1, ['- [ ] one', '> - [!] two', '```', '- [ ] literal', '```', '文字'])
call WaitMd()
let original = getline(1, '$')
call feedkeys("gg", 'xt')
1,6VimMarkdownTask
call assert_equal(['- [x] one', '> - [x] two', '```', '- [ ] literal', '```',
      \ '- [ ] 文字'], getline(1, '$'))
undo
call assert_equal(original, getline(1, '$'))
''')

    def test_chinese_table_alignment_escaped_pipes_and_idempotence(self):
        self.md(r'''
call setline(1, ['| 名字 | value |', '| :--- | ---: |',
      \ '| 中文 | `a|b` |', '| a\|b | x |'])
call WaitMd()
call feedkeys("i\<C-g>u\<Esc>", 'xt')
VimMarkdownTable
let output = getline(1, '$')
call assert_equal(4, len(output))
call assert_match('a\\|b', output[3])
call assert_match('`a|b`', output[2])
call assert_equal(strdisplaywidth(output[0]), strdisplaywidth(output[2]))
let tick = b:changedtick
VimMarkdownTable
call assert_equal(tick, b:changedtick)
call assert_equal(output, getline(1, '$'))
undo
call assert_equal('| 中文 | `a|b` |', getline(3))
''')

    def test_visual_multibyte_wrap_and_code_delimiter(self):
        self.md(r'''
call setline(1, '前中文后')
call WaitMd()
call cursor(1, 4)
call feedkeys("vl\<Space>mb", 'xt')
call assert_equal('前**中文**后', getline(1))
undo
call assert_equal('前中文后', getline(1))
call setline(1, 'a `b` c')
VimMarkdownWrap code
call assert_equal('``a `b` c``', getline(1))
''')

    def test_templates_have_single_undo_and_preserve_trailing_spaces_on_save(self):
        path = self.work / 'note.md'
        self.md(r'''
VimMarkdownInsert code python
call assert_equal(['```python', '', '```'], getline(1, '$'))
call assert_equal(2, line('.'))
undo
call assert_equal([''], getline(1, '$'))
VimMarkdownInsert table 2 2
call assert_equal(4, line('$'))
call setline(1, 'hard break  ')
execute 'write! ' . fnameescape(''' + quoted(path) + r''')
call assert_equal('hard break  ', readfile(''' + quoted(path) + r''')[0])
''')

    def test_heading_navigation_counts_setext_and_outline(self):
        self.md(r'''
call setline(1, ['# one', '', '二', '===', '```', '# fake', '```', '## three'])
call WaitMd()
normal 2]h
call assert_equal(8, line('.'))
normal [h
call assert_equal(3, line('.'))
let source = bufnr('%')
VimMarkdownOutline
call assert_equal('vimmarkdownoutline', &filetype)
call assert_match('three', getline(6))
call cursor(4, 1)
call feedkeys("\<CR>", 'xt')
call assert_equal(source, bufnr('%'))
call assert_equal(1, line('.'))
''')

    def test_toc_duplicate_chinese_anchors_and_update(self):
        self.md(r'''
call setline(1, ['# 中文', '## same', '## same', '## same'])
call WaitMd()
VimMarkdownToc
call assert_true(search('\[中文\](#中文)', 'nw') > 0)
call assert_true(search('\[same\](#same-2)', 'nw') > 0)
call WaitMd()
let tick = b:changedtick
VimMarkdownToc
call assert_equal(tick, b:changedtick)
call cursor(line('$'), 1)
VimMarkdownToc
call assert_equal(1, len(filter(getline(1, '$'), 'v:val ==# "<!-- vim-markdown-toc -->"')))
''')

    def test_link_to_local_file_and_chinese_anchor(self):
        target = self.work / 'other file.md'
        target.write_text('# 开始\n\n## 中文\n', encoding='utf-8')
        self.md(r'''
call setline(1, '[go](other file.md#中文)')
call WaitMd()
VimMarkdownLink
for attempt in range(100)
  sleep 2m
  if line('.') == 3
    break
  endif
endfor
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_equal(3, line('.'))
''')

    def test_window_options_do_not_leak_and_filetype_detaches(self):
        self.md(r'''
call WaitMd()
call assert_true(&wrap)
call assert_true(&linebreak)
vnew plain.txt
call assert_false(&wrap)
call assert_false(&linebreak)
wincmd p
setfiletype text
setlocal filetype=text
call assert_false(exists('b:vimrc_lite_md_options'))
call assert_false(get(maparg("\<CR>", 'i', 0, 1), 'buffer', 0))
call assert_false(&wrap)
''')

    def test_reload_and_hidden_buffer_reentry_restart_index(self):
        self.md(r'''
call setline(1, ['# one', '## two'])
call WaitMd()
let source = bufnr('%')
new plain.txt
execute 'source ' . fnameescape(''' + quoted(ROOT / '.vimrc') + r''')
execute 'buffer ' . source
call WaitMd()
call assert_equal([1, 2], map(copy(VimMarkdownHeaders()), 'v:val.line'))
call feedkeys("Go- item\<CR>next\<Esc>", 'xt')
call assert_equal('- next', getline('$'))
call assert_equal('', v:errmsg)
''')

    def test_module_can_be_disabled_without_markdown_timers(self):
        self.md(r'''
call assert_false(exists('b:vimrc_lite_md_index'))
call assert_false(get(maparg("\<CR>", 'i', 0, 1), 'buffer', 0))
call assert_equal([], filter(timer_info(), 'string(v:val.callback) =~# "_Chunk"'))
''', before=['let g:vimrc_lite_markdown = 0'])

    def test_large_file_keeps_existing_fast_text_mode(self):
        path = self.work / 'large.md'
        path.write_text('- item\n' * 200000)
        self.vim('edit ' + str(path) + r'''
call assert_equal('text', &filetype)
call assert_false(exists('b:vimrc_lite_md_index'))
call assert_false(get(maparg("\<CR>", 'i', 0, 1), 'buffer', 0))
''')

    def test_nested_lists_quoted_fences_and_dedented_blocks(self):
        self.md(r'''
call setline(1, ['- parent', '    - child', '      ```', '      - literal',
      \ '      ```', '# outside', '> ```', '> - literal', '> ```', '# after',
      \ '> ```', '> - unclosed', '# outside quote'])
call WaitMd()
call assert_equal([6, 10, 13], map(copy(VimMarkdownHeaders()), 'v:val.line'))
for lnum in [4, 8, 12]
  call assert_equal(1, VimMarkdownContext(lnum), string(lnum))
endfor
call cursor(2, 1)
call feedkeys("A\<CR>next\<Esc>", 'xt')
call assert_equal('    - next', getline(3))
''')

    def test_toc_ignores_markers_in_code_and_preserves_search(self):
        self.md(r'''
call setline(1, ['# 中文', '```', '<!-- vim-markdown-toc -->',
      \ 'literal', '<!-- /vim-markdown-toc -->', '```', '## foo_bar',
      \ '## same', '## same', '## same-1'])
call WaitMd()
let @/ = 'keep search'
VimMarkdownToc
call assert_equal('keep search', @/)
call assert_true(index(getline(1, '$'), 'literal') > 0)
call assert_true(index(getline(1, '$'), '  - [foo_bar](#foo_bar)') > 0)
call assert_true(index(getline(1, '$'), '  - [same-1](#same-1-1)') > 0)
call WaitMd()
let tick = b:changedtick
VimMarkdownToc
call assert_equal(tick, b:changedtick)
''')

    def test_code_wrap_pads_backtick_boundaries(self):
        self.md(r'''
call setline(1, '`literal`')
VimMarkdownWrap code
call assert_equal('`` `literal` ``', getline(1))
''')

    def test_focus_and_manual_section_folding_restore_options(self):
        self.md(r'''
call setline(1, ['# one', 'paragraph', '## child', 'body', '# two', 'body'])
call WaitMd()
VimMarkdownFocus
call assert_false(&number)
call assert_false(&cursorline)
VimMarkdownFocus
call assert_true(&number)
call assert_true(&cursorline)
call cursor(3, 1)
VimMarkdownFold
call assert_equal(3, foldclosed(3))
call assert_equal(4, foldclosedend(3))
VimMarkdownFold
call assert_equal(-1, foldclosed(3))
VimMarkdownFocus
new plain.txt
call assert_true(&number)
call assert_true(&cursorline)
''')

    def test_incremental_structure_matches_fresh_parse_after_random_edits(self):
        randomizer = random.Random(817)
        actions = []
        for _ in range(24):
            line = randomizer.randrange(1, 180)
            text = randomizer.choice(['# 标题', '## child', '```', '<!--', '-->',
                                      'plain', '- item', '', '===', '~~~'])
            operation = randomizer.choice(['set', 'set', 'append', 'delete'])
            if operation == 'set':
                actions.append(f'call setline({line}, {quoted(text)})')
            elif operation == 'append':
                actions.append(f'call append({line}, {quoted(text)})')
            else:
                actions.append(f'{line}delete _')
            actions.append(r'''
call WaitMd()
let incremental = deepcopy(VimMarkdownHeaders())
let protected = map(range(1, line('$')), 'VimMarkdownContext(v:val)')
call VimMarkdownIndexStop(bufnr('%'))
call VimMarkdownIndexAttach()
call WaitMd()
call assert_equal(incremental, VimMarkdownHeaders())
call assert_equal(protected, map(range(1, line('$')), 'VimMarkdownContext(v:val)'))
''')
        self.md("call setline(1, repeat(['# title', 'paragraph', '', '- item'], 50))\n"
                "call WaitMd()\n" + '\n'.join(actions))

    def test_reload_disable_restores_hidden_buffers_and_user_mappings(self):
        self.vim(WAIT + r'''
new plain.txt
inoremap <buffer> <CR> USER
setlocal filetype=markdown
call WaitMd()
let source = bufnr('%')
new other.md
call WaitMd()
let g:vimrc_lite_markdown = 0
execute 'source ' . fnameescape(''' + quoted(ROOT / '.vimrc') + r''')
call assert_false(get(maparg('j', 'n', 0, 1), 'buffer', 0))
call assert_false(exists('b:vimrc_lite_md_options'))
execute 'buffer ' . source
call assert_equal('USER', maparg("\<CR>", 'i'))
call assert_false(get(maparg('j', 'n', 0, 1), 'buffer', 0))
call assert_false(&wrap)
''')

    def test_percent_encoded_link_with_parentheses_and_anchor(self):
        target = self.work / 'other (file).md'
        target.write_text('# root\n## 中文\n', encoding='utf-8')
        self.md(r'''
call setline(1, '[go](other%20(file).md#%E4%B8%AD%E6%96%87)')
call WaitMd()
VimMarkdownLink
call WaitMd()
sleep 10m
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_equal(2, line('.'))
''')

    def test_completion_enter_confirms_selection_or_inserts_newline(self):
        for select, expected in [(False, ['base', '', 'baseword baseother']),
                                 (True, ['baseword', 'baseword baseother'])]:
            with self.subTest(select=select):
                self.terminal_vim(WAIT + r'''
edit sample.md
call setline(1, ['', 'baseword baseother'])
call WaitMd()
let g:saw_menu = 0
let g:attempts = 0
function! MdCompletion(timer) abort
  let g:attempts += 1
  if pumvisible()
    let g:saw_menu = 1
    call feedkeys("''' + (r'\<C-n>' if select else '') + r'''\<CR>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:attempts > 100
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('MdCompletion'), {'repeat': -1})
call feedkeys('ibase', 'xt!')
call assert_equal(1, g:saw_menu)
call assert_equal(''' + str(expected) + r''', getline(1, '$'))
''')

    def test_outline_rejects_stale_source_positions(self):
        self.md(r'''
call setline(1, ['# first', 'body', '# second'])
call WaitMd()
let source = bufnr('%')
VimMarkdownOutline
call setbufline(source, 1, 'changed heading')
call cursor(5, 1)
call feedkeys("\<CR>", 'xt')
call assert_equal('vimmarkdownoutline', &filetype)
call assert_match('outline changed', execute('messages'))
''')

    def test_tree_focus_resumes_pending_index(self):
        self.terminal_vim(WAIT + r'''
edit sample.md
call setline(1, repeat(['# 标题', 'paragraph', '- [ ] task', ''], 300))
call WaitMd()
let source = bufnr('%')
for round in range(12)
  call setline(2, 'changed ' . round)
  call feedkeys("\<Space>e", 'xt')
  sleep 80m
  call feedkeys("\<Space>e", 'xt')
  call assert_equal(source, bufnr('%'))
  call WaitMd()
endfor
''')

    def test_long_lines_use_horizontal_editing_and_restore_wrap_after_shortening(self):
        self.md(r'''
call setline(1, ['# title', repeat('a', 120000), '# end'])
call WaitMd()
call assert_false(&wrap)
let tick = b:changedtick
VimMarkdownRender
call assert_equal(tick, b:changedtick)
call setline(2, 'normal paragraph')
call WaitMd()
call assert_true(&wrap)
''')

    def test_queued_task_and_table_commands_cover_the_entire_changed_region(self):
        self.md(r'''
call setline(1, repeat(['- [ ] task'], 200))
call WaitMd()
call setline(1, '- [ ] changed')
1,200VimMarkdownTask
sleep 100m
call assert_equal('- [x] task', getline(200))
%delete _
call setline(1, ['| 名称 | value |', '| :--- | ---: |'] + repeat(['| 中文 | x |'], 398))
call WaitMd()
call setline(3, '| Longer name | 123 |')
VimMarkdownTable
sleep 200m
call assert_equal(strdisplaywidth(getline(1)), strdisplaywidth(getline(400)))
call assert_equal(400, line('$'))
''')

    def test_native_terminal_heading_conceal_and_colors_follow_cursor_without_modifications(self):
        self.terminal_vim(WAIT + r'''
edit sample.md
call setline(1, ['# Heading', 'plain text', '', '```', '# literal', '```'])
call WaitMd()
setlocal nomodified
let tick = b:changedtick
call cursor(2, 1)
redraw
let row = win_screenpos(winnr())[0]
let heading = join(map(range(1, &columns), 'screenstring(row, v:val)'), '')
call assert_match('Heading', heading)
call assert_notmatch('# Heading', heading)
let column = stridx(heading, 'Heading') + 1
call assert_notequal(screenattr(row, column), screenattr(row + 1, column))
call cursor(1, 1)
redraw
let heading = join(map(range(1, &columns), 'screenstring(row, v:val)'), '')
call assert_match('# Heading', heading)
call assert_equal(tick, b:changedtick)
call assert_false(&modified)
''')

    def test_installed_configuration_loads_editor_and_preview_resources(self):
        import subprocess
        target = self.work / 'installed'
        result = subprocess.run(['bash', str(ROOT / 'vim-install.sh'), '--config-only',
                                 '--target-dir', str(target)], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)
        for name in ['markdown.vim', 'markdown-structure.vim', 'markdown-preview.vim']:
            self.assertEqual((ROOT / name).read_bytes(), (target / '.vim' / name).read_bytes())
        helper = 'netrw-tools/autoload/netrw.vim'
        self.assertEqual((ROOT / helper).read_bytes(), (target / '.vim' / helper).read_bytes())
        self.vim(WAIT + r'''
edit installed.md
call setline(1, ['# installed', '- [ ] task'])
call WaitMd()
call cursor(2, 1)
VimMarkdownTask
call assert_equal('- [x] task', getline(2))
call feedkeys("\<Space>e\<Space>e", 'xt')
call assert_equal('markdown', &filetype)
VimMarkdownPreview!
for attempt in range(200)
  sleep 5m
  if exists('g:vimrc_lite_markdown_preview_url')
    break
  endif
endfor
call assert_true(exists('g:vimrc_lite_markdown_preview_url'))
VimMarkdownStop
''', config=target / '.vimrc')

    def test_huge_short_line_document_uses_large_file_guard(self):
        path = self.work / 'many-lines.md'
        path.write_text('#\n' * 100001)
        self.vim('edit ' + str(path) + r'''
call assert_equal('text', &filetype)
call assert_equal(1, b:vimrc_lite_large_file)
call assert_false(exists('b:vimrc_lite_md_index'))
call assert_equal('OFF', &syntax)
''')

    def test_inline_comments_preserve_outer_tasks_tables_and_following_headings(self):
        self.md(r'''
call setline(1, ['# title <!-- note -->', '- [ ] task <!-- note -->', '',
      \ '| name | value |', '| --- | --- |', '| a <!-- note --> | x |',
      \ '| b | y |', '<!-- `-->`', '# after'])
call WaitMd()
call assert_equal([1, 9], map(copy(VimMarkdownHeaders()), 'v:val.line'))
call cursor(2, 1)
VimMarkdownTask
call assert_equal('- [x] task <!-- note -->', getline(2))
call WaitMd()
call cursor(5, 1)
VimMarkdownTable
call assert_equal(strdisplaywidth(getline(4)), strdisplaywidth(getline(7)))
''')

    def test_table_preserves_indent_reuses_structure_and_limits_output_growth(self):
        self.md(r'''
call setline(1, ['- parent', '  | name | value |', '  | --- | --- |',
      \ '  | 中文 | x |', '# after'])
call WaitMd()
let batches = b:vimrc_lite_md_index.batches
call cursor(3, 1)
VimMarkdownTable
call assert_match('^  |', getline(4))
call assert_equal([5], map(copy(VimMarkdownHeaders()), 'v:val.line'))
sleep 80m
call assert_equal(batches, b:vimrc_lite_md_index.batches)
let headers = deepcopy(VimMarkdownHeaders())
let protected = map(range(1, line('$')), 'VimMarkdownContext(v:val)')
call VimMarkdownIndexStop(bufnr('%'))
call VimMarkdownIndexAttach()
call WaitMd()
call assert_equal(headers, VimMarkdownHeaders())
call assert_equal(protected, map(range(1, line('$')), 'VimMarkdownContext(v:val)'))
%delete _
call setline(1, ['| name | value |', '| --- | --- |', '| ' . repeat('x', 8000) . ' | a |']
      \ + repeat(['| x | b |'], 20))
call WaitMd()
let original = getline(1, '$')
let tick = b:changedtick
call cursor(1, 1)
VimMarkdownTable
call assert_equal(original, getline(1, '$'))
call assert_equal(tick, b:changedtick)
call assert_match('would exceed 64 KiB', execute('messages'))
''')
