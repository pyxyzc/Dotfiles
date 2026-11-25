" Markdown：稳定源码布局、原生高亮与显式写作操作。
if exists('#vimrc_lite_markdown#User#VimrcLiteReload')
  doautocmd <nomodeline> vimrc_lite_markdown User VimrcLiteReload
endif
let s:directory = fnamemodify(expand('<sfile>:p'), ':h')
let s:outline = {}
let s:pending = {}
execute 'source ' . fnameescape(s:directory . '/markdown-structure.vim')

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Markdown: ' . a:message
  echohl None
endfunction

function! s:Active() abort
  return &filetype ==# 'markdown' && &buftype ==# ''
        \ && get(g:, 'vimrc_lite_markdown', 1) && !get(b:, 'vimrc_lite_large_file', 0)
endfunction

function! s:Editable() abort
  return s:Active() && &modifiable && !&readonly
endfunction

function! s:Colors() abort
  highlight default link VimMarkdownH1 Title
  highlight default link VimMarkdownH2 Function
  highlight default link VimMarkdownH3 Type
  highlight default link VimMarkdownH4 Identifier
  highlight default link VimMarkdownH5 Constant
  highlight default link VimMarkdownH6 Comment
  for level in range(1, 6)
    execute 'highlight default link VimMarkdownHeadingMark' . level . ' VimMarkdownH' . level
  endfor
  highlight default link VimMarkdownMarker Comment
  highlight default link VimMarkdownCode String
  highlight default link VimMarkdownInline String
  highlight default link VimMarkdownQuote Comment
  highlight default link VimMarkdownLink Underlined
  highlight default link VimMarkdownUrl Comment
  highlight default link VimMarkdownTodo Todo
  highlight default link VimMarkdownDone Comment
  highlight default link VimMarkdownComment Comment
  highlight default link VimMarkdownFront Comment
  highlight default link VimMarkdownRule Comment
  highlight default link VimMarkdownBold Statement
  highlight default link VimMarkdownItalic Type
  highlight default link VimMarkdownStrike Comment
endfunction

function! s:Syntax() abort
  if !s:Active()
    return
  endif
  syntax clear
  if get(b:, 'vimrc_lite_md_long_line', 0)
    let b:current_syntax = 'markdown'
    return
  endif
  syntax case match
  syntax spell toplevel
  syntax match VimMarkdownBold /\*\*[^*\n]\+\*\*/
  syntax match VimMarkdownItalic /\%(^\|\s\)\zs\*[^*\n]\+\*/
  syntax match VimMarkdownStrike /\~\~[^\~\n]\+\~\~/
  syntax match VimMarkdownLink /!\?\[[^]\n]*\]/
  syntax match VimMarkdownUrl /\](\zs[^)\n]*\ze)/
  syntax match VimMarkdownUrl /https\?:\/\/[^ <>\t]\+/
  syntax match VimMarkdownQuote /^\s*>\%([ >]*\)/
  syntax match VimMarkdownMarker /^\s*\%([-+*]\|\d\+[.)]\)\ze\s/
  syntax match VimMarkdownTodo /\[[ !-]\]/
  syntax match VimMarkdownDone /\[[xX]\]/
  " Setext 保留原有下划线。仅给普通段落加标题色，块语法随后定义。
  let paragraph = '^ \{0,3}\%([#>|]\|[-+*][ \t]\|\d\+[.)][ \t]\)\@!\S.*'
  execute 'syntax match VimMarkdownH1 /' . paragraph . '\n \{0,3}=\+[ \t]*$/'
  execute 'syntax match VimMarkdownH2 /' . paragraph . '\n \{0,3}-\+[ \t]*$/'
  " 用单列标记区分级别；双宽终端使用数字。光标行由 Vim 显示原始 #。
  let markers = ['█', '▰', '◆', '▸', '•', '·']
  for level in range(1, 6)
    let hashes = repeat('#', level)
    let marker = markers[level - 1]
    let group = 'VimMarkdownHeadingMark' . level
    execute 'syntax match VimMarkdownH' . level . ' /^ \{0,3}' . hashes
          \ . '\%([ \t].*\|$\)/ contains=' . group
    execute 'syntax match ' . group . ' /^ \{0,3}\zs' . hashes
          \ . '\ze\%([ \t]\|$\)/ contained conceal cchar='
          \ . (strdisplaywidth(marker) == 1 ? marker : string(level))
  endfor
  syntax match VimMarkdownRule /^ \{0,3}\%([-*_]\s*\)\{3,}$/
  syntax match VimMarkdownCode /^\%( \{4}\|\t\).*/
  syntax region VimMarkdownInline start=/\z(`\+\)/ end=/\z1/ oneline keepend
  syntax region VimMarkdownComment start=/<!--/ end=/-->/ keepend
  syntax region VimMarkdownCode matchgroup=VimMarkdownMarker
        \ start=/^ \{0,3}\z(`\{3,}\)[^`]*$/ end=/^ \{0,3}\z1`*\s*$/ keepend
  syntax region VimMarkdownCode matchgroup=VimMarkdownMarker
        \ start=/^ \{0,3}\z(\~\{3,}\).*$/ end=/^ \{0,3}\z1\~*\s*$/ keepend
  syntax region VimMarkdownFront start=/\%1l^---$/ end=/^\%(---\|\.\.\.\)$/ keepend
  syntax sync minlines=40 maxlines=120
  let b:current_syntax = 'markdown'
endfunction

function! s:Window() abort
  if !s:Active()
    return
  endif
  if !exists('w:vimrc_lite_md_window')
    let w:vimrc_lite_md_window = {}
    for name in ['wrap', 'linebreak', 'breakindent', 'conceallevel', 'concealcursor']
      let w:vimrc_lite_md_window[name] = eval('&l:' . name)
    endfor
  endif
  setlocal linebreak breakindent concealcursor=
  let &l:wrap = !get(b:, 'vimrc_lite_md_long_line', 0)
  let &l:conceallevel = get(b:, 'vimrc_lite_md_render',
        \ get(g:, 'vimrc_lite_markdown_render', 1)) ? 2 : 0
endfunction

function! s:WindowRestore() abort
  if exists('w:vimrc_lite_md_focus')
    for [name, value] in items(w:vimrc_lite_md_focus)
      execute 'let &l:' . name . ' = value'
    endfor
    unlet w:vimrc_lite_md_focus
  endif
  if exists('w:vimrc_lite_md_window')
    for [name, value] in items(w:vimrc_lite_md_window)
      execute 'let &l:' . name . ' = value'
    endfor
    unlet w:vimrc_lite_md_window
  endif
endfunction

function! s:MapInfo(mode, key) abort
  let saved = &cpoptions
  try
    noautocmd set cpoptions-=<
    return maparg(a:key, a:mode, 0, 1)
  finally
    noautocmd let &cpoptions = saved
  endtry
endfunction

function! s:Map(mode, key, rhs, flags) abort
  let old = s:MapInfo(a:mode, a:key)
  call add(b:vimrc_lite_md_maps, [a:mode, a:key, get(old, 'buffer', 0) ? old : {}])
  execute a:mode . 'noremap <silent><special><buffer>' . a:flags . ' ' . a:key . ' ' . a:rhs
endfunction

function! s:Attach() abort
  if !s:Active()
    return
  endif
  if !exists('b:vimrc_lite_md_options')
    let b:vimrc_lite_md_options = {}
    for name in ['expandtab', 'shiftwidth', 'softtabstop', 'autoindent', 'indentexpr',
          \ 'formatoptions', 'textwidth', 'synmaxcol']
      let b:vimrc_lite_md_options[name] = eval('&l:' . name)
    endfor
    setlocal expandtab shiftwidth=2 softtabstop=2 autoindent indentexpr= textwidth=0
    setlocal formatoptions-=t formatoptions-=c formatoptions-=r formatoptions-=o
    let &l:synmaxcol = get(g:, 'vimrc_lite_markdown_synmaxcol', 512)
    let b:vimrc_lite_md_maps = []
    let threshold = get(g:, 'vimrc_lite_markdown_long_line_bytes', 8192)
    let b:vimrc_lite_md_long_line = threshold > 0
          \ && line2byte(line('$') + 1) > line('$') * threshold
    for [key, rhs] in items({'<leader>mr': 'VimMarkdownRender',
          \ '<leader>mo': 'VimMarkdownOutline', '<leader>mx': 'VimMarkdownTask',
          \ '<leader>mt': 'VimMarkdownTable', '<leader>ml': 'VimMarkdownLink',
          \ '<leader>mi': 'VimMarkdownInsert', '<leader>mc': 'VimMarkdownToc',
          \ '<leader>mh': 'VimMarkdownHelp', '<leader>mp': 'VimMarkdownPreview',
          \ '<leader>ms': 'VimMarkdownStop', '<leader>mz': 'VimMarkdownFold',
          \ '<leader>mf': 'VimMarkdownFocus'})
      call s:Map('n', key, ':' . rhs . '<CR>', '')
    endfor
    call s:Map('n', ']h', ':<C-u>call <SID>Heading(1, v:count1)<CR>', '')
    call s:Map('n', '[h', ':<C-u>call <SID>Heading(-1, v:count1)<CR>', '')
    call s:Map('n', 'j', 'v:count ? "j" : "gj"', '<expr>')
    call s:Map('n', 'k', 'v:count ? "k" : "gk"', '<expr>')
    " 旧版 Vim 不会重映射 noremap 返回的 <Plug>；显式允许脚本局部映射。
    call s:Map('i', '<CR>', '<SID>EnterKey()', '<script><expr>')
    call s:Map('i', expand('<SID>') . 'MarkdownEnter', '<SID>EnterList()', '<expr>')
    call s:Map('x', '<leader>mx', ':VimMarkdownTask<CR>', '')
    for [key, kind] in items({'b': 'bold', 'i': 'italic', 'c': 'code'})
      call s:Map('x', '<leader>m' . key,
            \ ':<C-u>call <SID>VisualWrap(''' . kind . ''')<CR>', '')
    endfor
    let b:undo_ftplugin = get(b:, 'undo_ftplugin', '')
          \ . '|call ' . expand('<SID>') . 'Detach()'
    call s:Syntax()
  endif
  call VimMarkdownIndexAttach()
  call VimMarkdownIndexResume()
  call s:Window()
endfunction

function! s:Focus() abort
  if !s:Active()
    return
  endif
  if exists('w:vimrc_lite_md_focus')
    for [name, value] in items(w:vimrc_lite_md_focus)
      execute 'let &l:' . name . ' = value'
    endfor
    unlet w:vimrc_lite_md_focus
  else
    let w:vimrc_lite_md_focus = {'number': &l:number, 'relativenumber': &l:relativenumber,
          \ 'signcolumn': &l:signcolumn, 'cursorline': &l:cursorline}
    setlocal nonumber norelativenumber signcolumn=no nocursorline
  endif
endfunction

function! s:Fold() abort
  if !s:Ready('Fold', [])
    return
  endif
  if foldclosed(line('.')) >= 0
    normal! zo
    return
  endif
  let current = {}
  let last = line('$')
  for heading in b:vimrc_lite_md_index.headers
    if heading.line <= line('.')
      let current = heading
    elseif !empty(current) && heading.level <= current.level
      let last = heading.line - 1
      break
    endif
  endfor
  if !empty(current) && last > current.line
    setlocal foldmethod=manual
    execute current.line . ',' . last . 'fold'
  endif
endfunction

function! s:Detach() abort
  call s:WindowRestore()
  if !exists('b:vimrc_lite_md_options')
    return
  endif
  call VimMarkdownIndexStop(bufnr('%'))
  for [name, value] in items(b:vimrc_lite_md_options)
    execute 'let &l:' . name . ' = value'
  endfor
  for [mode, key, old] in b:vimrc_lite_md_maps
    if get(s:MapInfo(mode, key), 'sid', 0) != s:script_id
      continue
    endif
    execute 'silent! ' . mode . 'unmap <special><buffer> ' . key
    if !empty(old) && exists('*mapset')
      call mapset(mode, 0, old)
    endif
  endfor
  let cleanup = '|call ' . expand('<SID>') . 'Detach()'
  let b:undo_ftplugin = substitute(get(b:, 'undo_ftplugin', ''),
        \ '\V' . escape(cleanup, '\'), '', 'g')
  unlet b:vimrc_lite_md_options b:vimrc_lite_md_maps
  unlet! b:vimrc_lite_md_index
endfunction

function! s:Other() abort
  if &filetype !=# 'markdown'
    call s:Detach()
  endif
endfunction

function! s:Render() abort
  if s:Active()
    let b:vimrc_lite_md_render = !get(b:, 'vimrc_lite_md_render',
          \ get(g:, 'vimrc_lite_markdown_render', 1))
    for window in win_findbuf(bufnr('%'))
      call setwinvar(window, '&conceallevel', b:vimrc_lite_md_render ? 2 : 0)
    endfor
  endif
endfunction

function! s:EnterList() abort
  if &paste || !get(g:, 'vimrc_lite_markdown_lists', 1) || !s:Editable()
    return "\<CR>"
  endif
  " 普通文字只检查当前行的短前缀，不请求结构上下文。
  let prefix = strpart(getline('.'), 0, min([col('.') - 1, 256]))
  if prefix !~# '^\s*\%([-+*>]\|\d\+[.)]\)'
        \ || col('.') > 4096 || VimMarkdownContext(line('.')) != 0
    return "\<CR>"
  endif
  let text = strpart(getline('.'), 0, col('.') - 1)
  let list = matchlist(text, '^\(\s*\%([>]\s*\)*\)\([-+*]\|\d\+[.)]\)\s\+'
        \ . '\(\[[ xX!-]\]\s\+\)\?\(.*\)$')
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
  return empty(quote) ? "\<CR>" : text ==# quote && col('.') > strlen(getline('.'))
        \ ? "\<C-u>\<CR>" : "\<CR>" . (indent('.') > 0 ? "\<C-u>" : '') . quote
endfunction

function! s:EnterKey() abort
  " Ignore 先提交已输入文本再检查续写，但会结束补全，菜单分支先处理。
  if pumvisible()
    return exists('*complete_info') && complete_info(['selected']).selected < 0
          \ ? "\<C-e>\<CR>" : "\<C-y>"
  endif
  return "\<Ignore>\<SNR>" . s:script_id . '_MarkdownEnter'
endfunction

function! s:Task(first, last) abort
  if !s:Editable() || !s:Ready('Task', [a:first, a:last])
    return
  endif
  let lines = getline(a:first, a:last)
  let changed = 0
  let protected = b:vimrc_lite_md_index.protected
  for offset in range(len(lines))
    if get(protected, string(a:first + offset), 1)
      continue
    endif
    let text = lines[offset]
    let pattern = '^\(\s*\%([>]\s*\)*\%([-+*]\|\d\+[.)]\)\s\+\)'
    if text =~# pattern . '\[[ xX!-]\]'
      let checked = text =~# pattern . '\[[xX]\]'
      let lines[offset] = substitute(text, pattern . '\[[ xX!-]\]',
            \ '\1[' . (checked ? ' ' : 'x') . ']', '')
    elseif text =~# pattern
      let lines[offset] = substitute(text, pattern, '\1[ ] ', '')
    elseif text =~# '\S'
      let lines[offset] = substitute(text, '^\(\s*\)', '\1- [ ] ', '')
    endif
    let changed = changed || lines[offset] !=# text
  endfor
  if changed
    call setline(a:first, lines)
  endif
endfunction

" 竖线仅在转义和代码 span 外拆分；中文宽度由 strdisplaywidth 计算。
function! s:Cells(text) abort
  let text = substitute(a:text, '^\s*|\|\s*$', '', 'g')
  let text = substitute(text, '\%(^\|[^\\]\)\zs|$', '', '')
  let cells = []
  if stridx(text, '`') < 0 && stridx(text, '\') < 0
    return map(split(text, '|', 1), 'substitute(v:val, "^\\s*\\|\\s*$", "", "g")')
  endif
  let first = 0
  let offset = 0
  let ticks = ''
  while offset < strlen(text)
    let offset = match(text, '[\\`|]', offset)
    if offset < 0
      break
    endif
    let char = strpart(text, offset, 1)
    if char ==# '\'
      let offset += 2
      continue
    elseif char ==# '`'
      let marker = matchstr(strpart(text, offset), '^`\+')
      let ticks = empty(ticks) ? marker : ticks ==# marker ? '' : ticks
      let offset += strlen(marker)
      continue
    elseif char ==# '|' && empty(ticks)
      call add(cells, substitute(strpart(text, first, offset - first), '^\s*\|\s*$', '', 'g'))
      let first = offset + 1
    endif
    let offset += 1
  endwhile
  call add(cells, substitute(strpart(text, first), '^\s*\|\s*$', '', 'g'))
  return cells
endfunction

function! s:Table() abort
  if !s:Editable() || !s:Ready('Table', [])
        \ || VimMarkdownContext(line('.')) != 0 || getline('.') !~# '|'
    return
  endif
  let first = line('.')
  let last = first
  let protected = b:vimrc_lite_md_index.protected
  while first > 1 && getline(first - 1) =~# '|' && first > line('.') - 500
        \ && !get(protected, string(first - 1), 1)
    let first -= 1
  endwhile
  while last < line('$') && getline(last + 1) =~# '|' && last < first + 500
        \ && !get(protected, string(last + 1), 1)
    let last += 1
  endwhile
  if last - first >= 500 || line2byte(last + 1) - line2byte(first) > 65536
    call s:Warn('table exceeds 500 rows / 64 KiB; select a smaller table')
    return
  endif
  let original = getline(first, last)
  let indentation = matchstr(original[0], '^\s*')
  let stable = 1
  for text in original
    if strpart(text, 0, strlen(indentation) + 1) !=# indentation . '|'
      let stable = 0
      break
    endif
  endfor
  let rows = map(copy(original), 's:Cells(v:val)')
  if len(rows) < 2 || join(rows[1], '') !~# '^[-: ]\+$'
        \ || !empty(filter(copy(rows[1]), 'v:val !~# "^:\\=-\\{3,}:\\=$"'))
    call s:Warn('table needs a header and a valid separator row')
    return
  endif
  let columns = len(rows[0])
  if columns > 40 || !empty(filter(copy(rows), 'len(v:val) != columns'))
    call s:Warn('table has inconsistent columns or more than 40 columns')
    return
  endif
  let widths = repeat([3], columns)
  for row in rows
    for column in range(columns)
      let widths[column] = max([widths[column], strdisplaywidth(row[column])])
    endfor
  endfor
  let output = []
  let bytes = 0
  for index in range(len(rows))
    let cells = []
    for column in range(columns)
      let value = rows[index][column]
      let alignment = rows[1][column]
      if index == 1
        let left = alignment[0] ==# ':' ? ':' : ''
        let right = alignment[-1:] ==# ':' ? ':' : ''
        let value = left . repeat('-', max([3, widths[column] - strlen(left . right)])) . right
      else
        let padding = widths[column] - strdisplaywidth(value)
        let left = alignment[-1:] !=# ':' ? 0 : alignment[0] ==# ':' ? padding / 2 : padding
        let value = repeat(' ', left) . value . repeat(' ', padding - left)
      endif
      call add(cells, value)
    endfor
    let text = indentation . '| ' . join(cells, ' |' . ' ') . ' |'
    let bytes += strlen(text) + 1
    if bytes > 65536
      call s:Warn('formatted table would exceed 64 KiB; source kept unchanged')
      return
    endif
    call add(output, text)
  endfor
  if output !=# getline(first, last)
    let view = winsaveview()
    call setline(first, output)
    call winrestview(view)
    if stable
      call VimMarkdownIndexStableRange(first, last)
    endif
  endif
endfunction

function! s:Delimiter(kind, text) abort
  if a:kind ==# 'code'
    let longest = 0
    let offset = 0
    while 1
      let found = matchstrpos(a:text, '`\+', offset)
      if found[1] < 0
        break
      endif
      let longest = max([longest, strlen(found[0])])
      let offset = found[2]
    endwhile
    return repeat('`', longest + 1)
  endif
  return a:kind ==# 'bold' ? '**' : '*'
endfunction

function! s:Wrap(kind, first, last, start, end) abort
  if !s:Editable() || index(['bold', 'italic', 'code'], a:kind) < 0
    return
  endif
  let lines = getline(a:first, a:last)
  let selected = copy(lines)
  let selected[-1] = strpart(selected[-1], 0, a:end)
  let selected[0] = strpart(selected[0], a:start)
  let text = join(selected, "\n")
  let delimiter = s:Delimiter(a:kind, text)
  let pad = a:kind ==# 'code' && (text =~# '^`\|`$'
        \ || text =~# '^ .* $' && text =~# '\S') ? ' ' : ''
  let lines[-1] = strpart(lines[-1], 0, a:end) . pad . delimiter
        \ . strpart(lines[-1], a:end)
  let lines[0] = strpart(lines[0], 0, a:start) . delimiter . pad
        \ . strpart(lines[0], a:start)
  call setline(a:first, lines)
endfunction

function! s:VisualWrap(kind) abort
  let first = line("'<")
  let last = line("'>")
  let start = col("'<") - 1
  let end = col("'>") - 1
  let end += strlen(matchstr(strpart(getline(last), end), '^.'))
  if visualmode() ==# 'V'
    let start = 0
    let end = strlen(getline(last))
  elseif &selection ==# 'exclusive'
    let end = col("'>") - 1
  endif
  if visualmode() ==# "\<C-v>"
    call s:Warn('use a character or line selection for wrapping')
    return
  endif
  call s:Wrap(a:kind, first, last, start, end)
endfunction

function! s:Insert(arguments) abort
  if !s:Editable()
    return
  endif
  let args = split(a:arguments)
  let kind = get(args, 0, '')
  let templates = {'code': ['```' . get(args, 1, ''), '', '```'],
        \ 'link': ['[文字](地址)'], 'image': ['![描述](imgs/image.png)'],
        \ 'math': ['$$', '', '$$'], 'note': ['> [!NOTE]', '> '],
        \ 'task': ['- [ ] '], 'mermaid': ['```mermaid', '', '```'],
        \ 'plantuml': ['```plantuml', '@startuml', '', '@enduml', '```']}
  if kind ==# 'table'
    let columns = min([20, max([1, str2nr(get(args, 1, '3'))])])
    let rows = min([50, max([1, str2nr(get(args, 2, '3'))])])
    let templates.table = ['| ' . join(repeat(['标题'], columns), ' |' . ' ') . ' |',
          \ '| ' . join(repeat(['---'], columns), ' |' . ' ') . ' |']
          \ + repeat(['| ' . join(repeat([''], columns), ' |' . ' ') . ' |'], rows)
  endif
  if !has_key(templates, kind)
    call s:Warn('use :VimMarkdownInsert code [lang] / table [cols rows] / link / image / math'
          \ . ' / note / task / mermaid / plantuml')
    return
  endif
  let first = line('.') + 1
  let output = templates[kind]
  if empty(getline('.'))
    let first -= 1
    call setline(first, output[0])
    if len(output) > 1
      undojoin
      call append(first, output[1:])
    endif
  else
    call append(line('.'), output)
  endif
  call cursor(first + (index(['code', 'math', 'mermaid'], kind) >= 0 ? 1 : 0), 1)
endfunction

function! s:Ready(action, args) abort
  if !s:Active()
    return 0
  endif
  call VimMarkdownIndexChanged()
  if b:vimrc_lite_md_index.complete
    return 1
  endif
  let s:pending = {'buf': bufnr('%'), 'window': win_getid(), 'position': getcurpos(),
        \ 'tick': b:changedtick, 'action': a:action, 'args': a:args}
  echo 'Markdown: building heading index…'
  call VimMarkdownIndexResume()
  return 0
endfunction

function! s:Heading(direction, count) abort
  if !s:Ready('Heading', [a:direction, a:count])
    return
  endif
  let rows = b:vimrc_lite_md_index.headers
  let matches = filter(copy(rows), a:direction > 0 ? 'v:val.line > line(".")'
        \ : 'v:val.line < line(".")')
  if !empty(matches)
    let target = a:direction > 0 ? min([len(matches), a:count]) - 1
          \ : max([0, len(matches) - a:count])
    normal! m'
    call cursor(matches[target].line, 1)
    normal! zv
  endif
endfunction

function! s:OutlineJump() abort
  if empty(s:outline) || line('.') < 4 || line('.') - 4 >= len(s:outline.rows)
    return
  endif
  if getbufvar(s:outline.source, 'changedtick') != s:outline.tick
    call s:Warn('outline changed; reopen with Space m o')
    return
  endif
  let target = s:outline.rows[line('.') - 4].line
  if win_gotoid(s:outline.window)
    call cursor(target, 1)
    normal! zv
  endif
endfunction

function! s:Outline() abort
  if !s:Ready('Outline', [])
    return
  endif
  if !empty(s:outline) && bufexists(s:outline.buf)
    execute 'silent! bwipeout ' . s:outline.buf
  endif
  let s:outline = {'source': bufnr('%'), 'window': win_getid(),
        \ 'tick': b:changedtick, 'rows': copy(b:vimrc_lite_md_index.headers)}
  botright 32vnew
  let s:outline.buf = bufnr('%')
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
  setlocal filetype=vimmarkdownoutline
  call VimLitePanel('Markdown', 'Enter: jump  q: close')
  call setline(1, ['  Headings', '  Enter: jump  q: close', '']
        \ + map(copy(s:outline.rows), 'repeat("  ", v:val.level) . v:val.text'))
  setlocal nomodifiable nowrap
  nnoremap <silent><buffer> <CR> :call <SID>OutlineJump()<CR>
  nnoremap <silent><buffer> q :close<CR>
endfunction

function! VimMarkdownIndexDone(buf) abort
  let index = getbufvar(a:buf, 'vimrc_lite_md_index', {})
  let long_line = !empty(get(index, 'long_lines', {}))
  if getbufvar(a:buf, 'vimrc_lite_md_long_line', 0) != long_line
    call setbufvar(a:buf, 'vimrc_lite_md_long_line', long_line)
    for window in getwininfo()
      if window.bufnr == a:buf
        call setwinvar(window.winid, '&wrap', !long_line)
      endif
    endfor
    if bufnr('%') == a:buf
      call s:Syntax()
    endif
  endif
  if !empty(s:pending) && s:pending.buf == a:buf
    let pending = s:pending
    let s:pending = {}
    if bufnr('%') == a:buf && win_getid() == pending.window
          \ && b:changedtick == pending.tick && getcurpos() ==# pending.position
      call call(function('<SID>' . pending.action), pending.args)
    endif
  endif
endfunction

function! s:Slug(text) abort
  let text = substitute(a:text, '!\?\[\([^]]*\)\]([^)]*)', '\1', 'g')
  let text = substitute(text, '`\|\*\*\|__\|\~\~', '', 'g')
  let text = substitute(text, '\%(^\|\s\)\zs[*_]\|[*_]\ze\%(\s\|$\)', '', 'g')
  let text = substitute(tolower(text), '[[:punct:]]',
        \ '\=index(["_", "-"], submatch(0)) >= 0 ? submatch(0) : ""', 'g')
  let text = substitute(text, '[！？，。：；、“”‘’（）【】《》…—·]', '', 'g')
  let slug = substitute(substitute(text, '^\s*\|\s*$', '', 'g'), '\s\+', '-', 'g')
  return empty(slug) ? 'section' : slug
endfunction

function! s:Anchors() abort
  let used = {}
  let rows = []
  for heading in b:vimrc_lite_md_index.headers
    let base = s:Slug(heading.text)
    let slug = base
    let number = 0
    while has_key(used, slug)
      let number += 1
      let slug = base . '-' . number
    endwhile
    let used[slug] = 1
    call add(rows, [heading, slug])
  endfor
  return rows
endfunction

function! s:TocBlock() abort
  let first = 0
  let last = 0
  let offset = 1
  while offset <= line('$')
    let found = match(getline(offset, '$'), '^<!-- /\?vim-markdown-toc -->$')
    if found < 0
      break
    endif
    let found += offset
    let state = VimMarkdownBlockBefore(found)
    if empty(state.fence) && !state.comment && !state.yaml
      if getline(found) ==# '<!-- vim-markdown-toc -->' && !first
        let first = found
      elseif getline(found) ==# '<!-- /vim-markdown-toc -->' && first
        let last = found
        break
      endif
    endif
    let offset = found + 1
  endwhile
  return [first, last]
endfunction

function! s:Toc() abort
  if !s:Editable() || !s:Ready('Toc', [])
    return
  endif
  let output = ['<!-- vim-markdown-toc -->']
  for [heading, anchor] in s:Anchors()
    if heading.level > 3
      continue
    endif
    let label = escape(heading.text, '[]')
    call add(output, repeat('  ', heading.level - 1) . '- [' . label . '](#' . anchor . ')')
  endfor
  call add(output, '<!-- /vim-markdown-toc -->')
  let [first, last] = s:TocBlock()
  if first && last >= first
    if getline(first, last) !=# output
      call setline(first, output[0 : min([len(output), last - first + 1]) - 1])
      let difference = len(output) - (last - first + 1)
      if difference > 0
        undojoin
        call append(last, output[len(output) - difference :])
      elseif difference < 0
        undojoin
        execute (first + len(output)) . ',' . last . 'delete _'
      endif
    endif
  else
    call append(line('.'), [''] + output + [''])
  endif
endfunction

function! s:Link() abort
  if !s:Active()
    return
  endif
  let text = getline('.')
  let offset = 0
  let target = ''
  while offset < strlen(text)
    let link = matchstrpos(text, '!\?\[[^]]*\](', offset)
    if link[1] < 0
      break
    endif
    let start = link[2]
    let position = start
    let depth = 1
    let angle = strpart(text, start, 1) ==# '<'
    while position < strlen(text) && depth
      let char = strpart(text, position, 1)
      if char ==# '\'
        let position += 2
        continue
      elseif char ==# '>' && angle
        let angle = 0
      elseif !angle && char ==# '('
        let depth += 1
      elseif !angle && char ==# ')'
        let depth -= 1
      endif
      let position += 1
    endwhile
    if !depth && col('.') - 1 >= link[1] && col('.') - 1 < position
      let target = strpart(text, start, position - start - 1)
      let target = substitute(target, '^\s*\|\s*$', '', 'g')
      let target = substitute(target, '\s\+["''][^"'']*["'']\s*$', '', '')
      let target = substitute(target, '^<\|>$', '', 'g')
      let target = substitute(target, '\\\([() ]\)', '\1', 'g')
      break
    endif
    let offset = position
  endwhile
  if empty(target)
    call s:Warn('place the cursor on an inline Markdown link')
    return
  endif
  if target =~# '^https\?://'
    if executable('xdg-open') && exists('*job_start')
      call job_start(['xdg-open', target], {'stoponexit': ''})
    else
      echo target
    endif
    return
  elseif target =~# '^\a[[:alnum:]+.-]*:'
    call s:Warn('unsupported link scheme: ' . target)
    return
  endif
  let parts = split(target, '#', 1)
  call map(parts, 'substitute(v:val, ''%\(\x\x\)'', '
        \ . '''\=printf("%c", str2nr(submatch(1), 16))'', ''g'')')
  if !empty(parts[0])
    let path = parts[0] =~# '^/' ? parts[0]
          \ : fnamemodify(expand('%:p'), ':h') . '/' . parts[0]
    if !filereadable(path)
      call s:Warn('file not found: ' . path)
      return
    endif
    execute 'edit ' . fnameescape(path)
  endif
  if len(parts) > 1
    call s:Anchor(parts[1])
  endif
endfunction

function! s:Anchor(anchor) abort
  if !s:Ready('Anchor', [a:anchor])
    return
  endif
  for [heading, anchor] in s:Anchors()
    if anchor ==# a:anchor
      normal! m'
      call cursor(heading.line, 1)
      normal! zv
      return
    endif
  endfor
  call s:Warn('heading not found: ' . a:anchor)
endfunction

function! s:Shutdown(restore) abort
  let s:pending = {}
  if exists('*VimMarkdownPreviewStop')
    call VimMarkdownPreviewStop()
  endif
  if !empty(s:outline) && bufexists(s:outline.buf)
    execute 'silent! bwipeout ' . s:outline.buf
  endif
  let s:outline = {}
  for window in getwininfo()
    if exists('*win_execute')
      call win_execute(window.winid, 'call ' . expand('<SID>') . 'WindowRestore()')
    endif
  endfor
  let original = bufnr('%')
  let view = winsaveview()
  let hidden = {}
  if a:restore
    let hidden[original] = &l:bufhidden
    setlocal bufhidden=hide
  endif
  try
    for info in getbufinfo()
      if a:restore && !empty(getbufvar(info.bufnr, 'vimrc_lite_md_options', {}))
        if !has_key(hidden, string(info.bufnr))
          let hidden[info.bufnr] = getbufvar(info.bufnr, '&bufhidden')
          call setbufvar(info.bufnr, '&bufhidden', 'hide')
        endif
        execute 'noautocmd keepalt keepjumps buffer ' . info.bufnr
        call s:Detach()
        if !get(g:, 'vimrc_lite_markdown', 1)
          syntax clear
          unlet! b:current_syntax
          runtime! syntax/markdown.vim
        endif
      elseif !empty(getbufvar(info.bufnr, 'vimrc_lite_md_index', {}))
        call VimMarkdownIndexStop(info.bufnr)
      endif
    endfor
  finally
    if bufnr('%') != original && bufexists(original)
      execute 'noautocmd keepalt keepjumps buffer ' . original
    endif
    for [buf, value] in items(hidden)
      if bufexists(str2nr(buf))
        call setbufvar(str2nr(buf), '&bufhidden', value)
      endif
    endfor
    call winrestview(view)
  endtry
endfunction

function! s:Preview(no_browser) abort
  if !exists('*VimMarkdownPreviewStart')
    execute 'source ' . fnameescape(s:directory . '/markdown-preview.vim')
  endif
  call VimMarkdownPreviewStart(a:no_browser)
endfunction

function! s:PreviewStop() abort
  if exists('*VimMarkdownPreviewStop')
    call VimMarkdownPreviewStop()
  endif
endfunction

function! s:Help() abort
  echo join(['Markdown · Space m', 'r reading/source · o outline · [h ]h headings',
        \ 'x task · t align table · l follow link · c insert/update TOC',
        \ 'i template: :VimMarkdownInsert code python / table 3 3 / math / image',
        \ 'Visual: b bold · i italic · c code',
        \ 'p offline preview · s stop; updates follow edits, not cursor movement',
        \ 'z fold current section · f focus mode',
        \ 'Enter continues lists; empty item exits. Counts with j/k use file lines.'], "\n")
endfunction

let s:script_id = str2nr(matchstr(expand('<SID>'), '\d\+'))
call s:Colors()
command! VimMarkdownRender call <SID>Render()
command! VimMarkdownOutline call <SID>Outline()
command! -range VimMarkdownTask call <SID>Task(<line1>, <line2>)
command! VimMarkdownTable call <SID>Table()
command! -nargs=* VimMarkdownInsert call <SID>Insert(<q-args>)
command! -range -nargs=1 VimMarkdownWrap
      \ call <SID>Wrap(<q-args>, <line1>, <line2>, 0, strlen(getline(<line2>)))
command! VimMarkdownToc call <SID>Toc()
command! VimMarkdownLink call <SID>Link()
command! VimMarkdownHelp call <SID>Help()
command! VimMarkdownFold call <SID>Fold()
command! VimMarkdownFocus call <SID>Focus()
command! -bang VimMarkdownPreview call <SID>Preview(<bang>0)
command! VimMarkdownStop call <SID>PreviewStop()

augroup vimrc_lite_markdown
  autocmd!
  autocmd FileType markdown call <SID>Attach()
  autocmd FileType * call <SID>Other()
  autocmd Syntax markdown call <SID>Syntax()
  autocmd BufWinEnter * call <SID>Attach()
  autocmd WinEnter * call VimMarkdownIndexResume()
  autocmd BufWinLeave * call <SID>WindowRestore()
  autocmd TextChanged,TextChangedI * call VimMarkdownIndexChanged()
  autocmd InsertLeave * call VimMarkdownIndexResume()
  autocmd BufWipeout * call VimMarkdownIndexStop(str2nr(expand('<abuf>')))
  autocmd ColorScheme * call <SID>Colors()
  autocmd User VimrcLiteReload call <SID>Shutdown(1)
  autocmd VimLeavePre * call <SID>Shutdown(0)
augroup END
call s:Attach()
