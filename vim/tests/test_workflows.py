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

if __name__ == '__main__':
    unittest.main(verbosity=2)
