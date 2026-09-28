"""The fast non-pair check preserves system matchparen behavior and controls."""

from test_vim import ROOT, VimSession


class MatchParenTests(VimSession):
    def test_highlight_matches_system_for_pairs_unicode_and_plain_text(self):
        self.terminal_vim(r'''
let system = matchstr(execute('function /_Highlight_Matching_Pair'), '<SNR>\d\+_Highlight_Matching_Pair')
call assert_false(empty(system))
function! PairMatches() abort
  let matches = filter(getmatches(), 'v:val.group ==# "MatchParen"')
  return map(matches, 'filter(v:val, "v:key !=# ''id''")')
endfunction
edit pairs.cpp
setlocal matchpairs+=<:>,«:»
let other = matchaddpos('Search', [[1, 1]], 17)
for text in ['(nested [pair]) plain', '«中文» <more>', '([{}])',
      \ '("ignored )" /* ] */)', 'é (pair) 😀', 'plain text', '']
  call setline(1, text)
  for character in range(max([1, strchars(text)]))
    call cursor(1, byteidxcomp(text, character) + 1)
    redraw
    call call(function(system), [])
    let expected = PairMatches()
    redraw
    doautocmd matchparen CursorMoved
    call assert_equal(expected, PairMatches(), string([text, col('.')]))
    call assert_equal(1, len(filter(getmatches(), 'v:val.id == other')))
  endfor
endfor
call setline(1, '()')
call cursor(1, 1)
redraw
doautocmd matchparen CursorMoved
call assert_false(empty(PairMatches()))
call setline(1, 'unrelated long text')
call cursor(1, 10)
doautocmd matchparen CursorMoved
call assert_equal([], PairMatches(), 'stale pair highlight')
''')

    def test_controls_reload_and_multiple_windows(self):
        self.terminal_vim(r'''
edit pairs.txt
call setline(1, '()')
call cursor(1, 1)
redraw
NoMatchParen
call assert_false(exists('#matchparen#CursorMoved'))
DoMatchParen
let wrapper = matchstr(execute('autocmd matchparen CursorMoved'), '<SNR>\d\+_Highlight()')
call assert_false(empty(wrapper))
call assert_false(empty(filter(getmatches(), 'v:val.group ==# "MatchParen"')))
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(1, len(filter(split(execute('autocmd matchparen CursorMoved'), "\n"),
      \ 'v:val =~# "_Highlight()"')))
vnew
call setline(1, 'plain text')
doautocmd matchparen CursorMoved
call assert_equal([], filter(getmatches(), 'v:val.group ==# "MatchParen"'))
wincmd p
redraw
doautocmd matchparen CursorMoved
call assert_false(empty(filter(getmatches(), 'v:val.group ==# "MatchParen"')))
''')

    def test_insert_mode_keeps_pair_before_cursor(self):
        self.terminal_vim(r'''
enew
call setline(1, '( )')
call cursor(1, 1)
let g:observed_pair = 0
function! ObservePair(timer) abort
  doautocmd matchparen CursorMovedI
  let matches = filter(getmatches(), 'v:val.group ==# "MatchParen"')
  call assert_false(empty(matches))
  if !empty(matches)
    call assert_equal([1, 1], matches[0].pos1[0:1])
    call assert_equal([1, 3], matches[0].pos2[0:1])
    let g:observed_pair = 1
  endif
  call feedkeys("\<Esc>", 't')
endfunction
call timer_start(20, function('ObservePair'))
call feedkeys('a', 'xt!')
call assert_equal(1, g:observed_pair)
''')
