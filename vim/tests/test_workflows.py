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

if __name__ == '__main__':
    unittest.main(verbosity=2)
