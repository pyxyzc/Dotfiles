"""Current-file search ordinals follow native search and remain display-only."""

import subprocess
import unittest

from test_vim import ROOT, VIM, VimSession


SUPPORTED = subprocess.run(
    [VIM, '-Nu', 'NONE', '-i', 'NONE', '-n', '-es', '-c',
     'if !has("patch-9.0.0121") || !has("textprop") || !exists("*searchcount") | cquit | endif',
     '-c', 'qa!'], capture_output=True,
).returncode == 0

HELPERS = r'''
function! OrdinalProperties() abort
  return prop_list(1, {'types': ['VimrcLiteSearchOrdinal'], 'end_lnum': -1})
endfunction
function! OrdinalText() abort
  return join(map(OrdinalProperties(), 'v:val.text'), '')
endfunction
function! RefreshOrdinal() abort
  doautocmd vimrc_lite_search_ordinal CursorMoved
  sleep 10m
  redraw
endfunction
'''


@unittest.skipUnless(SUPPORTED, 'Search virtual text needs Vim 9.0.0121+ and +textprop')
class SearchOrdinalTests(VimSession):
    def test_native_search_navigation_same_line_and_display_only(self):
        self.terminal_vim(HELPERS + r'''
edit words.txt
let original = ['foo foo', 'unrelated', 'foo', 'foo']
call setline(1, original)
write
call cursor(1, 1)
call feedkeys("/foo\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [2/4]', OrdinalText())
call assert_equal(1, OrdinalProperties()[0].lnum)
let row = screenpos(win_getid(), line('.'), col('.')).row
let screen = join(map(range(1, &columns), 'screenstring(row, v:val)'), '')
call assert_match('\[2/4\]', screen)
call feedkeys('n', 'xt')
call RefreshOrdinal()
call assert_equal(' [3/4]', OrdinalText())
call assert_equal(3, OrdinalProperties()[0].lnum)
call feedkeys('N', 'xt')
call RefreshOrdinal()
call assert_equal(' [2/4]', OrdinalText())
call feedkeys('N', 'xt')
call RefreshOrdinal()
call assert_equal(' [1/4]', OrdinalText())
call feedkeys('N', 'xt')
call RefreshOrdinal()
call assert_equal(' [4/4]', OrdinalText(), 'wrapped reverse search')
call assert_equal(original, getline(1, '$'))
call assert_equal(original, readfile('words.txt'))
call assert_equal(0, &modified)
call cursor(2, 1)
call RefreshOrdinal()
call assert_equal('', OrdinalText(), 'cursor is outside a match')
''')

    def test_unicode_regex_case_word_search_and_search_offsets(self):
        self.terminal_vim(HELPERS + r'''
edit words.txt
call setline(1, ['中文 word 中文', 'WORD word', 'other'])
call cursor(1, 1)
call feedkeys("/中文\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [2/2]', OrdinalText())
call feedkeys("?中文\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [1/2]', OrdinalText())
call cursor(1, 8)
call feedkeys('*', 'xt')
call RefreshOrdinal()
call assert_equal(' [2/3]', OrdinalText())
call feedkeys('#', 'xt')
call RefreshOrdinal()
call assert_equal(' [1/3]', OrdinalText())
call feedkeys("/WORD\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [1/1]', OrdinalText(), 'smartcase')
call feedkeys("/w.rd/e\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [2/3]', OrdinalText(), 'search offset inside match')
call feedkeys('n', 'xt')
call RefreshOrdinal()
call assert_equal(' [3/3]', OrdinalText(), 'next match with end offset')
call cursor(2, 1)
call feedkeys("/word/+1\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal('', OrdinalText(), 'line offset lands outside match')
''')

    def test_hide_highlight_insert_mode_and_search_cancel(self):
        self.terminal_vim(HELPERS + r'''
edit words.txt
call setline(1, ['foo foo', 'bar'])
call cursor(1, 1)
call feedkeys("/foo\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal(' [2/2]', OrdinalText())
call feedkeys("\<Space>fh", 'xt')
sleep 10m
call assert_equal('', OrdinalText(), 'leader fh hides without cursor movement')
call feedkeys('n', 'xt')
call RefreshOrdinal()
call assert_equal(' [1/2]', OrdinalText())
call feedkeys(":nohlsearch\<CR>", 'xt')
sleep 10m
call assert_equal('', OrdinalText(), ':nohlsearch hides without cursor movement')
call feedkeys('n', 'xt')
call RefreshOrdinal()
call assert_equal(' [2/2]', OrdinalText())
call feedkeys("/bar\<Esc>", 'xt')
call RefreshOrdinal()
call assert_equal('foo', @/)
call assert_equal(' [2/2]', OrdinalText(), 'cancel restores previous search')
let g:insert_observed = 0
function! ObserveInsert(timer) abort
  call assert_equal('', OrdinalText(), 'hidden while inserting')
  let g:insert_observed = 1
  call feedkeys("\<Esc>", 't')
endfunction
call timer_start(20, function('ObserveInsert'))
call feedkeys('a', 'xt!')
call assert_equal(1, g:insert_observed)
call RefreshOrdinal()
call assert_equal(' [2/2]', OrdinalText())
''')

    def test_edits_undo_buffer_switch_and_reload_remove_stale_properties(self):
        self.terminal_vim(HELPERS + r'''
edit first.txt
call setline(1, ['foo foo', 'foo'])
call cursor(1, 1)
call feedkeys("/foo\<CR>", 'xt')
call RefreshOrdinal()
let first = bufnr('%')
call assert_equal(' [2/3]', OrdinalText())
call append(0, 'foo')
call cursor(2, 5)
doautocmd vimrc_lite_search_ordinal TextChanged
sleep 10m
call assert_equal(' [3/4]', OrdinalText())
call assert_equal(1, len(OrdinalProperties()), 'old mark moved when a line was inserted')
call assert_equal(2, OrdinalProperties()[0].lnum)
call feedkeys('u', 'xt')
call cursor(1, 1)
call RefreshOrdinal()
call assert_equal(' [1/3]', OrdinalText())
vnew second.txt
call setline(1, 'foo')
call cursor(1, 1)
call RefreshOrdinal()
call assert_equal(' [1/1]', OrdinalText())
call assert_equal([], prop_list(1, {'bufnr': first,
      \ 'types': ['VimrcLiteSearchOrdinal'], 'end_lnum': -1}))
wincmd p
call RefreshOrdinal()
call assert_equal(' [1/3]', OrdinalText())
source ''' + str(ROOT / '.vimrc') + r'''
call RefreshOrdinal()
call assert_equal(' [1/3]', OrdinalText())
call assert_equal(1, len(OrdinalProperties()), 'reload duplicated mark')
let g:vimrc_lite_search_ordinal = 0
call RefreshOrdinal()
call assert_equal('', OrdinalText())
''')

    def test_more_than_default_search_count_limit(self):
        self.terminal_vim(HELPERS + r'''
edit many.txt
call setline(1, repeat(['foo foo'], 1000))
let @/ = 'foo'
call cursor(1000, 5)
call RefreshOrdinal()
call assert_equal(' [2000/2000]', OrdinalText())
call assert_equal(0, get(searchcount({'recompute': 0}), 'incomplete', -1))
''')

    def test_disabled_option_preserves_native_search(self):
        self.terminal_vim(HELPERS + r'''
edit words.txt
call setline(1, 'foo foo')
call cursor(1, 1)
call feedkeys("/foo\<CR>", 'xt')
call RefreshOrdinal()
call assert_equal('', OrdinalText())
call assert_equal(5, col('.'))
call feedkeys('n', 'xt')
call RefreshOrdinal()
call assert_equal(1, col('.'))
''', before=['let g:vimrc_lite_search_ordinal = 0'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
