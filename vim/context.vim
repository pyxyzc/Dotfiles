" 顶部上下文：LSP 符号按 buffer 缓存，弹层按窗口管理。
" 重载先释放旧请求、计时器与弹层；不修改源文件或窗口布局。
if exists('s:cache')
  call s:Reset()
endif
let s:cache = {}
let s:windows = {}
let s:delays = {}
let s:refresh = -1
let s:supported = exists('*popup_create') && exists('*win_execute')
      \ && exists('*screenpos') && has('timers')

function! s:Enabled() abort
  return s:supported && get(g:, 'vimrc_lite_context', 1)
        \ && get(g:, 'vimrc_lite_lsp', 1)
endfunction

function! s:Eligible(buffer) abort
  return s:Enabled() && bufloaded(a:buffer)
        \ && getbufvar(a:buffer, '&buftype') ==# '' && !empty(bufname(a:buffer))
        \ && index(['python', 'c', 'cpp'], getbufvar(a:buffer, '&filetype')) >= 0
        \ && !getbufvar(a:buffer, 'vimrc_lite_large_file', 0)
endfunction

function! s:Server(buffer) abort
  if !s:Eligible(a:buffer) || !exists('*lsp#get_allowed_servers')
    return ''
  endif
  let servers = sort(filter(lsp#get_allowed_servers(a:buffer),
        \ 'lsp#get_server_status(v:val) ==# "running"'
        \ . ' && lsp#capabilities#has_document_symbol_provider(v:val)'))
  for name in values(getbufvar(a:buffer, 'vimrc_lite_lsp_binding', {}))
    if index(servers, name) >= 0
      return name
    endif
  endfor
  return empty(servers) ? '' : servers[0]
endfunction

function! s:Valid(state) abort
  return get(s:cache, a:state.buffer, {}) is a:state
        \ && s:Eligible(a:state.buffer)
        \ && getbufvar(a:state.buffer, 'changedtick') == a:state.tick
        \ && lsp#utils#get_buffer_uri(a:state.buffer) ==# a:state.uri
        \ && s:Server(a:state.buffer) ==# a:state.server
        \ && get(lsp#get_server_info(a:state.server), 'vimrc_generation', 0)
        \ == a:state.generation
endfunction

function! s:Cancel(state) abort
  call timer_stop(a:state.timeout)
  let a:state.timeout = -1
  let request = a:state.request
  let a:state.request = {}
  if !empty(request)
    call lsp#cancel_request(request.ctx)
    if has_key(request, 'dispose')
      call request.dispose()
    endif
  endif
endfunction

function! s:CloseWindow(window) abort
  if has_key(s:windows, a:window)
    let display = remove(s:windows, a:window)
    if !empty(popup_getpos(display.popup))
      call popup_close(display.popup)
    endif
  endif
endfunction

function! s:Forget(buffer) abort
  if has_key(s:delays, a:buffer)
    call timer_stop(remove(s:delays, a:buffer))
  endif
  if has_key(s:cache, a:buffer)
    call s:Cancel(remove(s:cache, a:buffer))
  endif
  for [window, display] in items(copy(s:windows))
    if display.buffer == a:buffer
      call s:CloseWindow(window)
    endif
  endfor
endfunction

function! s:Reset() abort
  if !exists('*timer_stop')
    return
  endif
  call timer_stop(s:refresh)
  let s:refresh = -1
  for buffer in keys(copy(s:delays)) + keys(copy(s:cache))
    call s:Forget(buffer)
  endfor
  for window in keys(copy(s:windows))
    call s:CloseWindow(window)
  endfor
endfunction

function! s:Before(first, second) abort
  return a:first[0] < a:second[0]
        \ || (a:first[0] == a:second[0] && a:first[1] < a:second[1])
endfunction

function! s:Position(position) abort
  if type(a:position) != v:t_dict
        \ || type(get(a:position, 'line', '')) != v:t_number
        \ || type(get(a:position, 'character', '')) != v:t_number
        \ || a:position.line < 0 || a:position.character < 0
    return []
  endif
  return [a:position.line, a:position.character]
endfunction

function! s:Order(left, right) abort
  return s:Before(a:left.start, a:right.start) ? -1
        \ : s:Before(a:right.start, a:left.start) ? 1 : 0
endfunction

function! s:Tree(symbols) abort
  let nodes = []
  if type(a:symbols) != v:t_list
    return nodes
  endif
  for symbol in a:symbols
    if type(symbol) != v:t_dict || type(get(symbol, 'range', 0)) != v:t_dict
          \ || type(get(symbol, 'selectionRange', 0)) != v:t_dict
      " 平面 SymbolInformation 通常只给名称位置，不能据此推断函数体。
      continue
    endif
    let start = s:Position(get(symbol.range, 'start', {}))
    let end = s:Position(get(symbol.range, 'end', {}))
    let name = s:Position(get(symbol.selectionRange, 'start', {}))
    if empty(start) || empty(end) || empty(name) || !s:Before(start, end)
          \ || s:Before(name, start) || !s:Before(name, end)
      continue
    endif
    call add(nodes, {'start': start, 'end': end, 'name': name,
          \ 'kind': get(symbol, 'kind', 0), 'header': v:null,
          \ 'children': s:Tree(get(symbol, 'children', []))})
  endfor
  return sort(nodes, function('s:Order'))
endfunction

function! s:Result(state, data) abort
  if !s:Valid(a:state)
    if get(s:cache, a:state.buffer, {}) is a:state
      call s:Changed(a:state.buffer)
    endif
    return
  endif
  call s:Cancel(a:state)
  let a:state.done = 1
  let response = get(a:data, 'response', {})
  if !has_key(response, 'error')
    try
      let a:state.tree = s:Tree(get(response, 'result', []))
    catch
      let a:state.tree = []
    endtry
  endif
  call s:Queue()
endfunction

function! s:Timeout(state, timer) abort
  if get(s:cache, a:state.buffer, {}) is a:state
    call s:Cancel(a:state)
    let a:state.done = 1
  endif
endfunction

function! s:Start(state) abort
  let request = lsp#request_with_context(a:state.server,
        \ {'method': 'textDocument/documentSymbol', 'bufnr': a:state.buffer,
        \ 'params': {'textDocument': {'uri': a:state.uri}}})
  let a:state.request = request
  let a:state.timeout = timer_start(max([1,
        \ get(g:, 'vimrc_lite_lsp_request_timeout_ms', 10000)]),
        \ function('s:Timeout', [a:state]))
  let request.dispose = lsp#callbag#pipe(request.callbag,
        \ lsp#callbag#subscribe({'next': function('s:Result', [a:state]),
        \ 'error': function('s:Result', [a:state])}))
  if empty(a:state.request)
    call request.dispose()
  endif
endfunction

function! s:Ready(buffer, timer) abort
  if get(s:delays, a:buffer, -1) == a:timer
    call remove(s:delays, a:buffer)
    call s:Queue()
  endif
endfunction

function! s:Changed(buffer) abort
  call s:Forget(a:buffer)
  if s:Eligible(a:buffer)
    let s:delays[a:buffer] = timer_start(150, function('s:Ready', [a:buffer]))
  endif
endfunction

function! s:State(buffer) abort
  if has_key(s:cache, a:buffer)
    let state = s:cache[a:buffer]
    if s:Valid(state)
      return state
    endif
    if getbufvar(a:buffer, 'changedtick') != state.tick
      call s:Changed(a:buffer)
    else
      call s:Forget(a:buffer)
    endif
  endif
  let server = s:Server(a:buffer)
  if empty(server) || has_key(s:delays, a:buffer)
    return {}
  endif
  let state = {'buffer': a:buffer, 'server': server,
        \ 'generation': get(lsp#get_server_info(server), 'vimrc_generation', 0),
        \ 'uri': lsp#utils#get_buffer_uri(a:buffer),
        \ 'tick': getbufvar(a:buffer, 'changedtick'),
        \ 'tree': [], 'done': 0, 'request': {}, 'timeout': -1}
  let s:cache[a:buffer] = state
  call s:Start(state)
  return state
endfunction

function! s:Scopes(nodes, position) abort
  " 有序兄弟节点二分定位；移动光标时不遍历整份文件的符号。
  let low = 0
  let high = len(a:nodes)
  while low < high
    let middle = (low + high) / 2
    if s:Before(a:position, a:nodes[middle].start)
      let high = middle
    else
      let low = middle + 1
    endif
  endwhile
  if low == 0 || !s:Before(a:position, a:nodes[low - 1].end)
    return []
  endif
  let node = a:nodes[low - 1]
  let scopes = index([5, 6, 9, 12, 23], node.kind) >= 0 ? [node] : []
  return scopes + s:Scopes(node.children, a:position)
endfunction

function! s:Header(node) abort
  if a:node.header isnot v:null
    return a:node.header
  endif
  " 只扫描需要展示的签名，并限制长度；跳过字符串和注释中的分隔符。
  let lines = getbufline(bufnr('%'), a:node.name[0] + 1,
        \ min([a:node.end[0] + 1, a:node.name[0] + 20]))
  let python = &filetype ==# 'python'
  let depth = 0
  let quote = ''
  let escaped = 0
  let comment = 0
  let parts = []
  let length = 0
  let finished = 0
  for line in lines
    let part = ''
    let index = 0
    while index < strlen(line) && length < 4096
      let char = matchstr(strpart(line, index), '^.')
      let next = strpart(line, index, 2)
      if comment
        if next ==# '*/'
          let comment = 0
          let index += 2
          let part .= ' '
          continue
        endif
      elseif !empty(quote)
        let part .= char
        if escaped
          let escaped = 0
        elseif char ==# '\'
          let escaped = 1
        elseif char ==# quote
          let quote = ''
        endif
      elseif (python && char ==# '#') || (!python && next ==# '//')
        break
      elseif !python && next ==# '/*'
        let comment = 1
        let index += 2
        continue
      elseif char ==# '"' || char ==# "'"
        let quote = char
        let part .= char
      elseif depth == 0 && ((python && char ==# ':')
            \ || (!python && (char ==# '{' || char ==# ';'
            \ || (char ==# ':' && next !=# '::' && strpart(line, index - 1, 1) !=# ':'))))
        " C++ 构造函数的初始化列表不属于需要吸附的签名。
        let part .= char ==# ':' && python ? ':' : char ==# '{' ? '{' : ''
        let finished = 1
        break
      else
        if char ==# '(' || char ==# '[' || char ==# '{'
          let depth += 1
        elseif char ==# ')' || char ==# ']' || char ==# '}'
          let depth = max([0, depth - 1])
        endif
        let part .= char
      endif
      let index += strlen(char)
      let length += strlen(char)
    endwhile
    call add(parts, substitute(substitute(part, '^\s\+', '', ''), '\s\+$', '', ''))
    if finished || length >= 4096
      break
    endif
  endfor
  let indent = empty(lines) ? '' : repeat(' ', strdisplaywidth(matchstr(lines[0], '^\s*')))
  let a:node.header = indent . join(filter(parts, '!empty(v:val)'), ' ')
        \ . (finished ? '' : ' …')
  return a:node.header
endfunction

function! s:Clip(text, width) abort
  if strdisplaywidth(a:text) <= a:width
    return a:text
  endif
  let low = 0
  let high = strchars(a:text)
  while low < high
    let middle = (low + high + 1) / 2
    if strdisplaywidth(strcharpart(a:text, 0, middle)) <= a:width - 1
      let low = middle
    else
      let high = middle - 1
    endif
  endwhile
  return strcharpart(a:text, 0, low) . '…'
endfunction

function! s:Visible(window, node, height) abort
  let line = a:node.name[0] + 1
  let folded = foldclosed(line)
  if folded >= 0 && folded != line
    return 0
  endif
  let column = lsp#utils#position#lsp_character_to_vim(bufnr('%'),
        \ {'line': a:node.name[0], 'character': a:node.name[1]})
  let position = screenpos(a:window.winid, line, column)
  return position.row >= a:window.winrow + a:height && position.col > 0
        \ && position.row < a:window.winrow + a:window.height
endfunction

function! s:Render(window) abort
  let info = getwininfo(a:window)
  if empty(info)
    return
  endif
  let window = info[0]
  let state = s:State(window.bufnr)
  if empty(state) || !state.done
    call s:CloseWindow(a:window)
    return
  endif
  let cursor = screenpos(a:window, line('.'), col('.'))
  let capacity = min([max([0, get(g:, 'vimrc_lite_context_max_lines', 3)]),
        \ cursor.row - window.winrow, window.height - 1])
  if capacity <= 0 || window.width <= window.textoff + 4
    call s:CloseWindow(a:window)
    return
  endif
  let position = lsp#utils#position#vim_to_lsp(window.bufnr, [line('.'), col('.')])
  let scopes = s:Scopes(state.tree, [position.line, position.character])
  let height = 0
  " 将弹层遮住的定义一起吸附，直到高度稳定，避免边界处来回闪烁。
  for iteration in range(capacity + 1)
    let hidden = filter(copy(scopes), '!s:Visible(window, v:val, height)')
    let hidden = len(hidden) > capacity ? hidden[-capacity :] : hidden
    if len(hidden) == height
      break
    endif
    let height = len(hidden)
  endfor
  if empty(hidden)
    call s:CloseWindow(a:window)
    return
  endif
  let lines = map(hidden, 's:Clip(repeat(" ", window.textoff) . s:Header(v:val), window.width)')
  let options = {'line': window.winrow, 'col': window.wincol,
        \ 'minwidth': window.width, 'maxwidth': window.width,
        \ 'minheight': height, 'maxheight': height, 'wrap': 0, 'fixed': 1,
        \ 'posinvert': 0, 'scrollbar': 0, 'mapping': 0, 'zindex': 10,
        \ 'padding': [0, 0, 0, 0], 'border': [0, 0, 0, 0], 'highlight': 'VimContextHeader'}
  let display = get(s:windows, a:window, {})
  if empty(display) || empty(popup_getpos(display.popup))
    let popup = popup_create(lines, options)
    call setbufvar(winbufnr(popup), 'vimrc_lite_context_popup', a:window)
    let s:windows[a:window] = {'popup': popup, 'buffer': window.bufnr,
          \ 'lines': lines, 'options': options}
  else
    if display.lines !=# lines
      call popup_settext(display.popup, lines)
      let display.lines = lines
    endif
    if display.options !=# options
      call popup_setoptions(display.popup, options)
      let display.options = options
    endif
  endif
endfunction

function! s:Update(timer) abort
  let s:refresh = -1
  let visible = {}
  for window in getwininfo()
    if window.tabnr == tabpagenr() && s:Eligible(window.bufnr)
      let visible[window.winid] = 1
      call win_execute(window.winid, 'noautocmd call ' . expand('<SID>')
            \ . 'Render(' . window.winid . ')')
    endif
  endfor
  for window in keys(copy(s:windows))
    if !has_key(visible, window)
      call s:CloseWindow(window)
    endif
  endfor
endfunction

function! s:Queue() abort
  if s:Enabled() && s:refresh == -1
    let s:refresh = timer_start(0, function('s:Update'))
  endif
endfunction

function! s:ServerChanged() abort
  call s:Reset()
  call s:Queue()
endfunction

function! s:Toggle() abort
  let g:vimrc_lite_context = !get(g:, 'vimrc_lite_context', 1)
  call s:Reset()
  call s:Queue()
endfunction

function! s:Highlights() abort
  highlight default link VimContextHeader Pmenu
endfunction

command! VimContextToggle call <SID>Toggle()
augroup vimrc_lite_context
  autocmd!
  autocmd BufEnter,BufWinEnter,WinEnter,TabEnter,CursorMoved,CursorMovedI * call s:Queue()
  autocmd VimEnter,VimResized,InsertLeave,CursorHold,CursorHoldI * call s:Queue()
  autocmd TextChanged,TextChangedI * call s:Changed(bufnr('%'))
  autocmd BufUnload,BufWipeout,BufFilePre,FileType * call s:Forget(str2nr(expand('<abuf>')))
  autocmd BufFilePost,FileType * call s:Queue()
  autocmd User lsp_server_init,lsp_server_exit call s:ServerChanged()
  autocmd User lsp_buffer_enabled call s:Queue()
  autocmd ColorScheme * call s:Highlights()
  autocmd VimLeavePre * call s:Reset()
  if exists('##TextChangedP')
    autocmd TextChangedP * call s:Changed(bufnr('%'))
  endif
  if exists('##WinScrolled')
    autocmd WinScrolled * call s:Queue()
  endif
  if exists('##WinClosed')
    autocmd WinClosed * call s:CloseWindow(str2nr(expand('<amatch>')))
  endif
augroup END
call s:Highlights()
call s:Queue()
