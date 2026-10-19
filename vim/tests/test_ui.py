"""Shared UI appearance, panel navigation and narrow-window behavior."""

from test_vim import ROOT, VimSession


class UiTests(VimSession):
    def test_directory_navigation_restores_editor_chrome(self):
        (self.work / 'first.py').write_text('first\n')
        self.terminal_vim(r'''
let expected = &statusline
edit .
call assert_equal('netrw', &filetype)
call assert_match('Files', &statusline)
call assert_true(search('first.py', 'w') > 0)
call feedkeys("\<CR>", 'xt')
call assert_equal('python', &filetype)
call assert_equal(expected, &statusline)
call assert_true(&number && &relativenumber && &cursorline)
''', args=['-c', 'let g:skip_home = 1'])

    def test_panels_preserve_editor_options_and_keep_selected_file(self):
        (self.work / 'first.py').write_text('first\n')
        (self.work / 'notes.md').write_text('# Notes\n\n## Details\n')
        self.vim(r'''
edit first.py
edit notes.md
let origin = win_getid()
let options = [&number, &relativenumber, &cursorline, &signcolumn, &statusline]
call Call('BufferLine', [])
for command in ['VimKeys buffer', 'VimHealth', 'VimLspInfo']
  execute command
  call assert_false(&number || &relativenumber || &cursorcolumn)
  call assert_equal('no', &signcolumn)
  call assert_match('%#VimrcBufferLineCurrent# 2:notes.md', Call('BufferLine', []))
endfor
source ''' + str(ROOT / '.vimrc') + r'''
call assert_match('%#VimrcBufferLineCurrent# 2:notes.md', Call('BufferLine', []))
for panel in range(3)
  call feedkeys('q', 'xt')
endfor
call assert_equal(origin, win_getid())
call assert_equal(options, [&number, &relativenumber, &cursorline, &signcolumn, &statusline])
call assert_equal(['# Notes', '', '## Details'], getline(1, '$'))
call assert_equal('', v:errmsg)
''')

    def test_narrow_panel_footer_and_literal_status_text(self):
        self.terminal_vim(r'''
leftabove vnew
vertical resize 24
call VimLitePanel('Panel', 'Enter: jump  q: close')
call assert_true(winwidth(0) <= &columns / 3)
redraw!
let row = getwininfo(win_getid())[0].winrow + winheight(0)
let text = join(map(range(1, winwidth(0)), 'screenstring(row, v:val)'), '')
call assert_match('Panel', text)
call assert_notmatch('Enter:', text)
call assert_notmatch('^<', text)
vertical resize 75
redraw!
let text = join(map(range(1, winwidth(0)), 'screenstring(row, v:val)'), '')
call assert_match('Enter: jump  q: close', text)
call VimLitePanel('100% useful', '%{invalid}: literal')
redraw!
let text = join(map(range(1, winwidth(0)), 'screenstring(row, v:val)'), '')
call assert_match('100% useful', text)
call assert_match('%{invalid}: literal', text)
call assert_equal('', v:errmsg)
''', args=['-c', 'let g:skip_home = 1'])

    def test_theme_reload_preserves_transparency_and_256_color_styles(self):
        for transparent in (0, 1):
            for truecolor in (0, 1):
                with self.subTest(transparent=transparent, truecolor=truecolor):
                    self.vim(r'''
highlight CursorLineNr guifg=#000000 ctermfg=0
highlight VertSplit guifg=#ffffff ctermfg=15
colorscheme tokyonight-night
for mode in ['gui', 'cterm']
  let normal = synIDattr(hlID('Normal'), 'bg', mode)
  call assert_equal(g:vimrc_lite_transparent, empty(normal))
  let line = synIDattr(hlID('CursorLine'), 'bg', mode)
  call assert_equal('', line)
  call assert_equal('1', synIDattr(hlID('CursorLine'), 'underline', mode))
  call assert_notequal(synIDattr(hlID('CursorLineNr'), 'fg', mode),
        \ synIDattr(hlID('LineNr'), 'fg', mode))
  call assert_equal(synIDattr(hlID('TabLine'), 'bg', mode),
        \ synIDattr(hlID('StatusLine'), 'bg', mode))
  for group in ['TabLineFill', 'TabLine', 'VimLiteSlogan', 'StatusLine', 'StatusLineNC',
        \ 'StatusLineTerm', 'StatusLineTermNC', 'User1', 'User2']
    call assert_equal(synIDattr(hlID('Normal'), 'fg', mode),
          \ synIDattr(hlID(group), 'bg', mode), group . ' keeps the light bar')
    call assert_equal('', synIDattr(hlID(group), 'reverse', mode))
  endfor
  call assert_notequal(synIDattr(hlID('TabLine'), 'bg', mode),
        \ synIDattr(hlID('NormalFloat'), 'bg', mode))
  call assert_notequal(synIDattr(hlID('Normal'), 'fg', mode),
        \ synIDattr(hlID('VertSplit'), 'fg', mode))
endfor
call assert_equal('#ff6bcb', synIDattr(hlID('CursorLineNr'), 'fg', 'gui'))
call assert_equal('206', synIDattr(hlID('CursorLineNr'), 'fg', 'cterm'))
call assert_equal('', v:errmsg)
''', before=[f'let g:vimrc_lite_transparent = {transparent}',
             f'let g:vimrc_lite_truecolor = {truecolor}'])
