" Markdown：原生阅读视图、结构导航和异步离线浏览器预览。
if exists('#vimrc_lite_markdown#User#VimrcLiteReload')
  doautocmd <nomodeline> vimrc_lite_markdown User VimrcLiteReload
endif
let s:directory = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/markdown'
let s:preview = {}
let s:outline = {}
let s:timer = -1
let s:fenced_languages = get(g:, 'vimrc_lite_markdown_fenced_languages',
      \ empty(get(g:, 'markdown_fenced_languages', []))
      \ ? ['python', 'c', 'cpp', 'c++=cpp', 'bash=sh', 'sh', 'json', 'vim']
      \ : g:markdown_fenced_languages)

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Markdown: ' . a:message
  echohl None
endfunction

function! s:Markdown() abort
  return &filetype ==# 'markdown' && &buftype ==# ''
endfunction

function! s:Editable() abort
  return s:Markdown() && &modifiable && !&readonly
endfunction

function! s:Colors() abort
  let colors = ['#7aa2f7', '#bb9af7', '#7dcfff', '#9ece6a', '#e0af68', '#ff9e64']
  let terminals = [111, 183, 117, 149, 179, 215]
  for index in range(6)
    execute 'highlight markdownH' . (index + 1) . ' gui=bold cterm=bold guifg='
          \ . colors[index] . ' guibg=#24283b ctermfg=' . terminals[index] . ' ctermbg=235'
    execute 'highlight! link VimMarkdownH' . (index + 1) . ' markdownH' . (index + 1)
  endfor
  highlight markdownCodeBlock guifg=#c0caf5 guibg=#16161e ctermfg=153 ctermbg=234
  highlight markdownCode guifg=#9ece6a guibg=#16161e ctermfg=149 ctermbg=234
  highlight markdownCodeDelimiter guifg=#bb9af7 ctermfg=183
  highlight markdownBlockquote guifg=#7dcfff ctermfg=117
  highlight VimMarkdownBullet guifg=#7aa2f7 ctermfg=111
  highlight VimMarkdownTodo guifg=#e0af68 ctermfg=179
  highlight VimMarkdownDone guifg=#9ece6a ctermfg=149
  highlight VimMarkdownCallout gui=bold cterm=bold guifg=#7dcfff ctermfg=117
  highlight VimMarkdownTable guifg=#565f89 ctermfg=60
  highlight VimMarkdownHeadingMark guifg=#bb9af7 ctermfg=183
  for language in s:fenced_languages
    let name = matchstr(language, '[^=]*$')
    if name =~# '^\w\+$'
      execute 'highlight! link markdownHighlight_' . name . ' markdownCodeBlock'
      execute 'highlight! link markdownHighlight' . name . ' markdownCodeBlock'
      execute 'highlight! link VimMarkdownCode_' . name . ' markdownCodeBlock'
    endif
  endfor
endfunction

" 围栏语法限定在普通 Markdown 文件，不向 LSP 文档窗口传播语言配置。
function! s:Fences() abort
  if get(b:, 'vimrc_lite_markdown_fences', 0)
    return
  endif
  let included = {}
  let previous_syntax = get(b:, 'current_syntax', 'markdown')
  let previous_error = v:errmsg
  let previous_options = {'foldmethod': &l:foldmethod, 'foldtext': &l:foldtext,
        \ 'iskeyword': &l:iskeyword}
  try
    for language in s:fenced_languages
      let name = matchstr(language, '[^=]*$')
      let marker = matchstr(language, '^[^=]*')
      if name !~# '^\w\+$' || marker !~# '^[A-Za-z0-9_+-]\+$'
        continue
      endif
      if !has_key(included, name)
        unlet! b:current_syntax
        execute 'syntax include @VimMarkdownFence_' . name . ' syntax/' . name . '.vim'
        let included[name] = 1
      endif
      let group = 'VimMarkdownCode_' . name
      for char in ['`', '\~']
        execute 'syntax region ' . group . ' matchgroup=markdownCodeDelimiter start=/^ \{0,3}\z('
              \ . char . '\{3,}\)\s*' . escape(marker, '\.^$~[]*') . '\S\@!.*$/ end=/^ \{0,3}'
              \ . '\z1' . char . '*\s*$/ keepend contains=@VimMarkdownFence_' . name
      endfor
      execute 'highlight! link ' . group . ' markdownCodeBlock'
    endfor
    let b:vimrc_lite_markdown_fences = 1
  finally
    let b:current_syntax = previous_syntax
    for [option, value] in items(previous_options)
      execute 'let &l:' . option . ' = value'
    endfor
    " 系统 sh.vim 使用 silent! 删除临时命令；忽略其已处理的缺失命令提示。
    if v:errmsg =~# '^E184: No such user-defined command: ShFold'
      let v:errmsg = previous_error
    endif
  endtry
endfunction

function! s:Syntax() abort
  if !s:Markdown() || get(b:, 'vimrc_lite_large_file', 0)
    return
  endif
  call s:Fences()
  for level in range(1, 6)
    execute 'silent! syntax clear VimMarkdownH' . level
    execute 'syntax match VimMarkdownH' . level . ' /^ \{0,3}#\{' . level
          \ . '}\%(\s.*\|$\)/ contained contains=@markdownInline,VimMarkdownHeadingMark'
    execute 'syntax cluster markdownBlock add=VimMarkdownH' . level
  endfor
  silent! syntax clear VimMarkdownHeadingMark VimMarkdownBullet VimMarkdownTodo VimMarkdownDone
  silent! syntax clear VimMarkdownCallout VimMarkdownTable
  syntax match VimMarkdownHeadingMark /^ \{0,3}#\{1,6}/ contained conceal cchar=▎
  syntax match VimMarkdownBullet /^\s*[-+*]\ze\s\+\S/ contained conceal cchar=•
  syntax cluster markdownBlock add=VimMarkdownBullet
  syntax match VimMarkdownTodo /\[ \]/ containedin=markdownLineStart conceal cchar=□
  syntax match VimMarkdownDone /\[[xX]\]/ containedin=markdownLineStart conceal cchar=✓
  syntax match VimMarkdownCallout /\[!\%(NOTE\|TIP\|IMPORTANT\|WARNING\|CAUTION\)\]/
        \ containedin=markdownLineStart,markdownBlockquote
  syntax match VimMarkdownTable /\(^\s*\)\@<=|\|\s\zs|\ze\s\|:\=-\{3,}:\=/
        \ containedin=markdownLineStart
endfunction

function! s:Attach() abort
  if !s:Markdown() || get(b:, 'vimrc_lite_large_file', 0)
    return
  endif
  if !get(b:, 'vimrc_lite_markdown', 0)
    let b:vimrc_lite_markdown = 1
    setlocal expandtab shiftwidth=2 softtabstop=2 autoindent indentexpr=
    setlocal formatoptions-=t formatoptions-=c formatoptions-=r formatoptions-=o
    setlocal textwidth=0 foldmethod=manual
    nnoremap <silent><buffer> <leader>mp :VimMarkdownPreview<CR>
    nnoremap <silent><buffer> <leader>ms :VimMarkdownStop<CR>
    nnoremap <silent><buffer> <leader>mo :VimMarkdownOutline<CR>
    nnoremap <silent><buffer> <leader>mr :VimMarkdownRender<CR>
    nnoremap <silent><buffer> <leader>mf :VimMarkdownFocus<CR>
    nnoremap <silent><buffer> <leader>mx :VimMarkdownTask<CR>
    xnoremap <silent><buffer> <leader>mx :VimMarkdownTask<CR>
    nnoremap <silent><buffer> <leader>mt :VimMarkdownTable<CR>
    nnoremap <silent><buffer> <leader>ml :VimMarkdownLink<CR>
    nnoremap <silent><buffer> <leader>mh :VimMarkdownHelp<CR>
    nnoremap <silent><buffer> <leader>mi :VimMarkdownInsert<CR>
    xnoremap <silent><buffer> <leader>mb :VimMarkdownWrap bold<CR>
    xnoremap <silent><buffer> <leader>mi :VimMarkdownWrap italic<CR>
    xnoremap <silent><buffer> <leader>mc :VimMarkdownWrap code<CR>
    nnoremap <silent><buffer> ]h :<C-u>call <SID>Heading(1, v:count1)<CR>
    nnoremap <silent><buffer> [h :<C-u>call <SID>Heading(-1, v:count1)<CR>
    nnoremap <silent><buffer> j gj
    nnoremap <silent><buffer> k gk
    inoremap <silent><expr><buffer> <CR> <SID>Enter()
    let b:undo_ftplugin = get(b:, 'undo_ftplugin', '')
          \ . '|call ' . expand('<SID>') . 'Detach()'
  endif
  setlocal wrap linebreak breakindent
  if has('conceal')
    let b:vimrc_lite_markdown_raw = get(b:, 'vimrc_lite_markdown_raw',
          \ get(w:, 'vimrc_lite_markdown_raw', !get(g:, 'vimrc_lite_markdown_render', 1)))
    unlet! w:vimrc_lite_markdown_raw
    let &l:conceallevel = b:vimrc_lite_markdown_raw ? 0 : 2
    setlocal concealcursor=
  endif
  call s:Syntax()
  if exists('*VimMarkdownViewRefresh')
    call VimMarkdownViewRefresh()
  endif
  if exists('*VimMarkdownNotesAttach')
    call VimMarkdownNotesAttach()
  endif
  if exists('*VimMarkdownSnippetsAttach')
    call VimMarkdownSnippetsAttach()
  endif
  if exists('*VimMarkdownImagesAttach')
    call VimMarkdownImagesAttach()
  endif
endfunction

function! s:Detach() abort
  if exists('*VimMarkdownViewClear')
    call VimMarkdownViewClear(bufnr('%'))
  endif
  call s:FocusRestore()
  if exists('*VimMarkdownNotesStop')
    call VimMarkdownNotesStop(bufnr('%'))
  endif
  if exists('*VimMarkdownImagesStop')
    call VimMarkdownImagesStop(bufnr('%'))
  endif
  for key in ['mp', 'ms', 'mo', 'mr', 'mf', 'mx', 'mt', 'ml', 'mh', 'mi',
        \ 'mc', 'mu', 'mz', 'mZ', 'ma', 'mv', 'mV']
    execute 'silent! nunmap <buffer> <leader>' . key
  endfor
  for key in ['mx', 'mb', 'mi', 'mc']
    execute 'silent! xunmap <buffer> <leader>' . key
  endfor
  for key in ['j', 'k', ']h', '[h']
    execute 'silent! nunmap <buffer> ' . key
  endfor
  silent! iunmap <buffer> <CR>
  for key in ['<Tab>', '<S-Tab>', '<Plug>(vim-lite-markdown-tab)',
        \ '<Plug>(vim-lite-markdown-backtab)', '<Plug>(vim-lite-markdown-expand)']
    execute 'silent! iunmap <buffer> ' . key
    execute 'silent! sunmap <buffer> ' . key
  endfor
  setlocal wrap< linebreak< breakindent< conceallevel< concealcursor<
  setlocal autoindent< indentexpr< textwidth< foldmethod< foldexpr< foldtext<
  unlet! b:vimrc_lite_markdown b:vimrc_lite_markdown_headers b:vimrc_lite_markdown_fences
endfunction

function! s:Render() abort
  if s:Markdown() && has('conceal')
    let b:vimrc_lite_markdown_raw = !get(b:, 'vimrc_lite_markdown_raw', &l:conceallevel == 0)
    for window in getwininfo()
      if window.bufnr == bufnr('%')
        call setwinvar(window.winid, '&conceallevel', b:vimrc_lite_markdown_raw ? 0 : 2)
      endif
    endfor
    if exists('*VimMarkdownViewRefresh')
      call VimMarkdownViewRefresh()
    endif
    redraw!
    echo 'Markdown: ' . (b:vimrc_lite_markdown_raw ? 'source' : 'reading view')
  endif
endfunction

function! VimMarkdownStatusLabel() abort
  return s:Markdown() && !get(b:, 'vimrc_lite_large_file', 0)
        \ ? (get(b:, 'vimrc_lite_markdown_raw', 0) ? ' [MD:source]' : ' [MD:read]')
        \ . (exists('*VimMarkdownBreadcrumb') ? VimMarkdownBreadcrumb() : '') : ''
endfunction

function! s:FocusRestore() abort
  if exists('w:vimrc_lite_markdown_focus')
    for [option, value] in items(w:vimrc_lite_markdown_focus)
      execute 'let &l:' . option . ' = value'
    endfor
    unlet w:vimrc_lite_markdown_focus
  endif
endfunction

function! s:Focus() abort
  if !s:Markdown()
    return
  endif
  if exists('w:vimrc_lite_markdown_focus')
    call s:FocusRestore()
  else
    let w:vimrc_lite_markdown_focus = {}
    for option in ['number', 'relativenumber', 'signcolumn', 'colorcolumn', 'cursorline']
      let w:vimrc_lite_markdown_focus[option] = eval('&l:' . option)
    endfor
    setlocal nonumber norelativenumber signcolumn=no colorcolumn= nocursorline
  endif
endfunction

" changedtick 缓存用于结构操作；导航、目录和代码保护共用围栏／front matter 范围。
function! s:Headers(buf) abort
  let tick = getbufvar(a:buf, 'changedtick')
  let cached = getbufvar(a:buf, 'vimrc_lite_markdown_headers', {})
  if get(cached, 'tick', -1) == tick && has_key(cached, 'comments')
    return cached.rows
  endif
  let rows = []
  let code = []
  let comments = []
  let lines = getbufline(a:buf, 1, '$')
  let fence = ''
  let fence_length = 0
  let fence_start = 0
  let comment = 0
  let comment_start = 0
  let yaml = !empty(lines) && lines[0] ==# '---'
  if yaml && empty(filter(copy(lines[1:]), 'v:val =~# "^\\%(---\\|\\.\\.\\.\\)\\s*$"'))
    let yaml = 0
  endif
  for index in range(len(lines))
    let text = lines[index]
    if yaml
      if index > 0 && text =~# '^\%(---\|\.\.\.\)\s*$'
        let yaml = 0
        call add(code, [1, index + 1])
      endif
      continue
    endif
    if empty(fence)
      if comment
        let comment = text !~# '-->'
        if !comment
          call add(comments, [comment_start, index + 1])
        endif
        continue
      elseif text =~# '^ \{0,3}<!--'
        let comment = text !~# '-->'
        let comment_start = index + 1
        if !comment
          call add(comments, [comment_start, index + 1])
        endif
        continue
      endif
    endif
    let marker = matchstr(text, '^ \{0,3}\zs\%(`\{3,}\|\~\{3,}\)')
    if !empty(fence)
      if !empty(marker) && marker[0] ==# fence && strlen(marker) >= fence_length
            \ && text =~# '^ \{0,3}' . escape(marker, '~') . '\s*$'
        let fence = ''
        call add(code, [fence_start, index + 1])
      endif
      continue
    elseif !empty(marker)
      let fence = marker[0]
      let fence_length = strlen(marker)
      let fence_start = index + 1
      continue
    endif
    let heading = matchlist(text, '^ \{0,3}\(#\{1,6}\)\%(\s\+\(.*\)\|$\)')
    if !empty(heading)
      call add(rows, {'line': index + 1, 'level': strlen(heading[1]),
            \ 'text': substitute(heading[2], '\s\+#*\s*$', '', '')})
    elseif index > 0 && text =~# '^ \{0,3}\%([=]\+\|[-]\+\)\s*$'
          \ && lines[index - 1] =~# '^ \{0,3}\S'
          \ && lines[index - 1] !~# '^ \{0,3}\%([#>`~*-]\|\d\+[.)]\s\)'
      call add(rows, {'line': index, 'level': text =~# '=' ? 1 : 2,
            \ 'text': substitute(lines[index - 1], '^\s*\|\s*$', '', 'g')})
    endif
  endfor
  if !empty(fence)
    call add(code, [fence_start, len(lines)])
  endif
  if comment
    call add(comments, [comment_start, len(lines)])
  endif
  let slugs = {}
  for row in rows
    let plain = substitute(row.text, '!\?\[\([^]]*\)\]([^)]*)', '\1', 'g')
    let slug = substitute(tolower(plain), '\%(\k\|[ -]\)\@!.', '', 'g')
    let slug = substitute(slug, ' ', '-', 'g')
    let slug = empty(slug) ? 'section' : slug
    let suffix = get(slugs, slug, 0)
    let slugs[slug] = suffix + 1
    let row.slug = slug . (suffix ? '-' . suffix : '')
  endfor
  call setbufvar(a:buf, 'vimrc_lite_markdown_headers',
        \ {'tick': tick, 'rows': rows, 'code': code, 'comments': comments})
  return rows
endfunction

function! VimMarkdownStructure(buf) abort
  call s:Headers(a:buf)
  return getbufvar(a:buf, 'vimrc_lite_markdown_headers', {'rows': [], 'code': []})
endfunction

function! VimMarkdownCells(text) abort
  return s:Cells(a:text)
endfunction

function! s:Heading(direction, count) abort
  if !s:Markdown()
    return
  endif
  let rows = copy(s:Headers(bufnr('%')))
  call filter(rows, a:direction > 0 ? 'v:val.line > line(".")' : 'v:val.line < line(".")')
  if a:direction < 0
    call reverse(rows)
  endif
  if !empty(rows)
    normal! m'
    call cursor(rows[min([a:count, len(rows)]) - 1].line, 1)
    normal! zvzz
  endif
endfunction

function! s:OutlineRefresh() abort
  if empty(s:outline) || !bufexists(s:outline.source) || !bufexists(s:outline.buf)
    return
  endif
  let tick = getbufvar(s:outline.source, 'changedtick')
  if get(s:outline, 'tick', -1) == tick
    return
  endif
  let rows = s:Headers(s:outline.source)
  let lines = ['  DOCUMENT OUTLINE', '  Enter: jump   q: close', '']
  for row in rows
    call add(lines, repeat('  ', row.level) . row.text . '  · ' . row.line)
  endfor
  if empty(rows)
    call add(lines, '  No headings yet')
  endif
  call setbufvar(s:outline.buf, '&modifiable', 1)
  call setbufline(s:outline.buf, 1, lines)
  if len(getbufline(s:outline.buf, 1, '$')) > len(lines)
    call deletebufline(s:outline.buf, len(lines) + 1, '$')
  endif
  call setbufvar(s:outline.buf, '&modifiable', 0)
  let s:outline.rows = rows
  let s:outline.tick = tick
endfunction

function! s:OutlineJump() abort
  let index = line('.') - 4
  if empty(s:outline) || index < 0 || index >= len(s:outline.rows)
    return
  endif
  let target = s:outline.rows[index].line
  if !win_gotoid(s:outline.sourcewin)
    let windows = win_findbuf(s:outline.source)
    if empty(windows)
      rightbelow vnew
    else
      call win_gotoid(windows[0])
    endif
  endif
  if bufnr('%') != s:outline.source
    execute 'buffer ' . s:outline.source
  endif
  normal! m'
  call cursor(target, 1)
  normal! zvzz
endfunction

function! s:Outline() abort
  if !s:Markdown()
    return
  endif
  let source = bufnr('%')
  let sourcewin = win_getid()
  if !empty(s:outline) && win_gotoid(s:outline.win)
    if s:outline.source != source
      let s:outline.tick = -1
    endif
    let s:outline.source = source
    let s:outline.sourcewin = sourcewin
  else
    topleft 32vnew
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
    setlocal nonumber norelativenumber nowrap signcolumn=no
    let s:outline = {'source': source, 'sourcewin': sourcewin,
          \ 'buf': bufnr('%'), 'win': win_getid()}
    nnoremap <silent><buffer> <CR> :call <SID>OutlineJump()<CR>
    nnoremap <silent><buffer> q :close<CR>
    syntax match VimMarkdownCallout /^  DOCUMENT OUTLINE$/
    syntax match Comment /^  Enter:.*/
    syntax match LineNr /· \d\+$/
    let &l:statusline = ' Markdown · Outline '
  endif
  call s:OutlineRefresh()
  call cursor(4, 1)
endfunction

function! s:Code(lnum) abort
  " 使用当前文本的围栏范围，避免编辑后尚未重绘的语法缓存误判代码保护。
  call s:Headers(bufnr('%'))
  for region in b:vimrc_lite_markdown_headers.code + b:vimrc_lite_markdown_headers.comments
    if region[0] <= a:lnum && a:lnum <= region[1]
      return 1
    endif
  endfor
  if getline(a:lnum) !~# '^\%( \{4}\|\t\)'
    return 0
  endif
  let column = max([1, match(getline(a:lnum), '\S') + 1])
  for id in synstack(a:lnum, column)
    if synIDattr(id, 'name') =~? 'code\|highlight\|yaml\|fence'
      return 1
    endif
  endfor
  return 0
endfunction

function! VimMarkdownInCode(lnum) abort
  return s:Code(a:lnum)
endfunction

function! s:Enter() abort
  if pumvisible()
    return exists('*complete_info') && complete_info(['selected']).selected < 0
          \ ? "\<C-e>\<CR>" : "\<C-y>"
  endif
  if !get(g:, 'vimrc_lite_markdown_lists', 1) || &paste
    return "\<CR>"
  endif
  let text = strpart(getline('.'), 0, col('.') - 1)
  if text !~# '^\s*\%([-+*]\|\d\+[.)]\|>\)' || s:Code(line('.'))
    return "\<CR>"
  endif
  let list = matchlist(text, '^\(\s*\%([>]\s*\)*\)\([-+*]\|\d\+[.)]\)\s\+'
        \ . '\(\[[ xX]\]\s\+\)\?\(.*\)$')
  if !empty(list)
    if empty(list[4]) && col('.') > strlen(getline('.'))
      return "\<C-u>\<CR>"
    endif
    let marker = list[2]
    if marker =~# '^\d'
      let marker = (str2nr(marker) + 1) . marker[-1:]
    endif
    return "\<CR>" . (indent('.') > 0 ? "\<C-u>" : '')
          \ . list[1] . marker . ' ' . (empty(list[3]) ? '' : '[ ] ')
  endif
  let quote = matchstr(text, '^\s*\%([>]\s*\)\+')
  if !empty(quote)
    return text ==# quote ? "\<C-u>\<CR>"
          \ : "\<CR>" . (indent('.') > 0 ? "\<C-u>" : '') . quote
  endif
  return "\<CR>"
endfunction

function! s:Task(first, last) abort
  if !s:Editable()
    return
  endif
  let changes = []
  for lnum in range(a:first, a:last)
    let text = getline(lnum)
    if s:Code(lnum) || text !~# '^\s*\%([>]\s*\)*\%([-+*]\|\d\+[.)]\)\s\+'
      continue
    endif
    let pattern = '^\s*\%([>]\s*\)*\%([-+*]\|\d\+[.)]\)\s\+\zs'
    if text =~# pattern . '\[[ xX!\-]\]'
      let text = substitute(text, pattern . '\[\zs[ xX!\-]\ze\]',
            \ text =~# pattern . '\[[xX]\]' ? ' ' : 'x', '')
    else
      let text = substitute(text, pattern, '[ ] ', '')
    endif
    call add(changes, [lnum, text])
  endfor
  let joined = 0
  for [lnum, text] in changes
    if joined
      undojoin
    endif
    call setline(lnum, text)
    let joined = 1
  endfor
endfunction

" 支持转义竖线及代码 span 中的竖线；对齐按显示宽度计算，兼容中文。
function! s:Cells(text) abort
  let cells = ['']
  let ticks = 0
  let escaped = 0
  let chars = split(substitute(a:text, '^\s*|\|[|]\s*$', '', 'g'), '\zs')
  let index = 0
  while index < len(chars)
    let char = chars[index]
    if char ==# '`' && !escaped
      let run = 1
      while index + run < len(chars) && chars[index + run] ==# '`'
        let run += 1
      endwhile
      let cells[-1] .= repeat('`', run)
      let ticks = ticks == run ? 0 : ticks == 0 ? run : ticks
      let index += run
      continue
    elseif char ==# '|' && ticks == 0 && !escaped
      call add(cells, '')
    else
      let cells[-1] .= char
    endif
    let escaped = char ==# '\' && !escaped
    let index += 1
  endwhile
  return map(cells, 'substitute(v:val, "^\\s*\\|\\s*$", "", "g")')
endfunction

function! s:Insert(arguments) abort
  if !s:Editable()
    return
  endif
  let kinds = ['code', 'table', 'link', 'image', 'note', 'math']
  let args = split(a:arguments)
  if empty(args)
    let choice = inputlist(['插入 Markdown 模板：', '1. 代码块', '2. 表格',
          \ '3. 链接', '4. 图片', '5. 提示块', '6. 数学公式'])
    if choice < 1 || choice > len(kinds)
      return
    endif
    let args = [kinds[choice - 1]]
  endif
  let templates = {'code': ['```' . get(args, 1, ''), '', '```'],
        \ 'table': ['| 标题 ' . '|' . ' 内容 |', '| --- ' . '|' . ' --- |',
        \ '|     ' . '|' . '     |'],
        \ 'link': ['[描述](path)'], 'image': ['![描述](image.png)'],
        \ 'note': ['> [!NOTE]', '> '], 'math': ['$$', '', '$$']}
  if !has_key(templates, args[0])
    call s:Warn('template: ' . join(kinds, ', '))
    return
  endif
  let first = line('.') + (getline('.') ==# '' ? 0 : 1)
  if getline('.') ==# ''
    call setline(first, templates[args[0]][0])
    if len(templates[args[0]]) > 1
      undojoin
      call append(first, templates[args[0]][1:])
    endif
  else
    call append(line('.'), templates[args[0]])
  endif
  call cursor(first + (index(['code', 'math', 'note'], args[0]) >= 0 ? 1 : 0), 1)
endfunction

function! s:InsertComplete(lead, line, position) abort
  return filter(['code', 'table', 'link', 'image', 'note', 'math'],
        \ 'stridx(v:val, a:lead) == 0')
endfunction

function! s:Table() abort
  if !s:Editable() || s:Code(line('.')) || getline('.') !~# '|'
    return
  endif
  let first = line('.')
  let last = first
  while first > 1 && getline(first - 1) =~# '|' && !s:Code(first - 1)
    let first -= 1
  endwhile
  while last < line('$') && getline(last + 1) =~# '|' && !s:Code(last + 1)
    let last += 1
  endwhile
  let rows = map(getline(first, last), 's:Cells(v:val)')
  if len(rows) < 2 || empty(rows[1])
        \ || !empty(filter(copy(rows[1]), 'v:val !~# "^:\\=-\\{3,}:\\=$"'))
    call s:Warn('table needs a header and a separator such as |---|---|')
    return
  endif
  let columns = len(rows[0])
  if !empty(filter(copy(rows), 'len(v:val) != columns'))
    call s:Warn('table rows must have the same number of cells')
    return
  endif
  let widths = repeat([3], columns)
  for row in rows
    for index in range(columns)
      let widths[index] = max([widths[index], strdisplaywidth(row[index])])
    endfor
  endfor
  let output = []
  for number in range(len(rows))
    let cells = []
    for index in range(columns)
      let cell = rows[number][index]
      if number == 1
        let left = cell[0] ==# ':' ? ':' : ''
        let right = cell[-1:] ==# ':' ? ':' : ''
        let cell = left . repeat('-', max([3, widths[index] - len(left) - len(right)])) . right
      else
        let cell .= repeat(' ', widths[index] - strdisplaywidth(cell))
      endif
      call add(cells, cell)
    endfor
    call add(output, '| ' . join(cells, ' ' . '|' . ' ') . ' |')
  endfor
  let view = winsaveview()
  if output !=# getline(first, last)
    call setline(first, output)
  endif
  call winrestview(view)
endfunction

function! s:Wrap(kind, first, last) abort
  if !s:Editable() || index(['bold', 'italic', 'code'], a:kind) < 0
    return
  endif
  let marks = {'bold': '**', 'italic': '*', 'code': '`'}
  let marker = marks[a:kind]
  let lines = getline(a:first, a:last)
  let start = getpos("'<")
  let stop = getpos("'>")
  let left = start[1] == a:first && visualmode() !=# 'V' ? start[2] - 1 : 0
  let right = stop[1] == a:last && visualmode() !=# 'V'
        \ ? stop[2] - 1 + strlen(matchstr(strpart(lines[-1], stop[2] - 1), '^.'))
        \ : strlen(lines[-1])
  let lines[-1] = strpart(lines[-1], 0, right) . marker . strpart(lines[-1], right)
  let lines[0] = strpart(lines[0], 0, left) . marker . strpart(lines[0], left)
  call setline(a:first, lines)
endfunction

function! s:Link() abort
  if !s:Markdown()
    return
  endif
  let text = getline('.')
  let offset = 0
  let destination = ''
  while offset < strlen(text)
    let match = matchstrpos(text, '!\?\[[^]]*\](\([^)]*\))', offset)
    if match[1] < 0
      break
    endif
    if col('.') - 1 >= match[1] && col('.') - 1 < match[2]
      let destination = matchstr(match[0], '](\zs.*\ze)')
      let destination = substitute(destination, '\s\+["''].\+$', '', '')
      break
    endif
    let offset = match[2]
  endwhile
  if empty(destination)
    call s:Warn('put the cursor on a Markdown link')
  elseif destination[0] ==# '#'
    let anchor = s:Decode(destination[1:])
    for row in s:Headers(bufnr('%'))
      if row.slug ==# anchor
        normal! m'
        call cursor(row.line, 1)
        normal! zvzz
        return
      endif
    endfor
    call s:Warn('heading anchor not found: ' . anchor)
  elseif destination =~# '^https\?://'
    call s:OpenBrowser(destination)
  elseif destination =~# '^\a\+:'
    call s:Warn('unsupported link scheme')
  else
    let path = substitute(destination, '#.*$', '', '')
    let path = s:Decode(path)
    let path = fnamemodify(expand('%:p:h') . '/' . path, ':p')
    if filereadable(path)
      execute 'edit ' . fnameescape(path)
    else
      call s:Warn('file not found: ' . path)
    endif
  endif
endfunction

" 按字节解码后保留原始 UTF-8；只将正则匹配出的十六进制送入字符串字面量。
function! s:Decode(text) abort
  return substitute(a:text, '%\(\x\x\)', '\=eval(''"\x'' . submatch(1) . ''"'')', 'g')
endfunction

function! s:OpenBrowser(url) abort
  let configured = get(g:, 'vimrc_lite_markdown_browser', [])
  if type(configured) == type([]) && !empty(configured)
    call job_start(configured + [a:url], {'stoponexit': ''})
  elseif empty($SSH_CONNECTION) && empty($SSH_TTY) && executable('xdg-open')
        \ && (!empty($DISPLAY) || !empty($WAYLAND_DISPLAY))
    call job_start(['xdg-open', a:url], {'stoponexit': ''})
  endif
  echom 'Markdown: ' . a:url
endfunction

function! s:PreviewOutput(channel, message) abort
  if empty(s:preview) || job_getchannel(s:preview.job) != a:channel
    return
  endif
  try
    let ready = json_decode(a:message)
    if has_key(ready, 'url')
      let s:preview.url = ready.url
      let g:vimrc_lite_markdown_preview_url = ready.url
      if get(s:preview, 'no_browser', 0)
        echom 'Markdown: ' . ready.url
      else
        call s:OpenBrowser(ready.url)
      endif
    elseif get(ready, 'event', '') ==# 'image' && exists('*VimMarkdownImageReceived')
      call VimMarkdownImageReceived(ready)
    endif
  catch
    call s:Warn('preview: ' . a:message)
  endtry
endfunction

function! s:PreviewError(channel, message) abort
  if !empty(a:message)
    call s:Warn('preview: ' . a:message)
  endif
endfunction

function! s:Send() abort
  if empty(s:preview) || job_status(s:preview.job) !=# 'run'
        \ || !bufexists(s:preview.buf)
    return
  endif
  let buf = s:preview.buf
  let payload = {}
  let tick = getbufvar(buf, 'changedtick')
  if get(s:preview, 'tick', -1) != tick
    let path = empty(bufname(buf)) ? getcwd() . '/Untitled.md' : fnamemodify(bufname(buf), ':p')
    let payload = {'text': join(getbufline(buf, 1, '$'), "\n"),
          \ 'path': path, 'root': s:preview.root,
          \ 'tick': tick,
          \ 'name': empty(bufname(buf)) ? 'Untitled.md' : fnamemodify(path, ':t')}
    let s:preview.tick = tick
  endif
  if bufnr('%') == buf
    let payload.line = line('.')
    let payload.column = col('.')
  endif
  if !empty(payload)
    try
      call ch_sendraw(job_getchannel(s:preview.job), json_encode(payload) . "\n")
    catch
      call s:Warn('preview channel closed; use :VimMarkdownPreview to restart')
    endtry
  endif
endfunction

function! VimMarkdownPreviewSync() abort
  call s:Send()
  call VimMarkdownViewSchedule()
endfunction

function! VimMarkdownImageBridge(request) abort
  call s:Preview(1)
  if !empty(s:preview) && job_status(s:preview.job) ==# 'run'
    call ch_sendraw(job_getchannel(s:preview.job),
          \ json_encode({'image_request': a:request}) . "\n")
  endif
endfunction

function! s:Refresh(timer) abort
  let s:timer = -1
  if exists('*VimMarkdownViewRefresh')
    call VimMarkdownViewRefresh()
  endif
  call s:Send()
  call s:OutlineRefresh()
endfunction

function! s:Changed() abort
  if !s:Markdown()
    return
  endif
  let view_changed = exists('*VimMarkdownViewInvalidate') ? VimMarkdownViewInvalidate() : 0
  if !view_changed && empty(s:preview) && empty(s:outline)
    return
  endif
  if s:timer != -1
    call timer_stop(s:timer)
  endif
  let s:timer = timer_start(get(g:, 'vimrc_lite_markdown_debounce', 150),
        \ function('<SID>Refresh'))
endfunction

function! s:Stop() abort
  if s:timer != -1
    call timer_stop(s:timer)
    let s:timer = -1
  endif
  if !empty(s:preview)
    if job_status(s:preview.job) ==# 'run'
      call job_stop(s:preview.job)
    endif
    let s:preview = {}
  endif
  unlet! g:vimrc_lite_markdown_preview_url
endfunction

function! s:Preview(no_browser) abort
  if !s:Markdown()
    call s:Warn('open a Markdown buffer first')
    return
  endif
  if !has('job') || !has('channel') || !has('timers') || !executable('python3')
    call s:Warn('browser preview needs Vim +job +channel +timers and python3')
    return
  endif
  if !filereadable(s:directory . '/preview.py')
    call s:Warn('missing markdown/; copy the complete module or run vim-install.sh')
    return
  endif
  if empty(s:preview) || job_status(s:preview.job) !=# 'run'
    call s:Stop()
    let s:preview = {'job': job_start(['python3', '-B', s:directory . '/preview.py'],
          \ {'out_cb': function('<SID>PreviewOutput'),
          \ 'err_cb': function('<SID>PreviewError'), 'stoponexit': 'term'}),
          \ 'buf': bufnr('%'), 'root': VimLiteProjectRoot()}
  else
    let s:preview.buf = bufnr('%')
    let s:preview.root = VimLiteProjectRoot()
    let s:preview.tick = -1
    if has_key(s:preview, 'url') && !a:no_browser
      call s:OpenBrowser(s:preview.url)
    endif
  endif
  let s:preview.no_browser = a:no_browser
  call s:Send()
endfunction

function! s:Wipe(buf) abort
  if !empty(s:preview) && s:preview.buf == a:buf
    call s:Stop()
  endif
  if !empty(s:outline) && (s:outline.source == a:buf || s:outline.buf == a:buf)
    let s:outline = {}
  endif
endfunction

function! s:Shutdown() abort
  if exists('*vsnip#deactivate')
    call vsnip#deactivate()
  endif
  if exists('*VimMarkdownImagesStop')
    call VimMarkdownImagesStop()
  endif
  if exists('*VimMarkdownNotesStop')
    call VimMarkdownNotesStop()
  endif
  if exists('*VimMarkdownViewStop')
    call VimMarkdownViewStop()
  endif
  if exists('*VimMarkdownViewClear')
    for buf in getbufinfo()
      if getbufvar(buf.bufnr, 'vimrc_lite_markdown', 0)
        call VimMarkdownViewClear(buf.bufnr)
      endif
    endfor
  endif
  call s:FocusRestore()
  call s:Stop()
  if !empty(s:outline) && bufexists(s:outline.buf)
    execute 'silent! bwipeout ' . s:outline.buf
  endif
  let s:outline = {}
endfunction

function! s:ViewCursor() abort
  if s:Markdown() && exists('*VimMarkdownViewRefresh')
    for window in getwininfo()
      if window.bufnr == bufnr('%')
        call setwinvar(window.winid, '&conceallevel',
              \ get(b:, 'vimrc_lite_markdown_raw', 0) ? 0 : 2)
      endif
    endfor
    call VimMarkdownViewRefresh()
  endif
endfunction

function! s:ViewLeave() abort
  if exists('*VimMarkdownViewLeave')
    call VimMarkdownViewLeave()
  endif
endfunction

function! s:ViewInsert() abort
  if s:Markdown() && exists('*VimMarkdownViewClear')
    call VimMarkdownViewClear(bufnr('%'))
    for window in getwininfo()
      if window.bufnr == bufnr('%')
        call setwinvar(window.winid, '&conceallevel', 0)
      endif
    endfor
  endif
endfunction

function! s:OtherFiletype() abort
  if &filetype !=# 'markdown'
    call s:FocusRestore()
  endif
endfunction

function! s:Help() abort
  echo join(['Markdown · <Space>m', 'p preview / s stop / o outline / r reading view',
        \ 'f focus / x task / t table / l follow link / h help',
        \ 'i insert template · :VimMarkdownInsert code python',
        \ 'Visual: b bold / i italic / c code · [h ]h headings',
        \ 'v paste image / c TOC / u update TOC / z fold / Z fold all / a auto-save',
        \ 'Tab expands snippets / Shift-Tab goes back · mk/dm/ff · 4x4tb',
        \ 'Enter continues lists; empty item exits · j/k move by screen line'], "\n")
endfunction

command! -bang VimMarkdownPreview call <SID>Preview(<bang>0)
command! VimMarkdownStop call <SID>Stop()
command! VimMarkdownOutline call <SID>Outline()
command! VimMarkdownRender call <SID>Render()
command! VimMarkdownFocus call <SID>Focus()
command! -range VimMarkdownTask call <SID>Task(<line1>, <line2>)
command! VimMarkdownTable call <SID>Table()
command! -nargs=* -complete=customlist,<SID>InsertComplete VimMarkdownInsert
      \ call <SID>Insert(<q-args>)
command! -range -nargs=1 VimMarkdownWrap call <SID>Wrap(<q-args>, <line1>, <line2>)
command! VimMarkdownLink call <SID>Link()
command! VimMarkdownHelp call <SID>Help()

augroup vimrc_lite_markdown
  autocmd!
  autocmd FileType markdown call s:Attach()
  autocmd FileType * call s:OtherFiletype()
  autocmd BufWinEnter * call s:Attach()
  autocmd BufWinLeave * call s:FocusRestore()
  autocmd BufLeave * call s:FocusRestore()
  autocmd BufWinLeave * call s:ViewLeave()
  autocmd InsertEnter * call s:ViewInsert()
  autocmd InsertLeave * call s:ViewCursor()
  autocmd Syntax markdown let b:vimrc_lite_markdown_fences = 0
  autocmd Syntax markdown call s:Syntax()
  autocmd ColorScheme * call s:Colors()
  autocmd TextChanged,TextChangedI,BufWritePost * call s:Changed()
  autocmd CursorMoved,CursorMovedI * call s:Changed()
  autocmd CursorMoved * call s:ViewCursor()
  autocmd WinEnter,VimResized * call VimMarkdownViewSchedule()
  autocmd BufWipeout * call s:Wipe(str2nr(expand('<abuf>')))
  autocmd VimLeavePre * call s:Shutdown()
  autocmd User VimrcLiteReload call s:Shutdown()
augroup END
let s:view = fnamemodify(s:directory, ':h') . '/markdown-view.vim'
if filereadable(s:view)
  execute 'source ' . fnameescape(s:view)
else
  call s:Warn('missing markdown-view.vim; copy the complete module or run vim-install.sh')
endif
call s:Colors()
let s:notes = fnamemodify(s:directory, ':h') . '/markdown-notes.vim'
if filereadable(s:notes)
  execute 'source ' . fnameescape(s:notes)
endif
let s:snippets = fnamemodify(s:directory, ':h') . '/markdown-snippets.vim'
if filereadable(s:snippets)
  execute 'source ' . fnameescape(s:snippets)
endif
let s:images = fnamemodify(s:directory, ':h') . '/markdown-images.vim'
if filereadable(s:images)
  execute 'source ' . fnameescape(s:images)
endif
if &filetype ==# 'markdown'
  call s:Attach()
endif
