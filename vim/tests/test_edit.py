"""Whitespace trimming preserves content, undo and change notifications."""

from test_vim import ROOT, VimSession


class TrimTests(VimSession):
    def test_long_lines_keep_non_ascii_whitespace_nul_and_editor_state(self):
        self.vim(r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
edit long.txt
let prefix = '中文' . repeat(' ', 200000) . '🙂'
let original = [prefix . " \t", "\tindent  ", "left\nright\t", '',
      \ 'keep' . nr2char(160), 'keep' . nr2char(0x3000), "keep\r", repeat(' ', 2048)]
let expected = [prefix, "\tindent", "left\nright", '',
      \ 'keep' . nr2char(160), 'keep' . nr2char(0x3000), "keep\r", '']
call setline(1, original)
let &undolevels = &undolevels
let @/ = 'previous search'
let @" = 'previous yank'
let v:searchforward = 0
call cursor(2, 3)
normal! zz
let view = winsaveview()
let jumps = getjumplist()
call call(function(editor . 'TrimWhitespace'), [])
call assert_equal(expected, getline(1, '$'))
call assert_equal(view, winsaveview())
call assert_equal(jumps, getjumplist())
call assert_equal('previous search', @/)
call assert_equal(0, v:searchforward)
call assert_equal('previous yank', @")
undo
call assert_equal(original, getline(1, '$'))
redo
call assert_equal(expected, getline(1, '$'))
''')

    def test_mixed_regions_at_chunk_boundaries_form_one_undo_step(self):
        self.vim(r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
edit mixed.txt
for boundary in [1, 255, 256, 257, 511, 512, 513, 768, 1000]
  let expected = repeat(['short text'], 1000)
  let expected[boundary - 1] = 'left' . repeat(' ', 200000) . 'right'
  let original = map(copy(expected), 'v:val . " \t"')
  call setline(1, original)
  let &undolevels = &undolevels
  call call(function(editor . 'TrimWhitespace'), [])
  call assert_equal(expected, getline(1, '$'), string(boundary))
  undo
  call assert_equal(original, getline(1, '$'), string(boundary) . ': undo')
  redo
  call assert_equal(expected, getline(1, '$'), string(boundary) . ': redo')
endfor
''')

    def test_no_op_and_sparse_changes_do_not_rewrite_clean_lines(self):
        self.vim(r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
edit sparse.txt
call setline(1, repeat(['clean'], 1000))
call setline(500, 'left' . repeat(' ', 200000) . 'right')
let &undolevels = &undolevels
setlocal nomodified
let tick = b:changedtick
let undo_state = undotree()
call call(function(editor . 'TrimWhitespace'), [])
call assert_equal(tick, b:changedtick)
call assert_false(&modified)
call assert_equal(undo_state, undotree())
call setline(510, 'dirty  ')
let &undolevels = &undolevels
if exists('*listener_add')
  function! Changes(buf, start, end, added, changes) abort
    call extend(g:changes, a:changes)
  endfunction
  call listener_flush()
  let g:changes = []
  let listener = listener_add(function('Changes'))
endif
call call(function(editor . 'TrimWhitespace'), [])
call assert_equal('dirty', getline(510))
if exists('*listener_add')
  call listener_flush()
  call assert_equal([510], map(copy(g:changes), 'v:val.lnum'))
  call listener_remove(listener)
endif
undo
call assert_equal('dirty  ', getline(510))
setlocal readonly
call call(function(editor . 'TrimWhitespace'), [])
call assert_equal('dirty  ', getline(510))
call assert_match('not an editable file', execute('messages'))
''')

    def test_missing_native_trim_keeps_legacy_fallback(self):
        config = self.work / 'fallback.vim'
        source = (ROOT / 'edit.vim').read_text()
        variants = {
            'absent': source.replace("if exists('*trim')", 'if 0'),
            'without_direction':
                'function! LegacyTrim(text, mask) abort\nreturn a:text\nendfunction\n'
                + source.replace("trim(' x ',", "LegacyTrim(' x ',"),
        }
        for name, variant in variants.items():
            with self.subTest(capability=name):
                config.write_text('set nocompatible noloadplugins\n' + variant)
                self.vim(r'''
let editor = matchstr(maparg('gc', 'n'), '<SNR>\d\+_')
let original = ['left' . repeat(' ', 5000) . "right \t", 'short  ']
call setline(1, original)
let &undolevels = &undolevels
call call(function(editor . 'TrimWhitespace'), [])
call assert_equal(['left' . repeat(' ', 5000) . 'right', 'short'], getline(1, '$'))
undo
call assert_equal(original, getline(1, '$'))
''', config=config)
