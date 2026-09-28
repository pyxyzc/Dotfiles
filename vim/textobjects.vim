" Lightweight structural text objects for the supported programming languages.

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim lite: ' . a:message
  echohl None
endfunction

function! s:Trimmed(lnum) abort
  return substitute(getline(a:lnum), '^\s\+', '', '')
endfunction

function! s:NextCodeLine(lnum) abort
  let line = a:lnum
  while line <= line('$')
    if s:Trimmed(line) !~# '^$'
      return line
    endif
    let line += 1
  endwhile
  return 0
endfunction

function! s:PythonKind(text) abort
  if a:text =~# '^\%(async\s\+\)\?def\>'
    return 'function'
  endif
  if a:text =~# '^class\>'
    return 'class'
  endif
  if a:text =~# '^\%(if\|elif\|else\|for\|while\|try\|except\|finally\|with\)\>'
    return 'block'
  endif
  return ''
endfunction

function! s:PythonDecoratedStart(lnum) abort
  let start = a:lnum
  while start > 1 && s:Trimmed(start - 1) =~# '^@\S'
    let start -= 1
  endwhile
  return start
endfunction

function! s:PythonBlockStart(lnum) abort
  let text = s:Trimmed(a:lnum)
  if text !~# '^\%(elif\|else\|except\|finally\)\>'
    return a:lnum
  endif
  let base = indent(a:lnum)
  let wanted = text =~# '^\%(elif\|else\)\>' ? 'if' : 'try'
  let line = a:lnum - 1
  while line > 0
    if s:Trimmed(line) !~# '^$'
      if indent(line) < base
        break
      endif
      if indent(line) == base
        let previous = s:Trimmed(line)
        if previous =~# '^' . wanted . '\>'
          return line
        endif
        if s:PythonKind(previous) !=# 'block'
          break
        endif
      endif
    endif
    let line -= 1
  endwhile
  return a:lnum
endfunction

function! s:PythonEnd(header, base) abort
  let line = a:header + 1
  while line <= line('$')
    if s:Trimmed(line) !~# '^$' && indent(line) <= a:base
      let end = line - 1
      while end > a:header && s:Trimmed(end) =~# '^$'
        let end -= 1
      endwhile
      return end
    endif
    let line += 1
  endwhile
  let end = line('$')
  while end > a:header && s:Trimmed(end) =~# '^$'
    let end -= 1
  endwhile
  return end
endfunction

function! s:PythonChainEnd(header, base) abort
  let end = s:PythonEnd(a:header, a:base)
  let next = s:NextCodeLine(end + 1)
  while next > 0 && indent(next) == a:base
    let text = s:Trimmed(next)
    if text !~# '^\%(elif\|else\|except\|finally\)\>'
      break
    endif
    let end = s:PythonEnd(next, a:base)
    let next = s:NextCodeLine(end + 1)
  endwhile
  return end
endfunction

function! s:PythonCandidate(header, kind) abort
  let text = s:Trimmed(a:header)
  let detected = s:PythonKind(text)
  if detected !=# a:kind
    return []
  endif
  let base = indent(a:header)
  let anchor = a:kind ==# 'block' ? s:PythonBlockStart(a:header)
        \ : a:header
  let start = a:kind ==# 'block' ? anchor
        \ : s:PythonDecoratedStart(a:header)
  let end = s:PythonChainEnd(anchor, base)
  let body = a:kind ==# 'block' ? a:header + 1 : s:NextCodeLine(a:header + 1)
  if body == 0
    let body = end + 1
  endif
  return [start, end, body, end]
endfunction

function! s:PythonObject(kind, cursor) abort
  " 从光标附近向上找包含它的最近定义；不遍历后面的所有函数。
  let header = a:cursor
  while header < line('$') && s:Trimmed(header) =~# '^@\S'
    let header += 1
  endwhile
  let lines = reverse(getline(1, header))
  let pattern = a:kind ==# 'function' ? '^\s*\%(async\s\+\)\?def\>'
        \ : a:kind ==# 'class' ? '^\s*class\>'
        \ : '^\s*\%(if\|elif\|else\|for\|while\|try\|except\|finally\|with\)\>'
  let offset = match(lines, pattern)
  while offset >= 0
    let start = header - offset
    if a:kind ==# 'block'
      let start = s:PythonBlockStart(start)
    endif
    let candidate = s:PythonCandidate(start, a:kind)
    if !empty(candidate) && candidate[0] <= a:cursor && a:cursor <= candidate[1]
      return candidate
    endif
    let offset = match(lines, pattern, header - start + 1)
  endwhile
  return []
endfunction

function! s:IsCodeChar(lnum, column) abort
  let id = synID(a:lnum, a:column + 1, 1)
  let group = synIDattr(id, 'name') . ' ' . synIDattr(synIDtrans(id), 'name')
  return group !~# '\%(Comment\|String\|Character\)'
endfunction

let s:code_skip = '!' . matchstr(string(function('s:IsCodeChar')), '<SNR>\d\+_IsCodeChar')
      \ . '(line("."), col(".") - 1)'

function! s:CBracePairs(cursor, kind) abort
  let pairs = []
  let view = winsaveview()
  let skip = s:code_skip
  try
    " 同行的块也允许选择；随后只沿包含光标的祖先括号向外查找。
    let text = getline(a:cursor)
    let column = match(text, '{')
    while column >= 0
      if s:IsCodeChar(a:cursor, column)
        call cursor(a:cursor, column + 1)
        let closing = searchpairpos('{', '', '}', 'nW', skip)
        if closing[0]
          call add(pairs, [a:cursor, column, closing[0], closing[1] - 1])
        endif
      endif
      let column = match(text, '{', column + 1)
    endwhile
    if !empty(filter(copy(pairs), 's:CBlockKind(s:CHeader(v:val)[1]) ==# a:kind'))
      return pairs
    endif
    call cursor(a:cursor, 1)
    while 1
      let opening = searchpairpos('{', '', '}', 'bW', skip)
      if !opening[0]
        break
      endif
      let closing = searchpairpos('{', '', '}', 'nW', skip)
      if closing[0] >= a:cursor
        let pair = [opening[0], opening[1] - 1, closing[0], closing[1] - 1]
        call add(pairs, pair)
        if s:CBlockKind(s:CHeader(pair)[1]) ==# a:kind
          break
        endif
      endif
    endwhile
  finally
    call winrestview(view)
  endtry
  return pairs
endfunction

function! s:CHeaderStart(open_line) abort
  let start = a:open_line
  let line = a:open_line
  while line > 1 && a:open_line - line < 30
    let previous = getline(line - 1)
    " 与 trim() 的默认空白一致，包含 U+00A0；旧 Vim 也可直接判断。
    if previous =~# '^[\x01-\x20 ]*$' || previous =~# '^\s*#'
          \ || previous =~# '^\s*\%(public\|private\|protected\):\s*$'
          \ || previous =~# '[;{}]\s*$'
      break
    endif
    let line -= 1
    let start = line
  endwhile
  return start
endfunction

function! s:CHeader(pair) abort
  let start = s:CHeaderStart(a:pair[0])
  let lines = getline(start, a:pair[0])
  let lines[-1] = strpart(lines[-1], 0, a:pair[1])
  return [start, join(lines, ' ')]
endfunction

function! s:CBlockKind(header) abort
  if a:header =~# '\<\%(if\|for\|while\|do\|switch\|try\|catch\|else\)\>'
    return 'block'
  endif
  if a:header =~# '\<\%(class\|struct\)\>'
    return 'class'
  endif
  if a:header =~# ')\s*\%(const\|noexcept\|override\|final\|mutable\|&\|&&\)\?\s*$'
    return 'function'
  endif
  return ''
endfunction

function! s:CObject(kind, cursor) abort
  let best = []
  for pair in s:CBracePairs(a:cursor, a:kind)
    if a:cursor < pair[0] || a:cursor > pair[2]
      continue
    endif
    let header = s:CHeader(pair)
    let detected = s:CBlockKind(header[1])
    if detected !=# a:kind
      continue
    endif
    let candidate = [header[0], pair[2], pair[0] + 1, pair[2] - 1]
    if empty(best) || candidate[1] - candidate[0] < best[1] - best[0]
      let best = candidate
    endif
  endfor
  return best
endfunction

function! s:Object(kind, cursor) abort
  if &filetype ==# 'python'
    return s:PythonObject(a:kind, a:cursor)
  endif
  return s:CObject(a:kind, a:cursor)
endfunction

function! s:Select(kind, inner) abort
  let object = s:Object(a:kind, line('.'))
  if empty(object)
    normal! gv
    call s:Warn('no matching ' . a:kind . ' block')
    return
  endif
  let first = a:inner ? object[2] : object[0]
  let last = a:inner ? object[3] : object[1]
  if first > last
    normal! gv
    call s:Warn('matching ' . a:kind . ' has no inner lines')
    return
  endif
  call setpos("'<", [0, first, 1, 0])
  call setpos("'>", [0, last, 1, 0])
  normal! gv
  normal! V
endfunction

function! s:Enable() abort
  xnoremap <silent><buffer> af :<C-u>call <SID>Select('function', 0)<CR>
  xnoremap <silent><buffer> if :<C-u>call <SID>Select('function', 1)<CR>
  xnoremap <silent><buffer> ac :<C-u>call <SID>Select('class', 0)<CR>
  xnoremap <silent><buffer> ic :<C-u>call <SID>Select('class', 1)<CR>
  xnoremap <silent><buffer> ab :<C-u>call <SID>Select('block', 0)<CR>
  xnoremap <silent><buffer> ib :<C-u>call <SID>Select('block', 1)<CR>
endfunction

augroup vimrc_lite_textobjects
  autocmd!
  autocmd FileType python,c,cpp,cuda call <SID>Enable()
augroup END
