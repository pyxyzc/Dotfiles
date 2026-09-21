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
  let best = []
  for line in range(1, line('$'))
    let candidate = s:PythonCandidate(line, a:kind)
    if empty(candidate) || a:cursor < candidate[0] || a:cursor > candidate[1]
      continue
    endif
    if empty(best) || candidate[1] - candidate[0] < best[1] - best[0]
      let best = candidate
    endif
  endfor
  return best
endfunction

function! s:IsCodeChar(lnum, column) abort
  let id = synIDtrans(synID(a:lnum, a:column + 1, 1))
  let group = synIDattr(id, 'name')
  return group !~# '\%(Comment\|String\|Character\)'
endfunction

function! s:CBracePairs() abort
  let pairs = []
  let stack = []
  for line in range(1, line('$'))
    let text = getline(line)
    if empty(text)
      continue
    endif
    for column in range(0, strlen(text) - 1)
      let character = strpart(text, column, 1)
      if !s:IsCodeChar(line, column)
        continue
      endif
      if character ==# '{'
        call add(stack, [line, column])
      elseif character ==# '}' && !empty(stack)
        let opening = remove(stack, -1)
        call add(pairs, [opening[0], opening[1], line, column])
      endif
    endfor
  endfor
  return pairs
endfunction

function! s:CHeaderStart(open_line) abort
  let start = a:open_line
  let line = a:open_line
  while line > 1 && a:open_line - line < 30
    let previous = getline(line - 1)
    if empty(trim(previous)) || previous =~# '^\s*#'
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
  for pair in s:CBracePairs()
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
