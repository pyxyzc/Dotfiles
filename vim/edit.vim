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

" 某些旧 Vim 的 trim() 没有方向参数；仅启用实际支持右侧裁剪的实现。
let s:trim_right = 0
if exists('*trim')
  try
    let s:trim_right = trim(' x ', " \t", 2) ==# ' x'
  catch /E118:/
  endtry
endif

function! s:TrimWhitespace() abort
  if !s:Editable()
    return
  endif
  let view = winsaveview()
  try
    " 按块查看字节数，长行区域从末尾裁剪；相邻短行仍合并为一次原生替换。
    " 不按全文平均长度判断，避免漏掉大量短行之间的单条巨型行。
    let first = 1
    let last = line('$')
    if s:trim_right
      for start in range(1, last, 256)
        let stop = min([last, start + 255])
        if line2byte(stop + 1) - line2byte(start) < 512 * (stop - start + 1)
          continue
        endif
        if first < start
          execute 'keeppatterns ' . first . ',' . (start - 1) . 's/\s\+$//e'
        endif
        for lnum in range(start, stop)
          let previous = getline(lnum)
          let trimmed = trim(previous, " \t", 2)
          " 不触碰未改变的行，避免空操作产生修改、撤销记录或 LSP 同步。
          if trimmed !=# previous
            call setline(lnum, trimmed)
          endif
        endfor
        let first = stop + 1
      endfor
    endif
    if first <= last
      execute 'keeppatterns ' . first . ',' . last . 's/\s\+$//e'
    endif
  finally
    " keeppatterns 已保留搜索；重写 @/ 反而会把向后搜索重置为向前。
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

" 选区全部为注释时取消注释，否则整体添加；空行保持原样。
function! s:ToggleComments(first, last) abort
  if !s:Editable()
    return
  endif
  let [prefix, suffix] = s:CommentStyle()
  let lines = getline(a:first, a:last)
  let tail = empty(suffix) ? '' : s:CommentToken(suffix, '^\s\+') . '\s*'
  " 由 Vim 的列表匹配找第一个非注释行，避免每行反复调用辅助函数和构造正则。
  let end = empty(suffix) ? '' : '\_.*' . tail . '$'
  let noncomment = '\C^\%(\s*$\|\s*\S\@=' . s:CommentStart(prefix) . end . '\)\@!'
  let commented = match(lines, noncomment) < 0
  if commented
    let body = empty(suffix) ? '\_.*' : '\_.\{-}'
    let pattern = '\C^\(\s*\)' . s:CommentToken(prefix, '\s\+$') . '\s\?\(' . body . '\)'
          \ . (empty(suffix) ? '' : '\s\?' . tail) . '$'
    let replacement = '\1\2'
  else
    let start = prefix . (prefix =~# '\s$' ? '' : ' ')
    let finish = empty(suffix) ? '' : (suffix =~# '^\s' ? '' : ' ') . suffix
    let pattern = '^\(\s*\)\(\S\_.*\)$'
    let replacement = '\1' . escape(start, '\&~') . '\2' . escape(finish, '\&~')
  endif
  let view = winsaveview()
  let search = @/
  " 按行调用原生 substitute：保留内嵌 NUL，不拼接全文，也不改写 :& 的替换记录。
  call map(lines, 'substitute(v:val, pattern, replacement, "")')
  call setline(a:first, lines)
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
