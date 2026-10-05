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

if __name__ == '__main__':
    unittest.main(verbosity=2)
