"""Background snapshots preserve native output, focus, filters, and lifecycle."""

import json
import shutil

from test_vim import ROOT, VimSession, quoted

WAIT = r'''
function! WaitForTree() abort
  let started = reltime()
  while execute('VimTreeListStatus') !~# 'no listings running'
    if reltimefloat(reltime(started)) > 5
      call assert_report('tree listing timed out')
      return
    endif
    sleep 1m
  endwhile
endfunction
'''


class AsyncTreeTests(VimSession):
    def copy_config(self, worker):
        config = self.work / 'config'
        config.mkdir()
        for path in [ROOT / '.vimrc'] + list(ROOT.glob('*.vim')):
            shutil.copyfile(path, config / path.name)
        shutil.copytree(ROOT / 'colors', config / 'colors')
        shutil.copytree(ROOT / 'vendor', config / 'vendor')
        (config / 'tree-list.vim').write_text(worker)
        return config / '.vimrc'

    def make_tree(self, count=1200):
        directory = self.work / 'listing'
        directory.mkdir()
        for index in range(count):
            (directory / f'file_{index:04d}.txt').touch()
        child = directory / 'child space 中文'
        child.mkdir()
        (child / 'nested.txt').touch()
        (directory / '.hidden').touch()
        (directory / 'run.sh').write_text('#!/bin/sh\n')
        (directory / 'run.sh').chmod(0o755)
        (directory / 'link').symlink_to('file_0000.txt')
        return directory

    def test_complete_snapshot_matches_sync_and_preserves_focus_during_refresh(self):
        directory = self.make_tree()
        report = self.work / 'snapshot.json'
        self.terminal_vim(WAIT + 'cd ' + str(directory) + r'''
edit draft.txt
call setline(1, 'unsaved')
let editor = win_getid()
let draft = bufnr('%')
call feedkeys(' e', 'xt')
let tree = win_getid()
call assert_match('loading', VimTreeStatusLabel())
call feedkeys("\<C-l>", 'xt')
call assert_equal(editor, win_getid())
call WaitForTree()
call assert_equal(editor, win_getid(), 'completion stole focus')
call feedkeys("\<C-h>", 'xt')
call assert_true(search('file_1199.txt', 'nw') > 0)
call assert_true(search('child space 中文/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call WaitForTree()
call assert_true(search('nested.txt', 'w') > 0)
let view = winsaveview()
call writefile([], get(w:, 'netrw_treetop') . '/child space 中文/new.txt')
call feedkeys('R', 'xt')
call assert_equal(view, winsaveview(), 'refresh changed the existing view while loading')
call feedkeys("\<C-l>", 'xt')
call WaitForTree()
call assert_equal(editor, win_getid())
call feedkeys("\<C-h>", 'xt')
call assert_true(search('new.txt', 'nw') > 0)
call assert_true(search('nested.txt', 'nw') > 0)
call assert_equal(['unsaved'], getbufline(draft, 1, '$'))
call assert_true(getbufvar(draft, '&modified'))
call writefile([json_encode(getline(1, '$'))], ''' + quoted(report) + r''')
call assert_notmatch('background listing failed', execute('messages'))
''')
        async_lines = json.loads(report.read_text())
        self.terminal_vim(WAIT + 'cd ' + str(directory) + r'''
call feedkeys(' e', 'xt')
call assert_true(search('child space 中文/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call feedkeys('R', 'xt')
call writefile([json_encode(getline(1, '$'))], ''' + quoted(report) + r''')
''', before=['let g:vimrc_lite_tree_async = 0'])
        self.assertEqual(async_lines, json.loads(report.read_text()))

    def test_filters_preserve_literal_suffix_names_in_sync_and_async_modes(self):
        (self.work / 'build').mkdir()
        (self.work / 'build.txt').touch()
        (self.work / 'pair').touch()
        (self.work / 'pair@').touch()
        for asynchronous in [0, 1]:
            self.terminal_vim(WAIT + r'''
call feedkeys(' e', 'xt')
call WaitForTree()
call assert_equal(0, search('build/$', 'nw'))
call assert_true(search('build.txt', 'nw') > 0)
call assert_equal(0, search('| pair$', 'nw'))
call assert_true(search('pair@\%(\t\|$\)', 'nw') > 0)
''', before=['let g:vimrc_lite_tree_async = ' + str(asynchronous),
             'let g:vimrc_lite_tree_async_threshold = 1',
             "let g:vimrc_lite_tree_ignore = ['build/', 'pair']"])

    def test_reload_resumes_pending_listing_and_close_cancels_it(self):
        directory = self.make_tree()
        self.terminal_vim(WAIT + 'cd ' + str(directory) + r'''
call feedkeys(' e', 'xt')
source ''' + str(ROOT / '.vimrc') + r'''
call WaitForTree()
call assert_true(search('file_1199.txt', 'nw') > 0)
call feedkeys('R', 'xt')
call assert_match('loading', VimTreeStatusLabel())
call feedkeys(' e', 'xt')
sleep 10m
call assert_match('no listings running', execute('VimTreeListStatus'))
call assert_equal(1, winnr('$'))
call feedkeys(' e', 'xt')
call WaitForTree()
call assert_true(search('file_1199.txt', 'nw') > 0)
''')

    def test_direct_directory_startup_and_refresh_keeps_types_hidden_and_sorting(self):
        directory = self.make_tree()
        self.terminal_vim(WAIT + r'''
call assert_equal('netrw', &filetype)
call WaitForTree()
call assert_true(search('file_1199.txt', 'nw') > 0)
for key in ['H', 'H', 'R']
  call feedkeys(key, 'xt')
  call WaitForTree()
  call assert_true(search('run.sh\*$', 'nw') > 0)
  call assert_true(search('link@\%(\t\|$\)', 'nw') > 0)
  call assert_true(search('file_0000.txt', 'nw') < search('file_1199.txt', 'nw'))
endfor
''', args=[str(directory)])

    def test_worker_failure_falls_back_to_complete_listing(self):
        directory = self.make_tree()
        config = self.copy_config('cquit\n')
        self.terminal_vim(WAIT + 'cd ' + str(directory) + r'''
call feedkeys(' e', 'xt')
call WaitForTree()
call assert_true(search('file_1199.txt', 'nw') > 0)
call assert_match('background listing failed', execute('messages'))
call assert_equal('', VimTreeStatusLabel())
''', config=config)

    def test_changed_filters_discard_stale_snapshot_and_rescan(self):
        directory = self.make_tree()
        config = self.copy_config('sleep 50m\nsource ' + str(ROOT / 'tree-list.vim') + '\n')
        self.terminal_vim(WAIT + 'cd ' + str(directory) + r'''
call feedkeys(' e', 'xt')
let g:vimrc_lite_tree_ignore = ['file_1199.txt']
call WaitForTree()
call assert_equal(0, search('file_1199.txt', 'nw'))
call assert_true(search('file_1198.txt', 'nw') > 0)
call assert_notmatch('background listing failed', execute('messages'))
''', config=config)
