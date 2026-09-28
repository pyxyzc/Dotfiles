"""File-tree navigation, entry resolution and copy checks in isolated fixtures."""

import os
import socket
import time

from test_vim import ROOT, VimSession, quoted


WAIT = r'''
function! WaitForCopy() abort
  let started = reltime()
  while execute('VimTreeCopyStatus') !~# 'no copies running'
    if reltimefloat(reltime(started)) > 3
      call assert_report('copy did not finish')
      return
    endif
    sleep 10m
  endwhile
endfunction
'''

COPY = r'''
call feedkeys(' e', 'xt')
call search('payload.txt', 'w')
call feedkeys('c', 'xt')
call search('destination/', 'w')
call feedkeys('p', 'xt')
'''


class TreeTests(VimSession):
    def test_fast_tree_render_matches_native_filtering_cache_and_view(self):
        self.vim(r'''
call feedkeys(' e', 'xt')
let prefix = ScriptPrefix('/autoload/netrw\.vim$')
let native_tree = prefix . 'NetrwTreeDisplay'
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let source_tree = {
      \ '/render root': ['before.txt', 'sub/', 'middle.txt', 'tail/', 'last.txt',
      \                  'closed/', 'alias@', 'HIDDEN.txt', 'hidden.txt', 'skip.bak', '.', '..', 'dot.'],
      \ '/render root/sub': ['nested/', 'one.txt', '.hidden', 'two.txt', "embedded\nnewline"],
      \ '/render root/sub/nested': ['deep.txt', 'skip.bak', 'dir/', 'link@'],
      \ '/render root/tail/': ['tail.txt', 'empty/'],
      \ '/render root/tail/empty': [],
      \ '/render root/alias@': ['not-used'],
      \ '/render root/alias/': ['alias-child']}
function! RenderTree(enabled) abort
  let g:vimrc_lite_netrw_fast_tree = a:enabled
  let w:netrw_treedict = deepcopy(g:source_tree)
  let w:netrw_treetop = '/render root'
  setlocal modifiable noreadonly foldenable
  silent keepjumps %delete _
  call setline(1, 'prefix')
  call cursor(1, 2)
  call setreg('"', ['keep', 'register'], 'V')
  call call(function(g:native_tree), [w:netrw_treetop, ''])
  return [getline(1, '$'), deepcopy(w:netrw_treedict), winsaveview(), &foldenable,
        \ getreg('"', 1, 1), getregtype('"'), g:netrw_hide]
endfunction
" 先在未安装适配时取得深树原生结果，防止转发层降低可用递归深度。
let ordinary_tree = source_tree
let source_tree = {}
let directory = '/render root'
for level in range(40)
  let source_tree[directory] = ['leaf' . level, 'nested/']
  let directory .= '/nested'
endfor
let source_tree[directory] = ['last.txt']
let g:netrw_hide = 0
let expected_deep = RenderTree(0)
let g:vimrc_lite_netrw_fast_tree = 1
call call(function(tree . 'InstallFastTree'), [prefix])
call assert_equal(expected_deep, RenderTree(1))
call assert_equal(expected_deep, RenderTree(0))
let source_tree = ordinary_tree
for hide in [0, 1, 2]
  let g:netrw_hide = hide
  for ignorecase in [0, 1]
    let &ignorecase = ignorecase
    for magic in [0, 1]
      let &magic = magic
      for pattern in ['', 'hidden', '\.bak$', 'hidden,\.bak$', '/', '\.\|txt']
        let g:netrw_list_hide = pattern
        let expected = RenderTree(0)
        call assert_equal(expected, RenderTree(1), string([hide, ignorecase, magic, pattern]))
      endfor
    endfor
  endfor
endfor
source ''' + str(ROOT / '.vimrc') + r'''
let g:netrw_hide = 0
call assert_equal(RenderTree(0), RenderTree(1))
''', before=['let g:vimrc_lite_netrw_fast_tree = 0'])

    def test_literal_type_suffixes_do_not_select_a_neighbouring_file(self):
        for index, mark in enumerate('@*=|'):
            (self.work / f'pair{index}').write_text('keep neighbour\n')
            (self.work / f'pair{index}{mark}').write_text('selected literal\n')
        (self.work / 'link-target').touch()
        (self.work / 'ambiguous').symlink_to('link-target')
        (self.work / 'ambiguous@').write_text('keep literal\n')
        (self.work / 'executable').write_text('#!/bin/sh\n')
        (self.work / 'executable').chmod(0o755)
        (self.work / 'executable*').write_text('keep literal\n')
        (self.work / 'stale').write_text('keep neighbour\n')
        (self.work / 'stale@').write_text('changed attributes\n')
        os.mkfifo(self.work / 'pipe')
        self.vim(r'''
call feedkeys(' e', 'xt')
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
for index in range(4)
  let mark = strpart('@*=|', index, 1)
  let base = 'pair' . index
  let literal = base . mark
  call assert_true(search('\V' . literal, 'w') > 0)
  let entry = call(function(tree . 'Entry'), [])
  call assert_equal(literal, entry.name)
  call assert_equal(getcwd() . '/' . literal, entry.path)
  call feedkeys("r\<C-u>renamed" . mark . "\<CR>", 'xt')
  call assert_equal(['keep neighbour'], readfile(base))
  call assert_false(filereadable(literal))
  call assert_equal(['selected literal'], readfile('renamed' . mark))
  call assert_true(search('\Vrenamed' . mark, 'w') > 0)
  call feedkeys("dy\<CR>", 'xt')
  call assert_false(filereadable('renamed' . mark))
  call assert_equal(['keep neighbour'], readfile(base))
endfor
" 若真实链接/可执行文件与字面后缀文件显示相同，拒绝猜测，不操作其中任意一个。
for name in ['ambiguous@', 'executable*']
  call assert_true(search('\V' . name, 'w') > 0)
  call assert_equal('', call(function(tree . 'Entry'), []).path)
  call feedkeys('d', 'xt')
endfor
call assert_equal('link', getftype('ambiguous'))
call assert_equal(['keep literal'], readfile('ambiguous@'))
call assert_true(executable(getcwd() . '/executable'))
call assert_equal(['keep literal'], readfile('executable*'))
call assert_match('ambiguous filename/type marker', execute('messages'))
" 列表生成后类型发生变化，也不能退回旁边那个不同名称的文件。
call setfperm('stale@', 'rwxr-xr-x')
call assert_true(search('\Vstale@', 'w') > 0)
call assert_equal('', call(function(tree . 'Entry'), []).path)
call feedkeys('d', 'xt')
call assert_equal(['keep neighbour'], readfile('stale'))
call assert_equal(['changed attributes'], readfile('stale@'))
" 真正的 FIFO 标记也必须剥离，不能把 pipe| 当成物理文件名。
call assert_true(search('\Vpipe|', 'w') > 0)
call assert_equal(getcwd() . '/pipe', call(function(tree . 'Entry'), []).path)
''')

    def test_fast_listing_matches_native_types_options_and_reload(self):
        directory = self.work / 'listing space 中文'
        directory.mkdir()
        (directory / 'sub').mkdir()
        for name in ['plain.txt', '.hidden', 'a[1].txt', "quote'.txt", 'back\\slash',
                     '中文😀.py', 'space name', 'trailing ', 'literal@', 'literal*']:
            (directory / name).write_text('sample\n')
        (directory / 'run.sh').write_text('#!/bin/sh\n')
        (directory / 'run.sh').chmod(0o755)
        (directory / 'link').symlink_to('plain.txt')
        (directory / 'dir-link').symlink_to('sub', target_is_directory=True)
        (directory / 'broken').symlink_to('missing')
        os.mkfifo(directory / 'pipe')
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.bind(str(directory / 'socket'))
        self.vim(r'''
execute 'cd ' . fnameescape(''' + quoted(directory) + r''')
call feedkeys(' e', 'xt')
let native = ScriptPrefix('/autoload/netrw\.vim$') . 'LocalListing'
function! Listing(enabled) abort
  let g:vimrc_lite_netrw_fast_listing = a:enabled
  setlocal modifiable noreadonly
  silent keepjumps %delete _
  call call(function(g:native), [])
  return [getline(1, '$'), &l:tabstop, get(g:, 'netrw_maxfilenamelen', 0)]
endfunction
for style in [0, 1, 2, 3]
  let w:netrw_liststyle = style
  for sorting in ['name', 'exten', 'size', 'time']
    let g:netrw_sort_by = sorting
    for dynamic in [0, 1]
      let g:netrw_dynamic_maxfilenamelen = dynamic
      let expected = Listing(0)
      call assert_equal(expected, Listing(1), string([style, sorting, dynamic]))
    endfor
  endfor
endfor
let w:netrw_liststyle = 3
let g:netrw_sort_by = 'name'
let g:netrw_dynamic_maxfilenamelen = 0
let expected = Listing(0)
for entry in ['run.sh*', 'sub/', 'pipe|', 'broken@']
  call assert_true(index(expected[0], entry) >= 0, entry)
endfor
" Vim 8.0 的 getftype 把 socket 报成 fifo；保持该 runtime 原有标记，不伪造现代结果。
let socket_suffix = getftype(b:netrw_curdir . '/socket') ==# 'socket' ? '=' : '|'
call assert_true(index(expected[0], 'socket' . socket_suffix) >= 0)
set wildignore=*.txt
let expected = Listing(0)
call assert_equal(expected, Listing(1))
set wildignore=
" 不同尾斜杠形式沿用同一套原生路径处理。
let b:netrw_curdir .= '/'
call assert_equal(Listing(0), Listing(1))
let b:netrw_curdir = substitute(b:netrw_curdir, '/$', '', '')
" 换行/回车文件名回退到原生 :put 语义，不悄悄改成 buffer 内 NUL。
call writefile([], b:netrw_curdir . "/line\nbreak")
call writefile([], b:netrw_curdir . "/carriage\r")
call assert_equal(Listing(0), Listing(1))
call delete(b:netrw_curdir . "/line\nbreak")
call delete(b:netrw_curdir . "/carriage\r")
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(Listing(0), Listing(1))
''')

    def test_fast_listing_leaves_unknown_native_implementation_untouched(self):
        self.vim(r'''
runtime autoload/netrw.vim
let native = ScriptPrefix('/autoload/netrw\.vim$') . 'LocalListing'
execute 'function! ' . native . "()\nlet g:unknown_listing_called = 1\nendfunction"
let native_tree = ScriptPrefix('/autoload/netrw\.vim$') . 'NetrwTreeDisplay'
execute 'function! ' . native_tree . "(dir, depth)\nlet g:unknown_tree_called = 1\nendfunction"
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
call call(function(tree . 'InstallFastListing'), [])
call assert_equal(-1, stridx(execute('function ' . native), 'FastListing'))
call assert_equal(-1, stridx(execute('function ' . native_tree), 'FastTreeDisplay'))
call call(function(native), [])
call assert_equal(1, g:unknown_listing_called)
call call(function(native_tree), ['unused', ''])
call assert_equal(1, g:unknown_tree_called)
''')

    def test_subtree_refresh_matches_native_sorting_and_preserves_register_and_cwd(self):
        sub = self.work / 'sub space 中文'
        sub.mkdir()
        (sub / 'directory').mkdir()
        for index, name in enumerate(['z.py', 'a.txt', 'middle.c', '.hidden', 'skip.bak']):
            path = sub / name
            path.write_text('x' * (index + 1))
            os.utime(path, (1700000000 + index, 1700000000 + index))
        self.terminal_vim(r'''
call feedkeys(' e', 'xt')
call assert_true(search('sub space 中文/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
let directory = b:netrw_curdir
let g:netrw_list_hide = '\.bak$'
let g:netrw_hide = 1
for sorting in ['name', 'size', 'time', 'exten']
  let g:netrw_sort_by = sorting
  for direction in ['normal', 'reverse']
    let g:netrw_sort_direction = direction
    let cwd = [getcwd(), haslocaldir()]
    call setreg('"', ['kept', 'register'], 'V')
    let view = winsaveview()
    call feedkeys('R', 'xt')
    call assert_equal(['kept', 'register'], getreg('"', 1, 1))
    call assert_equal('V', getregtype('"'))
    call assert_equal(cwd, [getcwd(), haslocaldir()])
    call assert_equal(view, winsaveview())
    call assert_equal(0, search('skip.bak', 'nw'))
    let refreshed = copy(w:netrw_treedict[directory])
    " 独立折叠/展开走 netrw 原生列举，比较排序、隐藏和类型结果。
    call assert_true(search('sub space 中文/', 'w') > 0)
    call feedkeys("\<CR>", 'xt')
    call assert_true(search('sub space 中文/', 'w') > 0)
    call feedkeys("\<CR>", 'xt')
    call assert_equal(refreshed, w:netrw_treedict[directory], sorting . '/' . direction)
  endfor
endfor
''')

    def test_refresh_expanded_subtrees_keeps_types_order_and_hidden_entries(self):
        nested = self.work / 'sub' / 'deep'
        nested.mkdir(parents=True)
        (nested / 'before.txt').touch()
        (self.work / '.hidden-root').touch()
        (self.work / 'sub' / 'z-last.txt').touch()
        (self.work / 'sub' / 'run.sh').write_text('#!/bin/sh\n')
        (self.work / 'sub' / 'run.sh').chmod(0o755)
        (self.work / 'sub' / 'link').symlink_to('z-last.txt')
        self.terminal_vim(r'''
edit draft.txt
call setline(1, 'unsaved draft')
let draft = bufnr('%')
call feedkeys(' e', 'xt')
let tree_window = win_getid()
call assert_true(search('sub/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('deep/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('before.txt', 'nw') > 0)
let root = w:netrw_treetop
let hidden = search('\.hidden-root', 'nw') > 0
call writefile([], root . '/sub/a-first.txt')
call writefile([], root . '/sub/.hidden-new')
call writefile([], root . '/sub/deep/after.txt')
call delete(root . '/sub/deep/before.txt')
call mkdir(root . '/sub/new-dir')
for key in ['R', "\<C-l>", 'R', 'H', 'H']
  call feedkeys(key, 'xt')
  if key ==# 'H' | let hidden = !hidden | endif
  call assert_equal(tree_window, win_getid())
  call assert_equal('netrw', &filetype)
  call assert_equal(0, search('before.txt', 'nw'))
  call assert_true(search('after.txt', 'nw') > 0)
  call assert_true(search('deep/$', 'nw') > 0)
  call assert_true(search('new-dir/$', 'nw') > 0)
  call assert_true(search('run.sh\*$', 'nw') > 0)
  call assert_true(search('link@', 'nw') > 0)
  call assert_equal(hidden, search('\.hidden-new', 'nw') > 0)
  call assert_equal(hidden, search('\.hidden-root', 'nw') > 0)
  call assert_true(search('a-first.txt', 'nw') < search('z-last.txt', 'nw'))
  call assert_equal(['unsaved draft'], getbufline(draft, 1, '$'))
  call assert_true(getbufvar(draft, '&modified'))
endfor
" 刷新保留深层展开后，新目录仍能按回车打开。
call assert_true(search('new-dir/$', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call writefile([], root . '/sub/new-dir/created.txt')
call feedkeys('R', 'xt')
call assert_true(search('created.txt', 'nw') > 0)
call assert_true(search('after.txt', 'nw') > 0)
''')

    def test_refresh_hidden_and_thin_listing_keep_tree_and_entries(self):
        (self.work / 'sub').mkdir()
        (self.work / 'sub' / 'nested.txt').touch()
        (self.work / 'plain.txt').touch()
        (self.work / '.hidden').touch()
        self.terminal_vim(r'''
edit draft.txt
call setline(1, 'unsaved draft')
let draft = bufnr('%')
call feedkeys(' e', 'xt')
let tree_window = win_getid()
call assert_true(search('sub/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('nested.txt', 'nw') > 0)
let hidden = search('\.hidden', 'nw') > 0
for key in ['H', 'H', 'R', "\<C-l>"]
  call feedkeys(key, 'xt')
  if key ==# 'H' | let hidden = !hidden | endif
  call assert_equal(hidden, search('\.hidden', 'nw') > 0)
  call assert_equal(tree_window, win_getid())
  call assert_equal('netrw', &filetype)
  call assert_true(search('nested.txt', 'nw') > 0)
  call assert_equal(['unsaved draft'], getbufline(draft, 1, '$'))
  call assert_true(getbufvar(draft, '&modified'))
endfor
" Thin-list entry lookup needs netrw#Call's return value, not just its side effect.
call feedkeys('i', 'xt')
call assert_equal(0, w:netrw_liststyle)
call assert_true(search('plain.txt', 'w') > 0)
call feedkeys('y', 'xt')
call assert_equal('plain.txt', @")
''')

    def test_direct_directory_toggle_closes_without_opening_another_tree(self):
        directory = self.work / 'directory'
        directory.mkdir()
        (directory / 'target.txt').touch()
        self.terminal_vim(r'''
call assert_equal('netrw', &filetype)
call feedkeys(' e', 'xt')
call assert_equal(1, winnr('$'))
call assert_notequal('netrw', &filetype)
call feedkeys(' e', 'xt')
call assert_equal(2, winnr('$'))
call assert_equal('netrw', &filetype)
call feedkeys(' e', 'xt')
call assert_equal(1, winnr('$'))
call assert_notequal('netrw', &filetype)
''', args=[str(directory)])

    def test_closing_direct_trees_preserves_editor_focus_changes_and_other_tabs(self):
        directory = self.work / 'directory'
        directory.mkdir()
        (directory / 'target.txt').touch()
        self.terminal_vim(r'''
edit draft.txt
call setline(1, 'unsaved draft')
let draft = bufnr('%')
let editor = win_getid()
vsplit directory
let first = win_getid()
split
call assert_equal('netrw', &filetype)
call assert_equal(3, winnr('$'))
tabnew directory
let other_tab = win_getid()
tabprevious
call win_gotoid(editor)
call feedkeys(' e', 'xt')
call assert_equal(1, winnr('$'))
call assert_equal(editor, win_getid())
call assert_equal(['unsaved draft'], getline(1, '$'))
call assert_true(&modified)
call assert_equal('netrw', getbufvar(getwininfo(other_tab)[0].bufnr, '&filetype'))
" 目录占用唯一窗口时不退出 Vim，也不丢掉隐藏 buffer 中的未保存内容。
edit directory
call assert_equal('netrw', &filetype)
call feedkeys(' e', 'xt')
call assert_notequal('netrw', &filetype)
call assert_equal(['unsaved draft'], getbufline(draft, 1, '$'))
call assert_true(getbufvar(draft, '&modified'))
call assert_equal('netrw', getbufvar(getwininfo(other_tab)[0].bufnr, '&filetype'))
" 有有效的备用编辑 buffer 时直接返回它。
edit directory
if exists(':balt') == 2
  balt draft.txt
else
  execute 'buffer ' . draft
  edit directory
endif
call assert_equal(draft, bufnr('#'))
call feedkeys(' e', 'xt')
call assert_equal(draft, bufnr('%'))
call assert_equal(['unsaved draft'], getline(1, '$'))
''')

    def test_entry_search_matches_ancestor_walk_and_preserves_editor_state(self):
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
function! TreeCall(name, args) abort
  return call(function(g:tree . a:name), a:args)
endfunction
" 保留旧的逐行算法作为独立比对，覆盖兄弟子树、混合缩进和缺失父层。
function! WalkEntry() abort
  let name = TreeCall('Name', [getline('.')])
  let parent = TreeCall('Depth', [getline('.')]) - 1
  let parts = [substitute(name, '/$', '', '')]
  let lnum = line('.') - 1
  while lnum >= 1 && parent >= 1
    if TreeCall('Depth', [getline(lnum)]) == parent
      call insert(parts, substitute(TreeCall('Name', [getline(lnum)]), '/$', '', ''))
      let parent -= 1
    endif
    let lnum -= 1
  endwhile
  return {'name': name, 'path': '/tree/' . join(parts, '/'), 'dir': name =~# '/$'}
endfunction
enew
let b:netrw_curdir = '/tree/another-current-directory'
let w:netrw_treetop = '/tree'
let w:netrw_liststyle = 3
call setline(1, ['tree/', '| alpha/', '| | child/', '| | | deep 中文.txt',
      \ '| | | more.txt', '| | target.txt', '│ beta/', '│ | nested/',
      \ '│ | │ run.sh*', '│ | │ link@', '│ | spaced name.txt',
      \ '│ sibling/', '│ │ last.txt', '| root.txt', '| | | missing-parent.txt'])
let @/ = 'unrelated search'
let v:searchforward = 0
let @" = 'unchanged register'
call histadd('search', 'unrelated history')
let history = histget('search', -1)
let jumps = exists('*getjumplist') ? getjumplist() : getpos("''")
for lnum in range(2, line('$'))
  call cursor(lnum, strlen(getline(lnum)))
  normal! zz
  let view = winsaveview()
  call assert_equal(WalkEntry(), TreeCall('Entry', []), string(lnum))
  call assert_equal(view, winsaveview())
  call assert_equal('unrelated search', @/)
  call assert_equal(0, v:searchforward)
  call assert_equal(history, histget('search', -1))
  call assert_equal('unchanged register', @")
  call assert_equal(jumps, exists('*getjumplist') ? getjumplist() : getpos("''"))
endfor
call cursor(1, 1)
call assert_equal('', TreeCall('Entry', []).path)
call cursor(6, 1)
call assert_equal('/tree/alpha/target.txt', TreeCall('Entry', []).path)
" 上游没有树根变量时仍退回当前目录，不保留上次解析的路径。
unlet w:netrw_treetop
let b:netrw_curdir = '/fallback'
call assert_equal('/fallback/alpha/target.txt', TreeCall('Entry', []).path)
call setline(2, '| renamed/')
call assert_equal('/fallback/renamed/target.txt', TreeCall('Entry', []).path)
''')

    def test_nested_entry_yank_rename_and_delete_after_expanded_sibling(self):
        nested = self.work / 'nested 中文'
        sibling = nested / 'sibling'
        sibling.mkdir(parents=True)
        for index in range(1000):
            (sibling / f'file_{index:04d}.txt').touch()
        target = nested / 'target.txt'
        target.write_text('preserve content\n')
        self.vim(r'''
call feedkeys(' e', 'xt')
call assert_true(search('nested 中文/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('sibling/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_true(search('file_0999.txt', 'w') > 0)
call assert_true(search('target.txt', 'w') > 0)
call feedkeys('Y', 'xt')
call assert_equal('nested 中文/target.txt', @")
call feedkeys("r\<C-u>renamed.txt\<CR>", 'xt')
call assert_false(filereadable('nested 中文/target.txt'))
call assert_equal(['preserve content'], readfile('nested 中文/renamed.txt'))
call assert_true(search('renamed.txt', 'w') > 0)
call feedkeys("dy\<CR>", 'xt')
call assert_false(filereadable('nested 中文/renamed.txt'))
call assert_true(filereadable('nested 中文/sibling/file_0999.txt'))
''')

    def test_direct_directory_startup_prepares_netrw_before_vimenter(self):
        directory = self.work / 'directory space'
        directory.mkdir()
        (directory / 'target.txt').touch()
        self.terminal_vim(r'''
call assert_equal('netrw', &filetype)
call assert_equal(1, g:backends_prepared)
call assert_true(search('target.txt', 'w') > 0)
call assert_equal(''' + quoted(directory) + r''', b:netrw_curdir)
''', args=[str(directory)], before=[
            "autocmd VimEnter * let g:backends_prepared = "
            "exists('g:loaded_netrw') && exists('g:netrw_dav_cmd') && exists('g:netrw_fetch_cmd')",
        ])

    def test_open_failure_restores_new_window_directory(self):
        (self.work / 'target').mkdir()
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let original = getcwd()
command! Lexplore vnew <bar> throw 'deliberate tree failure'
try
  call call(function(tree . 'OpenTree'), [original . '/target'])
  call assert_report('expected tree failure')
catch /deliberate tree failure/
endtry
call assert_equal(2, winnr('$'))
for window in range(1, winnr('$'))
  call assert_equal(original, getcwd(window))
  call assert_equal(0, haslocaldir(window))
endfor
''')

    def test_open_restores_global_tab_and_window_directories_and_keeps_listing_fresh(self):
        project = self.work / 'project space 中文'
        project.mkdir()
        (project / 'target.txt').write_text('target\n')
        (self.work / 'tabdir').mkdir()
        (self.work / 'windowdir').mkdir()
        self.vim(r'''
let root = getcwd()
let project = ''' + quoted(project) + r'''
for scope in (exists(':tcd') == 2 ? ['global', 'tab', 'window'] : ['global', 'window'])
  execute 'cd ' . fnameescape(root)
  if scope ==# 'tab'
    execute 'tcd ' . fnameescape(root . '/tabdir')
  elseif scope ==# 'window'
    execute 'lcd ' . fnameescape(root . '/windowdir')
  endif
  let first = win_getid()
  let first_directory = getcwd()
  let first_scope = haslocaldir()
  rightbelow vnew
  execute 'lcd ' . fnameescape(root)
  execute 'edit ' . fnameescape(project . '/target.txt')
  let editor = win_getid()
  let tab_directory = getcwd(-1, tabpagenr())
  let global_directory = getcwd(-1)
  call feedkeys(' e', 'xt')
  call assert_equal('netrw', &filetype)
  call assert_equal(project, b:netrw_curdir)
  call assert_equal(first_directory, getcwd())
  call assert_equal(first_scope, haslocaldir())
  call assert_equal(first_directory, getcwd(win_id2win(first)))
  call assert_equal(first_scope, haslocaldir(win_id2win(first)))
  call assert_equal(root, getcwd(win_id2win(editor)))
  call assert_equal(1, haslocaldir(win_id2win(editor)))
  call assert_equal(tab_directory, getcwd(-1, tabpagenr()))
  call assert_equal(global_directory, getcwd(-1))
  call feedkeys(' e', 'xt')
  call win_gotoid(editor)
  call writefile(['new external file'], project . '/external.txt', 'S')
  call feedkeys(' e', 'xt')
  call assert_true(search('external.txt', 'w') > 0)
  call search('target.txt', 'w')
  call feedkeys("\<CR>", 'xt')
  call assert_equal(project . '/target.txt', expand('%:p'))
  call feedkeys(' e', 'xt')
  only
  call delete(project . '/external.txt')
endfor
''')

    def test_discovery_handles_empty_relative_and_spaced_path_entries(self):
        directory = self.work / 'tools space'
        directory.mkdir()
        for path in [self.work / 'cadaver', directory / 'curl']:
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let saved_path = $PATH
let $PATH = ':tools space:tools space/::missing'
try
  call assert_equal({'cadaver': 1, 'curl': 1},
        \ call(function(tree . 'FindPrograms'), [['cadaver', 'curl', 'fetch']]))
finally
  let $PATH = saved_path
endtry
''')

    def prepare_copy(self, body='sleep 0.3\nexec /bin/cp "$@"\n'):
        (self.work / 'payload.txt').write_text('copied content\n')
        (self.work / 'destination').mkdir()
        tools = self.work / 'tools'
        tools.mkdir()
        cp = tools / 'cp'
        cp.write_text('#!/bin/sh\n' + body)
        cp.chmod(0o755)
        self.env['PATH'] = str(tools) + os.pathsep + self.env['PATH']

    def test_copy_returns_before_io_and_survives_reload_without_stealing_focus(self):
        self.prepare_copy()
        self.vim(WAIT + r'''
call feedkeys(' e', 'xt')
call search('payload.txt', 'w')
call feedkeys('c', 'xt')
call search('destination/', 'w')
let started = reltime()
call feedkeys('p', 'xt')
call assert_true(reltimefloat(reltime(started)) < 0.15, 'copy blocked the editor')
call assert_false(filereadable('destination/payload.txt'))
call feedkeys('p', 'xt')
call assert_match('copy already running:', execute('messages'))
wincmd l
call setline(1, 'editing while the copy runs')
let focus = win_getid()
source ''' + str(ROOT / '.vimrc') + r'''
call WaitForCopy()
call assert_equal(['copied content'], readfile('destination/payload.txt'))
call assert_equal(focus, win_getid())
call assert_equal('editing while the copy runs', getline(1))
call assert_equal(['copied content'], readfile('payload.txt'))
''')

    def test_copy_completion_refreshes_same_tree_after_root_refresh(self):
        self.prepare_copy()
        self.vim(WAIT + r'''
call feedkeys(' e', 'xt')
call assert_true(search('destination/', 'w') > 0)
call feedkeys("\<CR>", 'xt')
let destination = b:netrw_curdir
call assert_true(search('payload.txt', 'w') > 0)
call feedkeys('c', 'xt')
call assert_true(search('destination/', 'w') > 0)
call feedkeys('p', 'xt')
call feedkeys('R', 'xt')
call assert_equal(w:netrw_treetop, b:netrw_curdir)
call WaitForCopy()
" Ex 模式下不抢焦点；模拟回到原树窗口时消费待刷新标记。
doautocmd WinEnter
call assert_equal(['copied content'], readfile('destination/payload.txt'))
call assert_true(index(w:netrw_treedict[destination], 'payload.txt') >= 0)
''')

    def test_copy_can_be_cancelled_and_partial_data_is_retained(self):
        self.prepare_copy('printf partial > "$4"\nsleep 1\n')
        self.vim(WAIT + COPY + r'''
sleep 40m
call assert_equal(['partial'], readfile('destination/payload.txt'))
VimTreeCopyCancel
call WaitForCopy()
call assert_equal(['partial'], readfile('destination/payload.txt'))
call assert_match('copy cancelled; partial target retained:', execute('messages'))
call assert_equal(['copied content'], readfile('payload.txt'))
''')

    def test_copy_failure_and_closed_origin(self):
        self.prepare_copy('sleep 0.1\nexit 7\n')
        self.vim(WAIT + COPY + r'''
call feedkeys(' e', 'xt')
call setline(1, 'still editing')
let focus = win_getid()
call WaitForCopy()
call assert_equal(focus, win_getid())
call assert_equal('still editing', getline(1))
call assert_false(filereadable('destination/payload.txt'))
call assert_match('copy failed (status 7)', execute('messages'))
''')

    def test_copy_does_not_overwrite_target_created_while_job_is_running(self):
        self.prepare_copy()
        self.vim(WAIT + COPY + r'''
call writefile(['created in the meantime'], 'destination/payload.txt', 'S')
call WaitForCopy()
call assert_equal(['created in the meantime'], readfile('destination/payload.txt'))
''')

    def test_copy_continues_after_vim_exits(self):
        self.prepare_copy()
        self.vim(COPY + "call assert_match('copying', execute('VimTreeCopyStatus'))")
        target = self.work / 'destination' / 'payload.txt'
        deadline = time.monotonic() + 3
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual('copied content\n', target.read_text())

    def test_batch_discovery_preserves_priority_user_settings_and_missing_backends(self):
        tools = self.work / 'tools'
        tools.mkdir()
        for name in ('cadaver', 'curl', 'fetch', 'elinks', 'links'):
            path = tools / name
            path.write_text('#!/bin/sh\nexit 0\n')
            path.chmod(0o755)
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let saved_path = $PATH
let $PATH = ''' + quoted(str(tools) + ':' + str(tools) + ':missing-directory') + r'''
call assert_equal({'cadaver': 1, 'curl': 1, 'fetch': 1, 'elinks': 1, 'links': 1},
      \ call(function(tree . 'FindPrograms'), [['cadaver', 'curl', 'fetch', 'elinks', 'links']]))
call call(function(tree . 'LoadNetrw'), [])
call assert_equal('cadaver', g:netrw_dav_cmd)
call assert_equal('fetch -o', g:netrw_fetch_cmd)
call assert_equal('elinks', g:netrw_file_cmd)
let $PATH = saved_path
''')
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let g:netrw_dav_cmd = 'custom-dav'
let g:netrw_fetch_cmd = 'custom-fetch'
let g:netrw_file_cmd = 'custom-file'
call call(function(tree . 'LoadNetrw'), [])
call assert_equal(['custom-dav', 'custom-fetch', 'custom-file'],
      \ [g:netrw_dav_cmd, g:netrw_fetch_cmd, g:netrw_file_cmd])
''')
        self.vim(r'''
let tree = matchstr(maparg(' e', 'n'), '<SNR>\d\+_')
let saved_path = $PATH
let $PATH = '/missing-vim-test-directory'
call call(function(tree . 'LoadNetrw'), [])
call assert_equal('', g:netrw_dav_cmd)
call assert_equal('', g:netrw_fetch_cmd)
call assert_false(exists('g:netrw_file_cmd'))
let $PATH = saved_path
''')
