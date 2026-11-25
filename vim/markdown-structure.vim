" 分批建立块状态与标题索引。修改监听只记录最早失效行，不读取全文。
let s:stride = 32

function! s:Empty() abort
  return {'fence': '', 'comment': 0, 'yaml': 0, 'quote': 0, 'indent': 0, 'lists': []}
endfunction

" 单行扫描仅检查有结构意义的前缀；注释结束位置使用原生字符串查找。
function! s:Step(text, state, lnum) abort
  let state = copy(a:state)
  let text = a:text
  if a:lnum == 1 && text ==# '---'
    let state.yaml = 1
    return [state, 1]
  endif
  if state.yaml
    if text =~# '^\%(---\|\.\.\.\)\s*$'
      let state.yaml = 0
    endif
    return [state, 1]
  endif
  let quoted = matchstr(strpart(text, 0, 256), '^ \{0,3}\%(>[ \t]\?\)\+')
  let quote = strlen(substitute(quoted, '[^>]', '', 'g'))
  let text = strpart(text, strlen(quoted))
  let indentation = matchend(strpart(text, 0, 256), '^ *')
  if !empty(state.fence) && (quote < state.quote
        \ || state.indent > indentation && text =~# '\S')
    let state.fence = ''
  endif
  if !empty(state.fence) && state.indent > 0
    let text = strpart(text, min([state.indent, indentation]))
  endif
  let prefix = strpart(text, 0, 256)
  let marker = matchstr(prefix, '^ \{0,3}\zs\%(`\{3,}\|\~\{3,}\)')
  if !empty(state.fence)
    if quote == state.quote && !empty(marker) && marker[0] ==# state.fence[0]
          \ && strlen(marker) >= strlen(state.fence)
          \ && strpart(text, matchend(prefix, '^ \{0,3}') + strlen(marker)) =~# '^\s*$'
      let state.fence = ''
    endif
    return [state, 1]
  endif
  let lists = copy(state.lists)
  let list = matchstr(prefix, '^ *\%([-+*]\|\d\+[.)]\)[ \t]\+')
  if prefix =~# '\S'
    while !empty(lists) && indentation < lists[-1]
      call remove(lists, -1)
    endwhile
  endif
  let list_item = !empty(list) && (indentation < 4 || !empty(lists))
  let list_body = !empty(lists) && indentation >= lists[-1]
  let content_indent = list_body ? lists[-1] : 0
  if list_item
    call add(lists, strdisplaywidth(list))
  elseif list_body
    let text = strpart(text, content_indent)
    let prefix = strpart(text, 0, 256)
    let marker = matchstr(prefix, '^ \{0,3}\zs\%(`\{3,}\|\~\{3,}\)')
  endif
  let state.lists = lists
  if state.comment
    let end = stridx(text, '-->')
    if end < 0
      return [state, 1]
    endif
    let state.comment = 0
    let text = strpart(text, end + 3)
    let prefix = strpart(text, 0, 256)
    let protected = 1
  else
    let protected = 0
  endif
  if !protected && !empty(marker)
    let state.fence = marker
    let state.quote = quote
    let state.indent = content_indent
    return [state, 1]
  endif
  " 反引号包围的行内注释标记是字面量；只在含注释标记时做这项处理。
  if stridx(text, '<!--') >= 0
    let opening = stridx(text, '<!--')
    if stridx(text, '``') < 0 && stridx(text, '\`') < 0
          \ && stridx(text, '<!--', opening + 4) < 0
      " 常见的单反引号／单注释路径由原生计数处理，避免为万段代码替换整条长行。
      let inside = count(strpart(text, 0, opening), '`') % 2
            \ && stridx(text, '`', opening + 4) >= 0
      let literal = inside ? '' : text
    else
      let literal = substitute(text, '`\+[^`]*`\+', '', 'g')
    endif
    let offset = 0
    while 1
      let start = stridx(literal, '<!--', offset)
      if start < 0
        break
      endif
      let end = stridx(literal, '-->', start + 4)
      let protected = protected || strpart(literal, 0, start) =~# '^\s*$'
      if end < 0
        let state.comment = 1
        break
      endif
      let offset = end + 3
    endwhile
  endif
  return [state, protected || state.comment || !list_item && prefix =~# '^\%( \{4}\|\t\)']
endfunction

" 规范表格仅改变管道之间的空白，行号、标题和块状态不变，可直接确认这次改动。
function! VimMarkdownIndexStableRange(first, last) abort
  call VimMarkdownIndexChanged()
  let index = b:vimrc_lite_md_index
  call timer_stop(index.timer)
  let index.timer = -1
  let index.tick = b:changedtick
  let index.complete = 1
  let index.dirty = 0
  let index.change_start = line('$') + 1
  let index.change_end = 0
  let index.shifted = 0
  let index.dirty_blocks = {}
  let index.shift_span = [0, 0]
  let index.repair_unsafe = 0
  let threshold = get(g:, 'vimrc_lite_markdown_long_line_bytes', 8192)
  for lnum in range(a:first, a:last)
    if threshold > 0 && strlen(getline(lnum)) > threshold
      let index.long_lines[lnum] = 1
    elseif has_key(index.long_lines, string(lnum))
      call remove(index.long_lines, string(lnum))
    endif
  endfor
  call VimMarkdownIndexDone(bufnr('%'))
endfunction

function! s:Start(index) abort
  let first = ((a:index.change_start - 1) / s:stride) * s:stride + 1
  let first = min([first, a:index.next])
  let first = ((first - 1) / s:stride) * s:stride + 1
  let a:index.next = first
  let a:index.state = copy(get(a:index.points, string(first), s:Empty()))
  let a:index.previous = ''
  let a:index.previous_protected = 1
  if first > 1
    let a:index.previous = getbufline(a:index.buf, first - 1)[0]
    let a:index.previous_protected = get(a:index.protected, string(first - 1), 1)
  endif
  let left = 0
  let right = len(a:index.headers)
  while left < right
    let middle = (left + right) / 2
    if a:index.headers[middle].line < first
      let left = middle + 1
    else
      let right = middle
    endif
  endwhile
  let a:index.build = left ? a:index.headers[: left - 1] : []
  let a:index.dirty = 0
  let a:index.complete = 0
endfunction

function! s:Reuse(index, lnum) abort
  if a:index.shifted || !a:index.has_base || a:lnum < a:index.change_end
        \ || !has_key(a:index.base_points, string(a:lnum))
        \ || a:index.base_points[a:lnum] !=# a:index.state
    return 0
  endif
  let left = 0
  let right = len(a:index.headers)
  while left < right
    let middle = (left + right) / 2
    if a:index.headers[middle].line < a:lnum
      let left = middle + 1
    else
      let right = middle
    endif
  endwhile
  call extend(a:index.build, a:index.headers[left :])
  return 1
endfunction

function! s:Chunk(buf, timer) abort
  let index = getbufvar(a:buf, 'vimrc_lite_md_index', {})
  if empty(index) || index.timer != a:timer || !bufloaded(a:buf)
    return
  endif
  let index.timer = -1
  if bufnr('%') != a:buf
    return
  endif
  " Ex 批处理的标准输入可能已结束，窥视会直接结束 Vim，只在交互编辑时检查。
  if mode(1) !~# '^c' && getchar(1) != 0
    let index.timer = timer_start(10, function('<SID>Chunk', [a:buf]))
    return
  endif
  " 原始 Esc 尚在终端判定期间仍报告插入模式，暂停扫描可避免延长等待。
  if mode(1) =~# '^[iRs]'
    let index.timer = timer_start(120, function('<SID>Chunk', [a:buf]))
    return
  endif
  let started = reltime()
  if index.dirty > 0
    call s:Start(index)
  endif
  let last = getbufinfo(a:buf)[0].linecount
  let processed = 0
  while index.next <= last && processed < 96
    let lnum = index.next
    if (lnum - 1) % s:stride == 0
      if s:Reuse(index, lnum)
        let index.state = copy(index.base_end_state)
        let index.next = last + 1
        break
      endif
      let index.points[lnum] = copy(index.state)
    endif
    let text = getbufline(a:buf, lnum)[0]
    let threshold = get(g:, 'vimrc_lite_markdown_long_line_bytes', 8192)
    if threshold > 0 && strlen(text) > threshold
      let index.long_lines[lnum] = 1
    elseif has_key(index.long_lines, string(lnum))
      call remove(index.long_lines, string(lnum))
    endif
    let [state, protected] = s:Step(text, index.state, lnum)
    let index.protected[lnum] = protected
    if !protected
      let heading = matchlist(strpart(text, 0, 2048),
            \ '^ \{0,3}\(#\{1,6}\)\%([ \t]\+\(.*\)\|$\)')
      if !empty(heading)
        let label = substitute(get(heading, 2, ''), '\s\+#\+\s*$', '', '')
        call add(index.build, {'line': lnum, 'level': strlen(heading[1]), 'text': label})
      elseif text =~# '^ \{0,3}\%([=]\+\|[-]\+\)\s*$' && lnum > 1
            \ && !index.previous_protected && index.previous =~# '\S'
            \ && index.previous !~# '^\s*\%([#>|]\|[-+*]\s\|\d\+[.)]\s\)'
        if empty(index.build) || index.build[-1].line != lnum - 1
          call add(index.build, {'line': lnum - 1, 'level': text =~# '=' ? 1 : 2,
                \ 'text': substitute(strpart(index.previous, 0, 2048), '^\s*\|\s*$', '', 'g')})
        endif
      endif
    endif
    let index.state = state
    let index.previous = strpart(text, 0, 2048)
    let index.previous_protected = protected
    let index.next += 1
    let processed += 1
    if reltimefloat(reltime(started)) >= 0.003
      break
    endif
  endwhile
  let index.complete = index.next > last
  if index.complete
    for lnum in keys(index.long_lines)
      if str2nr(lnum) > last
        call remove(index.long_lines, lnum)
      endif
    endfor
    let index.tick = getbufvar(a:buf, 'changedtick')
    let index.headers = index.build
    let index.build = []
    let index.base_points = copy(index.points)
    let index.base_end_state = copy(index.state)
    if (index.next - 1) % s:stride == 0
      let index.points[index.next] = copy(index.state)
    endif
    let index.has_base = 1
    let index.change_start = last + 1
    let index.change_end = 0
    let index.shifted = 0
    let index.dirty_blocks = {}
    let index.shift_span = [0, 0]
    let index.repair_unsafe = 0
  else
    let index.timer = timer_start(1, function('<SID>Chunk', [a:buf]))
  endif
  " 统计解析与索引发布；显式命令回调由交互基准单独测量。
  let elapsed = reltimefloat(reltime(started)) * 1000
  let index.max_batch_ms = max([index.max_batch_ms, float2nr(elapsed * 1000)])
  let index.batches += 1
  if index.complete && exists('*VimMarkdownIndexDone')
    call VimMarkdownIndexDone(a:buf)
  endif
endfunction

function! VimMarkdownIndexDirty(buf, first, ...) abort
  let index = getbufvar(a:buf, 'vimrc_lite_md_index', {})
  if empty(index)
    return
  endif
  let index.dirty = index.dirty > 0 ? min([index.dirty, a:first]) : a:first
  let index.change_start = min([index.change_start, a:first])
  let delta = get(a:000, 1, 1)
  let last = get(a:000, 0, a:first + 1)
  let index.change_end = max([index.change_end + abs(delta), last])
  let index.shifted += delta
  let first = a:first
  if delta
    let first = index.shift_span[0] ? min([index.shift_span[0], first]) : first
    let last = max([index.shift_span[1] + abs(delta), last])
    let index.shift_span = [first, last]
  endif
  let first = ((first - 1) / s:stride) * s:stride + 1
  let last = ((last - 1) / s:stride) * s:stride + 1
  if last - first > 2 * s:stride
    let index.repair_unsafe = 1
  else
    for point in range(first, last, s:stride)
      let index.dirty_blocks[point] = 1
    endfor
  endif
  let index.complete = 0
  if index.timer != -1
    call timer_stop(index.timer)
  endif
  let index.timer = timer_start(60, function('<SID>Chunk', [a:buf]))
endfunction

function! s:Listen(buf, start, end, added, changes) abort
  " Setext 标题的下一行也能改变上一行的结构。
  call VimMarkdownIndexDirty(a:buf, max([1, a:start - 1]),
        \ a:end + max([0, a:added]) + 1, a:added)
endfunction

function! VimMarkdownIndexAttach() abort
  if !empty(get(b:, 'vimrc_lite_md_index', {}))
    return
  endif
  let b:vimrc_lite_md_index = {'buf': bufnr('%'), 'next': 1, 'dirty': 0, 'state': s:Empty(),
        \ 'points': {'1': s:Empty()}, 'headers': [], 'complete': 0, 'tick': -1,
        \ 'protected': {},
        \ 'long_lines': {},
        \ 'base_points': {}, 'build': [], 'has_base': 0, 'change_start': 1,
        \ 'base_end_state': s:Empty(),
        \ 'change_end': 0, 'shifted': 1,
        \ 'dirty_blocks': {}, 'shift_span': [0, 0], 'repair_unsafe': 0, 'repairs': 0,
        \ 'timer': -1, 'listener': 0, 'previous': '', 'previous_protected': 1,
        \ 'batches': 0, 'max_batch_ms': 0, 'fallbacks': 0}
  if exists('*listener_add')
    let b:vimrc_lite_md_index.listener = listener_add(function('<SID>Listen'), bufnr('%'))
  endif
  let b:vimrc_lite_md_index.timer = timer_start(1, function('<SID>Chunk', [bufnr('%')]))
endfunction

" 少量远隔的正文修改可以分别验证检查点；状态未变时安全复用中间的大段正文。
function! s:Repair(index, first) abort
  if !a:index.has_base || a:index.shifted || a:index.repair_unsafe
        \ || !has_key(a:index.base_points, string(a:first))
    return 0
  endif
  let points = filter(map(keys(a:index.dirty_blocks), 'str2nr(v:val)'), 'v:val < a:first')
  if len(points) > 3
    return 0
  endif
  for point in sort(points, 'n')
    if !has_key(a:index.base_points, string(point + s:stride))
      return 0
    endif
    let state = copy(a:index.base_points[point])
    for lnum in range(point, point + s:stride - 1)
      let [state, protected] = s:Step(getline(lnum), state, lnum)
    endfor
    if state !=# a:index.base_points[point + s:stride]
      return 0
    endif
  endfor
  let a:index.repairs += 1
  return 1
endfunction

function! VimMarkdownIndexResume() abort
  if &filetype !=# 'markdown'
    return
  endif
  call VimMarkdownIndexChanged()
  let index = get(b:, 'vimrc_lite_md_index', {})
  if !empty(index) && !index.complete
    call timer_stop(index.timer)
    let index.timer = timer_start(1, function('<SID>Chunk', [bufnr('%')]))
  endif
endfunction

function! VimMarkdownIndexStop(buf) abort
  let index = getbufvar(a:buf, 'vimrc_lite_md_index', {})
  if !empty(index)
    call timer_stop(index.timer)
    if index.listener && exists('*listener_remove')
      call listener_remove(index.listener)
    endif
    call setbufvar(a:buf, 'vimrc_lite_md_index', {})
  endif
endfunction

function! VimMarkdownIndexChanged() abort
  if &filetype !=# 'markdown' || !exists('b:vimrc_lite_md_index')
    return
  endif
  if exists('*listener_flush')
    call listener_flush(bufnr('%'))
  elseif b:vimrc_lite_md_index.tick != b:changedtick
    call VimMarkdownIndexDirty(bufnr('%'), 1)
  endif
endfunction

" 返回 0=正文、1=代码／注释／属性、-1=尚未就绪；最多检查一个检查点区间。
function! VimMarkdownContext(lnum) abort
  call VimMarkdownIndexChanged()
  let index = b:vimrc_lite_md_index
  let first = ((a:lnum - 1) / s:stride) * s:stride + 1
  let frontier = index.dirty > 0 ? min([index.next, index.dirty]) : index.next
  if a:lnum < frontier
    return get(index.protected, string(a:lnum), -1)
  endif
  if first > frontier || !has_key(index.points, string(first))
    if !s:Repair(index, first)
      let index.fallbacks += 1
      return -1
    endif
    let state = copy(index.base_points[first])
  else
    let state = copy(get(index.points, string(first), s:Empty()))
  endif
  for lnum in range(first, a:lnum)
    let [state, protected] = s:Step(getline(lnum), state, lnum)
  endfor
  return protected
endfunction

" 供显式目录操作判断整行注释标记是否位于代码或其他注释中。
function! VimMarkdownBlockBefore(lnum) abort
  call VimMarkdownIndexChanged()
  let index = b:vimrc_lite_md_index
  let first = ((a:lnum - 1) / s:stride) * s:stride + 1
  let frontier = index.dirty > 0 ? min([index.next, index.dirty]) : index.next
  if first > frontier || !has_key(index.points, string(first))
    return {'fence': '?', 'comment': 1, 'yaml': 0}
  endif
  let state = copy(index.points[first])
  if first < a:lnum
    for lnum in range(first, a:lnum - 1)
      let [state, protected] = s:Step(getline(lnum), state, lnum)
    endfor
  endif
  return state
endfunction

function! VimMarkdownHeaders() abort
  call VimMarkdownIndexChanged()
  return get(b:vimrc_lite_md_index, 'complete', 0) ? b:vimrc_lite_md_index.headers : []
endfunction
