" 编辑辅助模块：清空 buffer、去除行尾空白、按 commentstring 切换注释。
" gc 作为操作符支持 gc{motion}，gcc 注释当前行（可带计数）。

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim edit: ' . a:message
  echohl None
endfunction

function! s:Editable() abort
  if &buftype !=# '' || !&modifiable || &readonly
    call s:Warn('current buffer is not an editable file')
    return 0
  endif
  return 1
endfunction

function! s:ClearBuffer() abort
  if s:Editable()
    %delete _
  endif
endfunction

function! s:TrimWhitespace() abort
  if !s:Editable()
    return
  endif
  let view = winsaveview()
  let search = @/
  try
    keeppatterns %s/\s\+$//e
  finally
    let @/ = search
    call winrestview(view)
  endtry
endfunction

" 注释切换以文件类型的 commentstring 为准，支持行注释和单行块注释。
" 前缀去掉尾部空白、后缀去掉首部空白后，转义成可拼接的正则字面量。
function! s:CommentToken(text, trim) abort
  return escape(substitute(a:text, a:trim, '', ''), '\.*$^~[]')
endfunction

function! s:CommentStyle() abort
  let comment = &l:commentstring
  if empty(&l:filetype) || comment !~# '%s'
    return ['# ', '']
  endif
  let index = stridx(comment, '%s')
  let prefix = strpart(comment, 0, index)
  if empty(prefix)
    return ['# ', '']
  endif
  return [prefix, strpart(comment, index + 2)]
endfunction

" 前缀末尾空格按一个可选空格匹配，避免把 #include 误判为注释。
function! s:CommentStart(prefix) abort
  let pattern = s:CommentToken(a:prefix, '\s\+$')
  if a:prefix =~# '\s$'
    return pattern . '\%(\s\|$\)\@='
  endif
  return pattern
endfunction

function! s:IsCommented(line, prefix, suffix) abort
  let body = substitute(a:line, '^\s*', '', '')
  if empty(body)
    return 0
  endif
  if body !~# '^' . s:CommentStart(a:prefix)
    return 0
  endif
  if !empty(a:suffix)
    let tail = s:CommentToken(a:suffix, '^\s\+')
    if body !~# tail . '\s*$'
      return 0
    endif
  endif
  return 1
endfunction

function! s:CommentLine(line, prefix, suffix) abort
  let indent = matchstr(a:line, '^\s*')
  let body = strpart(a:line, len(indent))
  if empty(body)
    return a:line
  endif
  let start = a:prefix
  if start !~# '\s$'
    let start .= ' '
  endif
  if empty(a:suffix)
    return indent . start . body
  endif
  let finish = a:suffix
  if finish !~# '^\s'
    let finish = ' ' . finish
  endif
  return indent . start . body . finish
endfunction

function! s:UncommentLine(line, prefix, suffix) abort
  let indent = matchstr(a:line, '^\s*')
  let body = strpart(a:line, len(indent))
  let bare = s:CommentToken(a:prefix, '\s\+$')
  if body =~# '^' . s:CommentStart(a:prefix)
    let body = substitute(body, '^' . bare . '\s\?', '', '')
  endif
  if !empty(a:suffix)
    let tail = s:CommentToken(a:suffix, '^\s\+')
    let body = substitute(body, '\s\?' . tail . '\s*$', '', '')
  endif
  return indent . body
endfunction

" 选区全部为注释时取消注释，否则整体添加；空行保持原样。
function! s:ToggleComments(first, last) abort
  if !s:Editable()
    return
  endif
  let [prefix, suffix] = s:CommentStyle()
  let lines = getline(a:first, a:last)
  let commented = 1
  for line in lines
    if line =~# '^\s*$'
      continue
    endif
    if !s:IsCommented(line, prefix, suffix)
      let commented = 0
      break
    endif
  endfor
  let view = winsaveview()
  let search = @/
  let replacement = []
  for line in lines
    if line =~# '^\s*$'
      call add(replacement, line)
    elseif commented
      call add(replacement, s:UncommentLine(line, prefix, suffix))
    else
      call add(replacement, s:CommentLine(line, prefix, suffix))
    endif
  endfor
  call setline(a:first, replacement)
  let @/ = search
  call winrestview(view)
endfunction

function! s:CommentOperator(type) abort
  call s:ToggleComments(line("'["), line("']"))
endfunction

nnoremap <silent> <leader>bD :call <SID>ClearBuffer()<CR>
xnoremap <silent> <leader>bD "_d
nnoremap <silent> <leader>bw :call <SID>TrimWhitespace()<CR>
nnoremap <silent> gc :<C-u>set operatorfunc=<SID>CommentOperator<CR>g@
nnoremap <silent> gcc :<C-u>call <SID>ToggleComments(line('.'), line('.') + v:count1 - 1)<CR>
xnoremap <silent> gc :<C-u>call <SID>ToggleComments(line("'<"), line("'>"))<CR>
