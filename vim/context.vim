" 状态栏上下文：LSP 符号按 buffer 缓存，名称按窗口光标位置查询。
" 移动光标不启动请求或计时器；状态栏沿用 Vim 的原生重绘。
if exists('s:cache')
  call s:Reset()
endif
" 安装副本与仓库文件的脚本 ID 不同，重载时也取消前一个模块的在途请求。
if exists(':VimContextToggle') == 2
  let s:previous = matchstr(execute('command VimContextToggle'), '<SNR>\d\+_\zeToggle()')
  if !empty(s:previous) && exists('*' . s:previous . 'Reset')
    call call(function(s:previous . 'Reset'), [])
  endif
endif
let s:cache = {}
let s:delays = {}
let s:refresh = -1
let s:supported = has('timers')

" 从旧配置切换时仅清理遗留上下文浮窗；后续运行不创建任何浮窗。
if exists('*popup_list')
  for s:popup in popup_list()
    if getbufvar(winbufnr(s:popup), 'vimrc_lite_context_popup', 0)
      call popup_close(s:popup)
    endif
  endfor
endif

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
  call timer_stop(get(a:state, 'compile_timer', -1))
  let a:state.compile_timer = -1
  let a:state.build = {}
  let request = a:state.request
  let a:state.request = {}
  if !empty(request)
    call lsp#cancel_request(request.ctx)
    if has_key(request, 'dispose')
      call request.dispose()
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

function! s:Result(state, data) abort
  if !s:Valid(a:state)
    if get(s:cache, a:state.buffer, {}) is a:state
      call s:Changed(a:state.buffer)
    endif
    return
  endif
  call s:Cancel(a:state)
  let response = get(a:data, 'response', {})
  let symbols = get(response, 'result', [])
  if has_key(response, 'error') || type(symbols) != type([]) || empty(symbols)
    let a:state.done = 1
    call s:Queue()
    return
  endif
  let a:state.build = {'phase': 'tree', 'stack': [s:Frame(symbols, '')]}
  call s:Compile(a:state, -1)
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
        \ 'regions': [], 'done': 0, 'request': {}, 'timeout': -1,
        \ 'compile_timer': -1, 'build': {}}
  let s:cache[a:buffer] = state
  call s:Start(state)
  return state
endfunction

" 仅在作用域边界所在行比较列号；同一行沿用上次的 UTF-16 列，仅转换移动的片段。
function! s:Character(position, cached) abort
  let point = get(a:cached, 'point', {})
  let row = a:position[0]
  let column = a:position[1] - 1
  if get(point, 'row', -1) != row
    let point = {'row': row, 'column': 0, 'units': 0, 'text': getline(row)}
    let a:cached.point = point
  endif
  let distance = column - point.column
  if distance != 0
    let text = strpart(point.text, min([column, point.column]), abs(distance))
    let units = lsp#utils#utf16#length(text)
    let point.units += distance > 0 ? units : -units
    let point.column = column
  endif
  return point.units
endfunction

" 将层级符号一次转换为名称不变的连续区间；相同名称的相邻区间合并。
function! s:AddRegion(regions, first, last, label) abort
  if !s:Before(a:first, a:last)
    return
  endif
  if !empty(a:regions) && a:regions[-1].label ==# a:label
        \ && a:regions[-1].last == a:first
    let a:regions[-1].last = a:last
  else
    call add(a:regions, {'first': a:first, 'last': a:last, 'label': a:label})
  endif
endfunction

function! s:Frame(symbols, label) abort
  return {'symbols': a:symbols, 'label': a:label, 'nodes': [], 'index': 0, 'ordered': 1}
endfunction

function! s:AddNode(frame, node) abort
  if a:node.label !=# a:frame.label || !empty(a:node.children)
    if !empty(a:frame.nodes) && s:Before(a:node.start, a:frame.nodes[-1].start)
      let a:frame.ordered = 0
    endif
    call add(a:frame.nodes, a:node)
  endif
endfunction

" 非源码顺序的结果用原生字符串排序；键的准备与还原也分批，不在比较器内调用 Vimscript。
function! s:SortStep(frame) abort
  if !has_key(a:frame, 'keys')
    let a:frame.keys = []
    let a:frame.sort_index = 0
  endif
  if a:frame.sort_index < len(a:frame.nodes)
    let point = a:frame.nodes[a:frame.sort_index].start
    call add(a:frame.keys, printf('%020d:%020d:%020d', point[0], point[1], a:frame.sort_index))
    let a:frame.sort_index += 1
  elseif !has_key(a:frame, 'sorted_nodes')
    call sort(a:frame.keys)
    let a:frame.sorted_nodes = []
  elseif len(a:frame.sorted_nodes) < len(a:frame.keys)
    let key = a:frame.keys[len(a:frame.sorted_nodes)]
    call add(a:frame.sorted_nodes, a:frame.nodes[str2nr(strpart(key, 42))])
  else
    let a:frame.nodes = a:frame.sorted_nodes
    let a:frame.ordered = 1
    unlet a:frame.keys a:frame.sorted_nodes
  endif
endfunction

function! s:TreeStep(state) abort
  let stack = a:state.build.stack
  let frame = stack[-1]
  if frame.index >= len(frame.symbols)
    if !frame.ordered
      call s:SortStep(frame)
      return
    endif
    call remove(stack, -1)
    if !empty(stack)
      let parent = stack[-1]
      let node = remove(parent, 'pending')
      let node.children = frame.nodes
      call s:AddNode(parent, node)
    else
      let a:state.build.phase = 'regions'
      call add(stack, {'nodes': frame.nodes, 'index': 0, 'position': [-1, 0],
            \ 'last': [0x7fffffff, 0], 'label': ''})
    endif
    return
  endif
  let symbol = frame.symbols[frame.index]
  let frame.index += 1
  if type(symbol) != type({})
    return
  endif
  let kind = get(symbol, 'kind', 0)
  let supported = index([5, 6, 9, 12, 23], kind) >= 0
  let children = get(symbol, 'children', [])
  if type(children) != type([])
    let children = []
  endif
  if (!supported && empty(children)) || type(get(symbol, 'range', 0)) != type({})
        \ || type(get(symbol, 'selectionRange', 0)) != type({})
    return
  endif
  let start = s:Position(get(symbol.range, 'start', {}))
  let end = s:Position(get(symbol.range, 'end', {}))
  let selection = s:Position(get(symbol.selectionRange, 'start', {}))
  let name = get(symbol, 'name', '')
  if empty(start) || empty(end) || empty(selection) || !s:Before(start, end)
        \ || s:Before(selection, start) || !s:Before(selection, end)
        \ || type(name) != type('') || empty(name)
    return
  endif
  let label = frame.label . (supported ? ':' . strtrans(name) : '')
  let node = {'start': start, 'end': end, 'label': label, 'children': []}
  if empty(children)
    call s:AddNode(frame, node)
  else
    let frame.pending = node
    call add(stack, s:Frame(children, label))
  endif
endfunction

function! s:RegionStep(state) abort
  let stack = a:state.build.stack
  let frame = stack[-1]
  if frame.index >= len(frame.nodes) || !s:Before(frame.position, frame.last)
    call s:AddRegion(a:state.regions, frame.position, frame.last, frame.label)
    call remove(stack, -1)
    let a:state.done = empty(stack)
    return
  endif
  let node = frame.nodes[frame.index]
  let frame.index += 1
  let first = s:Before(frame.position, node.start) ? node.start : frame.position
  let last = s:Before(node.end, frame.last) ? node.end : frame.last
  if !s:Before(first, last)
    return
  endif
  call s:AddRegion(a:state.regions, frame.position, first, frame.label)
  if empty(node.children)
    call s:AddRegion(a:state.regions, first, last, node.label)
  else
    call add(stack, {'nodes': node.children, 'index': 0, 'position': first,
          \ 'last': last, 'label': node.label})
  endif
  let frame.position = last
endfunction

" 每批约 4 ms，最多每 16 项检查一次时钟；编译期间允许处理按键与文档变化。
function! s:Compile(state, timer) abort
  let a:state.compile_timer = -1
  if !s:Valid(a:state)
    if get(s:cache, a:state.buffer, {}) is a:state
      call s:Changed(a:state.buffer)
    endif
    return
  endif
  let started = reltime()
  let steps = 0
  try
    while !a:state.done
      if a:state.build.phase ==# 'tree'
        call s:TreeStep(a:state)
      else
        call s:RegionStep(a:state)
      endif
      let steps += 1
      if steps % 16 == 0 && reltimefloat(reltime(started)) >= 0.004
        break
      endif
    endwhile
  catch
    let a:state.regions = []
    let a:state.done = 1
  endtry
  if a:state.done
    let a:state.build = {}
    call s:Queue()
  else
    let a:state.compile_timer = timer_start(0, function('s:Compile', [a:state]))
  endif
endfunction

function! s:Lookup(regions, position, cached) abort
  let row = a:position[0] - 1
  let character = -1
  let low = 0
  let high = len(a:regions)
  while low < high
    let middle = (low + high) / 2
    let bound = a:regions[middle].first
    if row == bound[0] && character < 0
      let character = s:Character(a:position, a:cached)
    endif
    if row < bound[0] || (row == bound[0] && character < bound[1])
      let high = middle
    else
      let low = middle + 1
    endif
  endwhile
  let region = a:regions[low - 1]
  let a:cached.first = region.first
  let a:cached.last = region.last
  let a:cached.label = region.label
endfunction

" 只读取已完成的符号缓存；%{} 结果是文字，名称中的 % 不作为状态栏格式执行。
function! VimContextLabel() abort
  if !s:Enabled() || &buftype !=# '' || get(b:, 'vimrc_lite_large_file', 0)
    return ''
  endif
  let state = get(s:cache, bufnr('%'), {})
  if empty(state) || !state.done || empty(state.regions) || state.tick != b:changedtick
    return ''
  endif
  let position = [line('.'), col('.')]
  let cached = get(w:, 'vimrc_lite_context_label', {})
  if get(cached, 'state', {}) isnot state
    let cached = {'state': state}
    let w:vimrc_lite_context_label = cached
  elseif cached.position == position
    return cached.label
  else
    let row = position[0] - 1
    if row >= cached.first[0] && row <= cached.last[0]
      if row > cached.first[0] && row < cached.last[0]
        let cached.position = position
        return cached.label
      endif
      let character = s:Character(position, cached)
      if (row > cached.first[0] || character >= cached.first[1])
            \ && (row < cached.last[0] || character < cached.last[1])
        let cached.position = position
        return cached.label
      endif
    endif
  endif
  call s:Lookup(state.regions, position, cached)
  let cached.position = position
  return cached.label
endfunction

" 请求只由进入窗口、文档变化及服务器事件排队，同一 buffer 的分屏共享一次请求。
function! s:Update(timer) abort
  let s:refresh = -1
  let seen = {}
  for window in getwininfo()
    if window.tabnr == tabpagenr() && !has_key(seen, window.bufnr)
          \ && s:Eligible(window.bufnr)
      let seen[window.bufnr] = 1
      call s:State(window.bufnr)
    endif
  endfor
  redrawstatus
endfunction

function! s:Queue() abort
  if s:Enabled() && s:refresh == -1
    let s:refresh = timer_start(0, function('s:Update'))
  endif
endfunction

function! s:ServerChanged() abort
  " 一个项目的服务器变化不清空其他项目的符号缓存。
  for [buffer, state] in items(copy(s:cache))
    if !s:Valid(state)
      call s:Forget(buffer)
    endif
  endfor
  call s:Queue()
  redrawstatus
endfunction

function! s:Toggle() abort
  let g:vimrc_lite_context = !get(g:, 'vimrc_lite_context', 1)
  call s:Reset()
  call s:Queue()
  redrawstatus
endfunction

command! VimContextToggle call <SID>Toggle()
augroup vimrc_lite_context
  autocmd!
  autocmd BufEnter,BufWinEnter,WinEnter,TabEnter * call s:Queue()
  autocmd VimEnter,InsertLeave * call s:Queue()
  autocmd TextChanged,TextChangedI * call s:Changed(bufnr('%'))
  autocmd BufUnload,BufWipeout,BufFilePre,FileType * call s:Forget(str2nr(expand('<abuf>')))
  autocmd BufFilePost,FileType * call s:Queue()
  autocmd User lsp_server_init,lsp_server_exit call s:ServerChanged()
  autocmd User lsp_buffer_enabled call s:Queue()
  autocmd VimLeavePre * call s:Reset()
  if exists('##TextChangedP')
    autocmd TextChangedP * call s:Changed(bufnr('%'))
  endif
augroup END
call s:Queue()
