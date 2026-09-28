" 自动单词补全分批扫描已加载的 buffer；原生 Ctrl-n/Ctrl-p 的完整扫描保持可用。
if exists('s:request') && has_key(s:request, 'timer')
  call timer_stop(s:request.timer)
endif
let s:request = {}
let s:presenting = 0
let s:dismissed = []
let s:context_key = []
let s:context = []

function! s:Cancel() abort
  if has_key(s:request, 'timer')
    call timer_stop(s:request.timer)
  endif
  let s:request = {}
endfunction

function! s:Context() abort
  let key = [bufnr('%'), line('.'), col('.'), b:changedtick, &l:iskeyword, &encoding]
  if key ==# s:context_key
    return s:context
  endif
  let text = getline('.')
  let end = min([strlen(text), key[2] - 1])
  let finish = end
  if &encoding ==# 'utf-8'
    " 从光标附近向后分段找词首，短前缀不必扫描整条巨型行。
    " 跨段长词保留完整字节范围，找到边界后只提取一次前缀。
    while end > 0
      let start = max([0, end - 4096])
      let chunk = strpart(text, start, end - start)
      let boundary = s:Boundary(chunk, 0)
      let start += boundary
      let chunk = strpart(chunk, boundary)
      let prefix = matchstr(chunk, '\k\+$')
      if strlen(prefix) < strlen(chunk) || start == 0
        let end -= strlen(prefix)
        break
      endif
      let end = start
    endwhile
    let prefix = strpart(text, end, finish - end)
  else
    " 非 UTF-8 编码不使用 UTF-8 字节边界修正，保持原生匹配语义。
    let prefix = matchstr(strpart(text, 0, end), '\k\+$')
  endif
  let s:context_key = key
  let s:context = key[0:2] + [prefix]
  return s:context
endfunction

function! s:Done() abort
  if s:presenting
    return
  endif
  let s:dismissed = s:Context()
  call s:Cancel()
endfunction

" UTF-8 字节窗口只在完整字符间切开；最多向后修正三个续字节。
function! s:Boundary(text, end) abort
  let end = min([strlen(a:text), a:end])
  while end < strlen(a:text)
    let byte = char2nr(strpart(a:text, end, 1))
    if byte < 128 || byte >= 192
      break
    endif
    let end += 1
  endwhile
  return end
endfunction

" 长行按 256 KiB 扫描；跨窗口候选只记录起点，找到词尾后一次提取完整单词。
function! s:LongMatch(request) abort
  let request = a:request
  let first = request.column
  let size = request.sizes[request.row]
  " Vimscript 字符串按值传递：每个窗口只截取一次全文，后续操作只传小片段。
  let offset = max([0, first - 4])
  let chunk = strpart(request.lines[request.row], offset,
        \ 262144 + strlen(request.context[3]) * 4 + 12)
  let begin = first - offset
  let end = s:Boundary(chunk, begin + 262144)
  if request.wordstart >= 0
    let request.column += matchend(strpart(chunk, begin, end - begin), '^\k*')
    if request.column < offset + end || offset + end == size
      let word = strpart(request.lines[request.row], request.wordstart,
            \ request.column - request.wordstart)
      let request.wordstart = -1
      return word
    endif
    return ''
  endif
  " 前一个字符保留 \< 的真实边界；额外前瞻覆盖跨窗的前缀及大小写字节长度差异。
  let before = matchstr(strpart(chunk, 0, begin), '\_.$')
  let limit = s:Boundary(chunk, end + strlen(request.context[3]) * 4)
  let text = before . strpart(chunk, begin, limit - begin)
  let found = matchstrpos(text, request.pattern)
  " 起点落在前一个字符的匹配已由前一窗口处理，不得把词中间误当词首。
  if found[1] >= 0 && found[1] < strlen(before)
    let found = matchstrpos(text, request.pattern, found[2])
  endif
  if found[1] < 0 || first + found[1] - strlen(before) >= offset + end
    let request.column = offset + end
    return ''
  endif
  let request.column = first + found[2] - strlen(before)
  if request.column == offset + limit && offset + limit < size
    let request.wordstart = first + found[1] - strlen(before)
    return ''
  endif
  return found[0]
endfunction

function! s:Scan(timer) abort
  if empty(s:request)
    return
  endif
  let request = s:request
  if mode(1) !~# '^i' || s:Context() !=# request.context || &paste || !&modifiable
        \ || (pumvisible() && complete_info(['selected']).selected >= 0)
    call s:Cancel()
    return
  endif
  let started = reltime()
  let previous = len(request.matches)
  while request.source < len(request.sources) && len(request.matches) < request.limit
        \ && reltimefloat(reltime(started)) < 0.003
    let source = request.sources[request.source]
    if !bufloaded(source.buf) || getbufvar(source.buf, 'changedtick') != source.tick
      let request.source += 1
      let request.lines = []
      continue
    endif
    if empty(request.lines)
      if source.next > source.last
        let request.source += 1
        continue
      endif
      let request.lines = getbufline(source.buf, source.next, min([source.next + 31, source.last]))
      let source.next += len(request.lines)
      let request.row = 0
      let request.column = 0
      let request.wordstart = -1
      let request.sizes = map(copy(request.lines), 'strlen(v:val)')
      let request.short = max(request.sizes) <= 8192
      if empty(request.lines)
        let request.source += 1
        continue
      endif
    endif
    " 短行块由原生列表匹配跳过不含候选的行；长行不能一次整行交给正则。
    if request.short && request.column == 0
      let request.row = match(request.lines, request.pattern, request.row)
      if request.row < 0
        let request.lines = []
        continue
      endif
    endif
    if request.sizes[request.row] > 8192
      let word = s:LongMatch(request)
      let exhausted = request.column >= request.sizes[request.row] && request.wordstart < 0
    else
      let found = matchstrpos(request.lines[request.row], request.pattern, request.column)
      let word = found[0]
      let request.column = found[2]
      let exhausted = found[1] < 0
    endif
    if exhausted
      let request.row += 1
      let request.column = 0
      if request.row == len(request.lines)
        let request.lines = []
      endif
    endif
    if !empty(word) && word !=# request.context[3] && !has_key(request.seen, word)
      let request.seen[word] = 1
      " 只缩短菜单标签；插入的 word 保持完整，避免超长词拖慢菜单布局。
      call add(request.matches, strlen(word) > 120
            \ ? {'word': word, 'abbr': strcharpart(word, 0, 80) . '…'} : word)
    endif
  endwhile
  if len(request.matches) > previous
    let s:presenting = 1
    try
      call complete(request.context[2] - strlen(request.context[3]), request.matches)
    finally
      let s:presenting = 0
    endtry
    " complete() 可能修改 changedtick；当前 buffer 的文本没有被选中补全项替换。
    for source in request.sources
      if source.buf == bufnr('%')
        let source.tick = b:changedtick
      endif
    endfor
  endif
  if request.source < len(request.sources) && len(request.matches) < request.limit
    let request.timer = timer_start(1, function('s:Scan'))
  else
    " 菜单展开期间只保留候选，不持续引用扫描用的文本块。
    let request.lines = []
    let request.sources = []
  endif
endfunction

function! s:Changed() abort
  if mode(1) !~# '^i' || &paste || &buftype !=# '' || !&modifiable
        \ || get(b:, 'vimrc_lite_large_file', 0)
    return
  endif
  " 手动关键词/LSP 补全由其自身管理；用户正在挑选候选项时也不重置菜单。
  if pumvisible() && (empty(s:request) || complete_info(['selected']).selected >= 0)
    return
  endif
  let context = s:Context()
  if strchars(context[3]) < 2 || context ==# s:dismissed
    call s:Cancel()
    return
  endif
  if !empty(s:request) && context ==# s:request.context
    return
  endif
  call s:Cancel()
  if !has('timers') || !exists('*matchstrpos') || !exists('*complete_info')
    call feedkeys("\<C-n>", 'n')
    return
  endif
  let sources = [{'buf': bufnr('%'), 'tick': b:changedtick, 'next': line('.'), 'last': line('$')},
        \ {'buf': bufnr('%'), 'tick': b:changedtick, 'next': 1, 'last': line('.') - 1}]
  for buffer in getbufinfo({'bufloaded': 1})
    if buffer.bufnr != bufnr('%') && (buffer.listed || !empty(buffer.windows))
          \ && getbufvar(buffer.bufnr, '&buftype') ==# ''
      call add(sources, {'buf': buffer.bufnr, 'tick': buffer.changedtick,
            \ 'next': 1, 'last': buffer.linecount})
    endif
  endfor
  let ignorecase = &ignorecase && (!&smartcase || context[3] !~# '\u')
  let s:request = {'context': context, 'sources': sources, 'source': 0, 'lines': [],
        \ 'matches': [], 'seen': {}, 'limit': max([1, get(g:, 'vimrc_lite_completion_max', 100)]),
        \ 'pattern': (ignorecase ? '\c' : '\C') . '\<\V' . escape(context[3], '\') . '\m\k*'}
  let s:request.timer = timer_start(0, function('s:Scan'))
endfunction

augroup vimrc_lite_completion
  autocmd!
  autocmd TextChangedI * call <SID>Changed()
  if exists('##TextChangedP')
    autocmd TextChangedP * call <SID>Changed()
  endif
  autocmd CompleteDone * call <SID>Done()
  autocmd InsertLeave,BufLeave * call <SID>Cancel()
augroup END
