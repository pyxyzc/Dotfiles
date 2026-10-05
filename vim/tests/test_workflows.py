"""Integration checks for project workflows; all files and state are temporary."""

import json
import os
from pathlib import Path
import sys
import unittest

from test_vim import ROOT, VimSession, quoted
from test_lsp import WAIT
import test_vim


class WorkflowTests(VimSession):
    def setUp(self):
        super().setUp()
        self.env['HOME'] = str(self.work)
        (self.work / '.git').mkdir()

    def test_persistent_undo_across_processes_and_opt_out(self):
        source = self.work / 'undo 中文.txt'
        source.write_text('before\n')
        self.vim("edit " + str(source) + r'''
call assert_true(&undofile)
call feedkeys('ccafter' . "\<Esc>", 'xt')
write
call assert_equal('after', getline(1))
''')
        self.vim("edit " + str(source) + r'''
undo
call assert_equal('before', getline(1))
call assert_true(&modified)
call assert_false(&swapfile)
''')
        self.vim('call assert_false(&undofile)',
                 before=['let g:vimrc_lite_persistent_undo = 0'])
        self.assertTrue(any((self.work / 'state/vim-lite/undo').iterdir()))

    def test_operator_text_objects_delete_yank_change_and_no_match(self):
        self.vim(r'''
setfiletype python
call setline(1, ['def first():', '    return 1', '', 'def second():', '    return 2'])
call cursor(2, 5)
call feedkeys('yaf', 'xt')
call assert_equal("def first():\n    return 1\n", @")
call feedkeys('daf', 'xt')
call assert_equal(['', 'def second():', '    return 2'], getline(1, '$'))
call cursor(3, 5)
call feedkeys("cifreturn 99\<Esc>", 'xt')
call assert_equal(['', 'def second():', '    return 99'], getline(1, '$'))
call setline(1, ['plain text', 'another line'])
3,$delete _
call cursor(1, 1)
let before = getline(1, '$')
call feedkeys('daf', 'xt')
call assert_equal(before, getline(1, '$'))
enew!
setfiletype cpp
call setline(1, ['int first() {', '  return 1;', '}', '', 'int second() {', '  return 2;', '}'])
call cursor(2, 3)
call feedkeys('dif', 'xt')
call assert_equal(['int first() {', '}', '', 'int second() {', '  return 2;', '}'],
      \ getline(1, '$'))
''')

    def test_tree_rename_modified_and_hidden_buffers_and_directory_move(self):
        (self.work / 'old').mkdir()
        (self.work / 'old/main.py').write_text('disk\n')
        (self.work / 'old/hidden.txt').write_text('hidden\n')
        self.vim(r'''
edit old/hidden.txt
let hidden = bufnr('%')
edit old/main.py
let main = bufnr('%')
call setline(1, 'unsaved')
edit origin.txt
let origin = win_getid()
call feedkeys(' e', 'xt')
let tree = win_getid()
call assert_true(search('old/', 'w') > 0)
call feedkeys("r\<C-u>new\<CR>", 'xt')
call assert_equal(tree, win_getid())
call assert_equal(2, winnr('$'))
call assert_equal('new/main.py', fnamemodify(bufname(main), ':~:.'))
call assert_equal('new/hidden.txt', fnamemodify(bufname(hidden), ':~:.'))
call assert_true(getbufvar(main, '&modified'))
call assert_equal(['unsaved'], getbufline(main, 1, '$'))
call win_gotoid(origin)
execute 'buffer ' . main
undo
call assert_equal(['disk'], getline(1, '$'))
redo
call assert_equal(['unsaved'], getline(1, '$'))
write
call assert_equal(['unsaved'], readfile('new/main.py'))
call assert_false(isdirectory('old'))
call win_gotoid(tree)
call assert_true(search('new/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('main.py', 'w') > 0)
call feedkeys("r\<C-u>renamed.py\<CR>", 'xt')
call assert_equal('new/renamed.py', fnamemodify(bufname(main), ':~:.'))
call assert_false(filereadable('new/main.py'))
''')

    def test_tree_rename_refuses_conflicting_open_target(self):
        (self.work / 'old.txt').write_text('source\n')
        self.vim(r'''
edit target.txt
call setline(1, 'unsaved target')
let target = bufnr('%')
call feedkeys(' e', 'xt')
call assert_true(search('old.txt', 'w') > 0)
call feedkeys("r\<C-u>target.txt\<CR>", 'xt')
call assert_true(filereadable('old.txt'))
call assert_false(filereadable('target.txt'))
call assert_equal(['unsaved target'], getbufline(target, 1, '$'))
call assert_match('target already has an open buffer', execute('messages'))
''')

    def test_tree_cut_moves_open_modified_buffer_without_saving_it(self):
        (self.work / 'source.txt').write_text('disk\n')
        (self.work / 'destination').mkdir()
        self.vim(r'''
edit source.txt
let source = bufnr('%')
call setline(1, 'unsaved')
edit origin.txt
call feedkeys(' e', 'xt')
call assert_true(search('source.txt', 'w') > 0)
call feedkeys('x', 'xt')
call assert_true(search('destination/', 'w') > 0)
call feedkeys('p', 'xt')
call assert_equal(['disk'], readfile('destination/source.txt'))
call assert_false(filereadable('source.txt'))
call assert_equal('destination/source.txt', fnamemodify(bufname(source), ':~:.'))
call assert_true(getbufvar(source, '&modified'))
call assert_equal(['unsaved'], getbufline(source, 1, '$'))
''')

    def test_tasks_background_errors_cwd_and_output(self):
        source = self.work / 'main.py'
        source.write_text('source\n')
        script = self.work / 'task.py'
        script.write_text('import os,time,sys\n'
                          'time.sleep(.1)\n'
                          'print(os.getcwd())\n'
                          'print("main.py:1:2: build failed", file=sys.stderr)\n'
                          'sys.exit(3)\n')
        (self.work / '.vim-lite-tasks.json').write_text(json.dumps({'tasks': {
            'build': {'cmd': [sys.executable, str(script)], 'errorformat': '%f:%l:%c: %m'}}}))
        self.terminal_vim(WAIT + r'''
edit main.py
let origin = win_getid()
let cwd = getcwd()
VimTask build
call assert_match('running', execute('VimTaskStatus'))
call setline(1, 'editing during task')
call WaitFor({-> execute('VimTaskStatus') =~# 'exit 3'})
call assert_equal(origin, win_getid())
call assert_equal(cwd, getcwd())
call assert_equal('editing during task', getline(1))
let entries = getqflist()
call assert_equal(1, len(entries))
call assert_equal(expand('%:p'), fnamemodify(bufname(entries[0].bufnr), ':p'))
call assert_equal([1, 2, 'build failed'], [entries[0].lnum, entries[0].col, entries[0].text])
VimTaskOutput
call assert_match('build failed', join(getline(1, '$'), "\n"))
call assert_match(cwd, join(getline(1, '$'), "\n"))
call feedkeys('q', 'xt')
call assert_equal(origin, win_getid())
''')

    def test_task_cancel_invalid_config_and_preserve_new_quickfix(self):
        self.terminal_vim(WAIT + r'''
let g:vimrc_lite_tasks = {'slow': [''' + quoted(sys.executable) + r''', '-c',
      \ 'import time; print("start", flush=True); time.sleep(30)']}
VimTask slow
let task_id = getqflist({'id': 0}).id
call setqflist([], ' ', {'title': 'newer list', 'items': [{'text': 'keep me'}]})
let newer_id = getqflist({'id': 0}).id
VimTask slow
call assert_match('a task is running', execute('messages'))
VimTaskStop
call WaitFor({-> execute('VimTaskStatus') !~# 'running'})
call assert_equal(newer_id, getqflist({'id': 0}).id)
call assert_equal('newer list', getqflist({'title': 0}).title)
call assert_match('cancelled', getqflist({'id': task_id, 'title': 0}).title)
call writefile(['invalid JSON'], '.vim-lite-tasks.json')
VimTask slow
call assert_match('Vim task:', execute('messages'))
call assert_equal(newer_id, getqflist({'id': 0}).id)
''')

    def test_session_restores_tabs_layout_views_and_skips_auxiliary_buffers(self):
        for name in ['one.txt', 'two.txt', 'three.txt']:
            (self.work / name).write_text('one\ntwo\nthree\nfour\n')
        self.vim(r'''
edit one.txt
vsplit two.txt
call cursor(3, 2)
tabnew three.txt
call cursor(2, 1)
let active_path = expand('%:p')
let root = VimLiteProjectRoot()
VimSessionSave work
tabonly
only
edit one.txt
VimSessionLoad work
call assert_equal(2, tabpagenr('$'))
call assert_equal(active_path, expand('%:p'))
call assert_equal([2, 1], [line('.'), col('.')])
call assert_equal(root, VimLiteProjectRoot())
tabfirst
call assert_equal('row', winlayout()[0])
call assert_equal(2, winnr('$'))
wincmd l
call assert_equal('two.txt', expand('%:t'))
call assert_equal([3, 2], [line('.'), col('.')])
call assert_match('work', execute('VimSessionList'))
''')

    def test_session_load_rejects_modified_missing_and_invalid_layout(self):
        (self.work / 'one.txt').write_text('saved\n')
        self.vim(r'''
edit one.txt
VimSessionSave
let origin = win_getid()
call setline(1, 'unsaved')
VimSessionLoad
call assert_equal('unsaved', getline(1))
call assert_equal(origin, win_getid())
call assert_match('modified buffers', execute('messages'))
setlocal nomodified
let paths = glob($XDG_STATE_HOME . '/vim-lite/sessions/*/default.json', 0, 1)
let saved = readfile(paths[0])
call delete('one.txt')
VimSessionLoad
call assert_equal(origin, win_getid())
call assert_match('missing file', execute('messages'))
call writefile(['saved'], 'one.txt')
call writefile(['{"version":1,"tabs":[],"root":"bad"}'], paths[0])
VimSessionLoad
call assert_equal(origin, win_getid())
call assert_equal(1, tabpagenr('$'))
VimSessionSave ../escape
call assert_match('session name', execute('messages'))
''')

    def test_session_restores_hidden_file_list_across_processes(self):
        for name in ['hidden.txt', 'visible.txt']:
            (self.work / name).write_text('saved\n')
        self.vim(r'''
edit hidden.txt
edit visible.txt
VimSessionSave persisted
''')
        self.vim(r'''
VimSessionLoad persisted
call assert_equal('visible.txt', expand('%:t'))
call assert_true(buflisted(bufnr('hidden.txt')))
call assert_false(bufloaded(bufnr('hidden.txt')))
call assert_equal(1, winnr('$'))
''')

    def test_reusable_terminal_preserves_job_and_shell_state(self):
        self.terminal_vim(r'''
set shell=sh
edit origin.txt
let origin = win_getid()
VimTerminalToggle
let terminal = bufnr('%')
let job = term_getjob(terminal)
call term_sendkeys(terminal, "VALUE=remembered\n")
call term_wait(terminal, 30)
stopinsert
VimTerminalToggle
call assert_equal(origin, win_getid())
call assert_true(bufexists(terminal))
call assert_equal('run', job_status(job))
VimTerminalToggle
call assert_equal(terminal, bufnr('%'))
call assert_equal(job, term_getjob(terminal))
call term_sendkeys(terminal, "printf 'value:%s' \"$VALUE\"\n")
for attempt in range(100)
  call term_wait(terminal, 10)
  if TerminalScreen(terminal) =~# 'value:remembered' | break | endif
endfor
call assert_match('value:remembered', TerminalScreen(terminal))
call term_sendkeys(terminal, "exit\n")
for attempt in range(200)
  sleep 10m
  if !bufexists(terminal) | break | endif
endfor
call assert_false(bufexists(terminal))
call assert_equal(origin, win_getid())
''')

    def test_health_and_key_query_and_reload(self):
        self.vim(r'''
let origin = win_getid()
VimKeys rename
call assert_match('符号重命名', join(getline(1, '$'), "\n"))
call assert_match('<Space>rn', join(getline(1, '$'), "\n"))
call feedkeys('q', 'xt')
call assert_equal(origin, win_getid())
VimKeys language server
call assert_match('<Space>ci', join(getline(1, '$'), "\n"))
call assert_match('LSP 状态面板', join(getline(1, '$'), "\n"))
call feedkeys('q', 'xt')
VimHealth
call assert_match('Project:', join(getline(1, '$'), "\n"))
call assert_match('Undo:', join(getline(1, '$'), "\n"))
call assert_match('missing executable:', join(getline(1, '$'), "\n"))
call feedkeys('q', 'xt')
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(2, exists(':VimTask'))
call assert_equal(2, exists(':VimSessionSave'))
call assert_true(&undofile)
''')


class SearchWorkflowTests(VimSession):
    # Only the new cases belong to this suite; existing SearchTests are run separately.
    def setUp(self):
        super().setUp()
        if not test_vim.shutil.which('gawk'):
            self.skipTest('requires gawk')
        self.project = self.work / 'project with spaces'
        self.project.mkdir()
        (self.project / '.git').mkdir()
        (self.project / 'src').mkdir()
        self.session = self.work / 'search session'
        self.session.mkdir()

    fake_fzf = test_vim.SearchTests.fake_fzf
    require_backends = test_vim.SearchTests.require_backends
    wait_search = staticmethod(test_vim.SearchTests.wait_search)

    @unittest.skipUnless(test_vim.shutil.which('fzf'), 'requires real fzf')
    def test_seeded_visual_literal_search_and_ctrl_q_single_result(self):
        self.require_backends()
        source = self.project / 'source.txt'
        source.write_text('a+b[0]\n')
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(source) + r''')
let origin = bufnr('%')
let @z = 'keep z'
let @" = 'keep unnamed'
call feedkeys('gg0v$' . "\<Space>fw", 'xt')
let terminal = winbufnr(popup_list()[0])
for attempt in range(200)
  call term_wait(terminal, 10)
  if TerminalScreen(terminal) =~# '1/1' | break | endif
endfor
call assert_match('1/1', TerminalScreen(terminal))
call assert_match('a+b\[0\]', TerminalScreen(terminal))
call assert_equal('keep z', @z)
call assert_equal('keep unnamed', @")
call term_sendkeys(terminal, "\<C-q>")
''' + self.wait_search() + r'''
call assert_equal(1, len(getqflist()))
call assert_equal(origin, getqflist()[0].bufnr)
call assert_equal('qf', &filetype)
''')

    @unittest.skipUnless(test_vim.shutil.which('fzf'), 'requires real fzf')
    def test_seeded_word_search_opens_without_typing_query(self):
        self.require_backends()
        source = self.project / 'word.txt'
        source.write_text('unique_word\n')
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(source) + r''')
VimSearchWord
let terminal = winbufnr(popup_list()[0])
for attempt in range(200)
  call term_wait(terminal, 10)
  if TerminalScreen(terminal) =~# '1/1' | break | endif
endfor
call assert_match('1/1', TerminalScreen(terminal))
call term_sendkeys(terminal, "\<CR>")
''' + self.wait_search() + r'''
call assert_equal('word.txt', expand('%:t'))
call assert_equal([], getqflist())
''')
    def test_multiple_selected_results_export_exact_special_paths(self):
        self.fake_fzf()
        fake = self.work / 'bin/fzf'
        fake.write_text(fake.read_text().replace(
            "sys.stdout.buffer.write(records[0] + b'\\0')",
            "sys.stdout.buffer.write(b'\\0'.join(records[:2]) + b'\\0')"))
        for name in ['src/one:中文.txt', 'src/two\t%0A\n.txt']:
            (self.project / name).write_text('first\nneedle\n')
        self.env['SEARCH_TEST_QUERY'] = 'needle'
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(self.project / 'origin.txt') + r''')
call setline(1, 'unsaved origin')
let origin = bufnr('%')
VimSearch
''' + self.wait_search() + r'''
let entries = getqflist()
call assert_equal(2, len(entries))
call assert_equal([2, 2], map(copy(entries), 'v:val.lnum'))
call assert_equal([''' + quoted(self.project / 'src/one:中文.txt') + ', '
            + quoted(self.project / 'src/two\t%0A\n.txt') + r'''],
      \ sort(map(copy(entries), 'fnamemodify(bufname(v:val.bufnr), ":p")')))
call assert_equal(['unsaved origin'], getbufline(origin, 1, '$'))
call assert_equal('qf', &filetype)
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
