" 统一自有界面的层次；第三方主题保持原样，真彩色与 256 色使用同一套语义。
function! s:Highlight(group, foreground, background, style) abort
  execute 'highlight ' . a:group . ' guifg=' . a:foreground[0]
        \ . ' guibg=' . a:background[0] . ' ctermfg=' . a:foreground[1]
        \ . ' ctermbg=' . a:background[1] . ' gui=' . a:style
        \ . ' cterm=' . a:style . ' term=' . a:style
endfunction

function! s:Colors() abort
  if get(g:, 'colors_name', '') !=# 'tokyonight-night'
    return
  endif
  let none = ['NONE', 'NONE']
  let panel = ['#16161e', '234']
  let surface = ['#292e42', '236']
  let foreground = ['#c0caf5', '153']
  let muted = ['#737aa2', '103']
  let border = ['#3b4261', '239']
  let blue = ['#7aa2f7', '111']
  let bar_muted = ['#565f89', '60']
  " 顶部与底部保留用户偏好的整条浅白色横栏，当前文件使用蓝色选中块。
  call s:Highlight('TabLineFill', border, foreground, 'NONE')
  call s:Highlight('TabLine', border, foreground, 'NONE')
  call s:Highlight('TabLineSel', panel, blue, 'NONE')
  call s:Highlight('VimLiteSlogan', bar_muted, foreground, 'italic')
  call s:Highlight('StatusLine', surface, foreground, 'NONE')
  call s:Highlight('StatusLineNC', bar_muted, foreground, 'NONE')
  call s:Highlight('StatusLineTerm', surface, foreground, 'NONE')
  call s:Highlight('StatusLineTermNC', bar_muted, foreground, 'NONE')
  call s:Highlight('User1', surface, foreground, 'bold')
  call s:Highlight('User2', ['#3d59a1', '61'], foreground, 'NONE')
  call s:Highlight('VertSplit', border, none, 'NONE')
  call s:Highlight('WinSeparator', border, none, 'NONE')
  call s:Highlight('LineNr', muted, none, 'NONE')
  call s:Highlight('LineNrAbove', muted, none, 'NONE')
  call s:Highlight('LineNrBelow', muted, none, 'NONE')
  " 保留当前行下划线和粉色行号，降低周围装饰的亮度。
  call s:Highlight('CursorLine', none, none, 'underline')
  call s:Highlight('CursorLineNr', ['#ff6bcb', '206'], none, 'bold')
  call s:Highlight('NormalFloat', foreground, panel, 'NONE')
  call s:Highlight('FloatBorder', ['#565f89', '60'], panel, 'NONE')
  call s:Highlight('FloatTitle', blue, panel, 'bold')
  call s:Highlight('Pmenu', foreground, panel, 'NONE')
  call s:Highlight('PmenuSel', foreground, surface, 'NONE')
  call s:Highlight('WildMenu', foreground, surface, 'bold')
  highlight! link VimLiteTitle Title
  highlight! link VimLiteMuted Comment
  highlight! link netrwTreeBar NonText
endfunction

" 只提供外观默认值；定位、关闭和输入处理仍由调用模块负责。
function! VimLitePopupOptions() abort
  let rounded = &encoding ==# 'utf-8' && &ambiwidth ==# 'single'
  return {'border': [1, 1, 1, 1], 'padding': [0, 1, 0, 1],
        \ 'borderchars': rounded ? ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
        \   : ['-', '|', '-', '|', '+', '+', '+', '+'],
        \ 'highlight': 'NormalFloat', 'borderhighlight': ['FloatBorder']}
endfunction

" 面板不继承代码窗口的标尺和光标装饰；标题与操作提示在状态栏左右对齐。
function! VimLitePanel(title, hint) abort
  setlocal nonumber norelativenumber nocursorline nocursorcolumn
  setlocal signcolumn=no foldcolumn=0 nofoldenable nolist nospell colorcolumn=
  let title = substitute(a:title, '%', '%%', 'g')
  let w:vimrc_lite_panel_hint = a:hint
  let width = strdisplaywidth(a:title . a:hint) + 4
  let &l:statusline = ' %<' . title . ' %=%{winwidth(0) < ' . width
        \ . ' ? "" : get(w:, "vimrc_lite_panel_hint", "")} '
endfunction

function! s:Filetype() abort
  if &filetype ==# 'netrw'
    let &l:statusline = ' Files %<%{exists("*VimTreeStatusLabel")'
          \ . ' ? VimTreeStatusLabel() : ""} %= %l/%L '
  elseif &filetype ==# 'qf'
    call VimLitePanel('Results', 'Enter: open  q: close')
    let &l:statusline = ' Results %<%{get(w:, "quickfix_title", "")} %= %l/%L '
    setlocal cursorline
  elseif &filetype ==# 'help'
    call VimLitePanel('Help', 'q: close')
    let &l:statusline = ' Help · %<%t %= q: close '
  endif
endfunction

call s:Colors()
augroup vimrc_lite_ui
  autocmd!
  autocmd ColorScheme * call <SID>Colors()
  autocmd FileType netrw,qf,help call <SID>Filetype()
augroup END
