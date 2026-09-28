"""Automatic word completion stays responsive without changing manual completion."""

from test_vim import VimSession, quoted


class CompletionTests(VimSession):
    def test_unsaved_long_current_line_accepts_complete_candidate_without_changing_prefix(self):
        self.terminal_vim(r'''
enew
let g:long_prefix = repeat('unmatched ', 100000)
call setline(1, [g:long_prefix, 'alpha_tail'])
call cursor(1, 1)
call assert_false(get(b:, 'vimrc_lite_large_file', 0))
let g:accepted = 0
let g:attempts = 0
function! AcceptCurrentLine(timer) abort
  let g:attempts += 1
  if pumvisible()
    let words = map(complete_info(['items']).items, 'v:val.word')
    call assert_equal(['alpha_tail'], words)
    let g:accepted = 1
    call feedkeys("\<C-n>\<C-y>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:attempts > 200
    call assert_report('current-line completion menu missing')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(5, function('AcceptCurrentLine'), {'repeat': -1})
call feedkeys('Aal', 'xt!')
call assert_equal(1, g:accepted)
call assert_equal(sha256(g:long_prefix . 'alpha_tail'), sha256(getline(1)))
call assert_equal('alpha_tail', getline(2))
call assert_true(&modified)
''')

    def test_context_windows_match_native_prefix_at_utf8_boundaries(self):
        self.vim(r'''
let s:prefix = ScriptPrefix('/completion.vim$')
for keywords in ['@,48-57,_,192-255', '@,48-57,_,192-255,-', '48-57,_']
  let &l:iskeyword = keywords
  for offset in range(-4, 4)
    for pad in ['a', '中', 'αλ', 'é', '😀', "\n"]
      let long = repeat(pad, (8192 + offset) / strlen(pad))
      for text in [long . ' alpha-tailX', ' ' . long . 'X', long . '_123X',
            \ 'prefix ' . long . '-tailX']
        call setline(1, text)
        call cursor(1, strlen(text))
        let expected = matchstr(strpart(text, 0, col('.') - 1), '\k\+$')
        let context = Call('Context', [])
        call assert_equal([bufnr('%'), 1, col('.')], context[0:2])
        call assert_equal(sha256(expected), sha256(context[3]), string([keywords, offset, pad]))
        call assert_equal(context, Call('Context', []))
      endfor
    endfor
  endfor
endfor
''')

    def test_context_cache_observes_text_cursor_buffer_keyword_and_encoding_changes(self):
        self.vim(r'''
let s:prefix = ScriptPrefix('/completion.vim$')
setlocal iskeyword+=-
call setline(1, ['foo-barX', 'otherX'])
call cursor(1, 8)
call assert_equal('foo-bar', Call('Context', [])[3])
setlocal iskeyword-=-
call assert_equal('bar', Call('Context', [])[3])
let &undolevels = &undolevels
noautocmd call setline(1, 'newwordX')
call assert_equal('newword', Call('Context', [])[3])
undo
call assert_equal('bar', Call('Context', [])[3])
redo
call assert_equal('newword', Call('Context', [])[3])
call cursor(1, 4)
call assert_equal('new', Call('Context', [])[3])
call cursor(2, 6)
call assert_equal('other', Call('Context', [])[3])
enew
call setline(1, 'other bufferX')
call cursor(1, 13)
call assert_equal([bufnr('%'), 1, 13, 'buffer'], Call('Context', []))
set encoding=latin1
call setline(1, 'before ' . nr2char(233) . 'X')
call cursor(1, strlen(getline(1)))
call assert_equal(matchstr(strpart(getline(1), 0, col('.') - 1), '\k\+$'), Call('Context', [])[3])
set encoding=utf-8
''')

    def test_long_line_windows_preserve_word_boundaries_unicode_and_full_words(self):
        self.vim(r'''
let s:prefix = ScriptPrefix('/completion.vim$')
setlocal iskeyword+=-
for [prefix, pattern, word] in [['al', '\C\<al\k*', 'alpha-tail'],
      \ ['αλ', '\C\<αλ\k*', 'αλφα-λέξη'], ['al', '\c\<al\k*', 'ALPHA'],
      \ ['kλ', '\c\<kλ\k*', 'KΛκελ']]
  for offset in range(-5, 5)
    for pad in ['!', '中', '😀']
      let padding = repeat(pad, (262144 + offset) / strlen(pad))
      let lines = [padding . ' ' . word . "\n" . word . ' ' . padding . ' ' . word,
            \ padding . 'x' . word . ' ' . word,
            \ padding . ' ' . word . repeat('x', 524300) . ' ' . word]
      for text in lines
        let request = {'lines': [text], 'sizes': [strlen(text)], 'row': 0,
              \ 'column': 0, 'wordstart': -1, 'context': [0, 0, 0, prefix], 'pattern': pattern}
        let actual = []
        let iterations = 0
        while request.column < strlen(text) || request.wordstart >= 0
          let item = Call('LongMatch', [request])
          if !empty(item)
            call add(actual, item)
          endif
          let iterations += 1
          if iterations > 20
            call assert_report('long-line scan failed to advance')
            break
          endif
        endwhile
        let expected = []
        let column = 0
        while 1
          let found = matchstrpos(text, pattern, column)
          if found[1] < 0
            break
          endif
          call add(expected, found[0])
          let column = found[2]
        endwhile
        " Report bounded hashes instead of megabytes of candidate text on failure.
        call assert_equal(map(expected, 'sha256(v:val)'), map(actual, 'sha256(v:val)'),
              \ string([prefix, offset, pad]))
      endfor
    endfor
  endfor
endfor
''')

    def test_long_candidate_has_short_label_but_inserts_complete_text(self):
        self.terminal_vim(r'''
enew
let g:long_word = 'alpha_' . repeat('x', 10000)
call setline(1, [g:long_word, ''])
call cursor(2, 1)
let g:polls = 0
let g:accepted = 0
function! AcceptLong(timer) abort
  let g:polls += 1
  if pumvisible()
    let items = complete_info(['items']).items
    call assert_equal(g:long_word, items[0].word)
    call assert_true(strchars(items[0].abbr) <= 81)
    let g:accepted = 1
    call feedkeys("\<C-n>\<C-y>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:polls > 100
    call assert_report('long candidate menu missing')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('AcceptLong'), {'repeat': -1})
call feedkeys('ial', 'xt!')
call assert_equal(1, g:accepted)
call assert_equal(g:long_word, getline(2))
''')

    def test_capped_menu_rescans_new_prefix_to_find_words_at_end_of_large_buffer(self):
        words = self.work / 'words.txt'
        words.write_text(''.join(f'alpha_{index:08d}\n' for index in range(100000)))
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(words) + r''')
enew
let g:stage = 0
let g:polls = 0
function! Drive(timer) abort
  let g:polls += 1
  let words = map(complete_info(['items']).items, 'v:val.word')
  if g:stage == 0 && pumvisible()
    call assert_inrange(1, 100, len(words))
    call assert_equal(-1, complete_info(['selected']).selected)
    let g:stage = 1
    call feedkeys('pha_0009999', 't')
  elseif g:stage == 1 && index(words, 'alpha_00099999') >= 0
    call assert_true(pumvisible())
    call assert_equal('alpha_0009999', getline(1))
    let g:stage = 2
    call feedkeys("\<C-e>", 't')
  elseif g:stage == 2 && !pumvisible()
    let g:stage = 3
  elseif g:stage == 3
    call assert_false(pumvisible(), 'cancelled menu reopened')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
    let g:stage = 4
  elseif g:polls > 400
    call assert_report('completion did not advance to the requested prefix')
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('Drive'), {'repeat': -1})
call feedkeys('ial', 'xt!')
call assert_equal(4, g:stage)
call assert_equal('.,w,b', &complete)
call assert_equal('', maparg("\<C-n>", 'i'))
''')

    def test_unsaved_unicode_words_smartcase_and_custom_keyword_characters(self):
        self.terminal_vim(r'''
enew
setlocal iskeyword+=-
call setline(1, ['AlphaUP alpha-lower αλφα αλβη', ''])
let g:words = []
let g:polls = 0
function! Capture(timer) abort
  let g:polls += 1
  if pumvisible()
    let g:words = map(complete_info(['items']).items, 'v:val.word')
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:polls > 100
    call assert_report('expected word menu')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
for [prefix, wanted, excluded] in [['Al', 'AlphaUP', 'alpha-lower'],
      \ ['alpha-', 'alpha-lower', 'AlphaUP'], ['αλ', 'αλφα', 'AlphaUP']]
  call setline(2, '')
  call cursor(2, 1)
  let g:polls = 0
  call timer_start(10, function('Capture'), {'repeat': -1})
  call feedkeys('i' . prefix, 'xt!')
  call assert_true(index(g:words, wanted) >= 0, string(g:words))
  call assert_equal(-1, index(g:words, excluded))
endfor
''')

    def test_pending_scan_cancels_when_leaving_insert_mode(self):
        source = self.work / 'words.txt'
        source.write_text('unmatched word\n' * 100000)
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(source) + r''')
enew
function! StopInsert(timer) abort
  call feedkeys("\<Esc>", 't')
endfunction
call timer_start(10, function('StopInsert'))
call feedkeys('ial', 'xt!')
let text = getline(1)
sleep 30m
call assert_false(pumvisible())
call assert_equal(text, getline(1))
call assert_equal('n', mode())
''')
