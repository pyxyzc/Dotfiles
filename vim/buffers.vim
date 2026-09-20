" buffer 管理模块：顶部编号栏、buffer 切换与关闭。
" 顶部编号与 <leader>1-9 数字快捷键共用同一列表，不等同于 :buffer 的实际编号。
" 关闭 buffer 前先把显示它的窗口换到接替 buffer，保留分屏布局；取消不改变布局。

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim buffers: ' . a:message
  echohl None
endfunction

function! s:ListedBuffers() abort
  return sort(getbufinfo({'buflisted': 1}), {left, right -> left.bufnr - right.bufnr})
endfunction

" 同名 buffer 以足够的路径后缀区分；一次统计后缀，避免重绘时两两比较。
function! s:BufferNames(buffers) abort
  let paths = map(copy(a:buffers), 'split(v:val.name, "/")')
  let counts = {}
  for parts in paths
    for depth in range(1, len(parts))
      let suffix = join(parts[-depth:], '/')
      let counts[suffix] = get(counts, suffix, 0) + 1
    endfor
  endfor
  let names = []
  for parts in paths
    if empty(parts)
      call add(names, '[No Name]')
      continue
    endif
    let depth = 1
    let name = parts[-1]
    while depth < len(parts) && counts[name] > 1
      let depth += 1
      let name = join(parts[-depth:], '/')
    endwhile
    call add(names, strtrans(name))
  endfor
  return names
endfunction

" 按显示列截断，避免切断中文或把 tabline 控制符当作文件名执行。
function! s:BufferLabel(name, width) abort
  if strdisplaywidth(a:name) <= a:width
    return a:name
  endif
  let name = a:name
  while !empty(name) && strdisplaywidth(name) > a:width - 1
    let name = strcharpart(name, 0, strchars(name) - 1)
  endwhile
  return name . '~'
endfunction

" 单个标签的宽度上限，防止长文件名挤掉其它标签。
let s:label_max_width = 32
" 多 buffer 时为两端的 "< " 与 " >" 溢出指示预留的列宽。
let s:overflow_reserve = 4

" 从焦点向两侧扩展连续区间，直到预算装不下相邻标签；隐藏项不参与重新编号。
function! s:VisibleRange(widths, focus, budget) abort
  let first = a:focus
  let last = a:focus
  let used = a:widths[a:focus]
  while 1
    let expanded = 0
    if last + 1 < len(a:widths)
      let markers = (first > 0 ? 2 : 0) + (last + 2 < len(a:widths) ? 2 : 0)
      if used + a:widths[last + 1] + markers <= a:budget
        let last += 1
        let used += a:widths[last]
        let expanded = 1
      endif
    endif
    if first > 0
      let markers = (first > 1 ? 2 : 0) + (last + 1 < len(a:widths) ? 2 : 0)
      if used + a:widths[first - 1] + markers <= a:budget
        let first -= 1
        let used += a:widths[first]
        let expanded = 1
      endif
    endif
    if !expanded
      break
    endif
  endwhile
  return [first, last]
endfunction

function! s:BufferLine() abort
  let buffers = s:ListedBuffers()
  if empty(buffers)
    return '%#TabLineFill#'
  endif
  let names = s:BufferNames(buffers)
  let numbers = map(copy(buffers), 'v:val.bufnr')
  let current = index(numbers, bufnr('%'))
  let focus = current >= 0 ? current : max([0, index(numbers, bufnr('#'))])
  let tabs = tabpagenr('$') > 1 ? printf(' Tab %d/%d ', tabpagenr(), tabpagenr('$')) : ''
  " 极窄窗口优先保留当前 buffer 编号和状态。
  if &columns < 40
    let tabs = ''
  endif
  let budget = &columns - strdisplaywidth(tabs)
  let reserve = len(buffers) > 1 ? s:overflow_reserve : 0
  let labels = []
  let widths = []
  for index in range(len(buffers))
    let buffer = buffers[index]
    let prefix = printf(' %d:', index + 1)
    let flags = (buffer.changed ? ' +' : '')
          \ . (getbufvar(buffer.bufnr, '&readonly') ? ' [RO]' : '') . ' '
    if getbufvar(buffer.bufnr, '&buftype') ==# 'terminal'
      let flags = ' [term]' . flags
    endif
    let available = budget - reserve - strdisplaywidth(prefix . flags)
    let width = max([1, min([s:label_max_width, available])])
    let label = prefix . s:BufferLabel(names[index], width) . flags
    call add(labels, label)
    call add(widths, strdisplaywidth(label))
  endfor
  let [first, last] = s:VisibleRange(widths, focus, budget)
  let line = '%#TabLineFill#' . (first > 0 ? '< ' : '')
  for index in range(first, last)
    let line .= index == current ? '%#TabLineSel#' : '%#VimrcBufferLine#'
    let line .= substitute(labels[index], '%', '%%', 'g')
  endfor
  return line . '%#TabLineFill#' . (last + 1 < len(buffers) ? ' >' : '') . '%=' . tabs
endfunction

function! s:BufferLineColors() abort
  highlight! link VimrcBufferLine StatusLine
endfunction
call s:BufferLineColors()
set showtabline=2
if has('gui_running')
  set guioptions-=e
endif
let &tabline = '%!' . expand('<SID>') . 'BufferLine()'
augroup vimrc_lite_buffers
  autocmd!
  autocmd ColorScheme * call <SID>BufferLineColors()
  autocmd BufAdd,BufDelete,BufEnter,BufFilePost,BufWritePost * redrawtabline
  autocmd TextChanged,TextChangedI,VimResized * redrawtabline
  if exists('##OptionSet')
    autocmd OptionSet readonly,buflisted redrawtabline
  endif
augroup END

function! s:GoBuffer(index) abort
  let buffers = s:ListedBuffers()
  if a:index <= len(buffers)
    execute 'buffer ' . buffers[a:index - 1].bufnr
  else
    call s:Warn('no buffer at position ' . a:index)
  endif
endfunction

" 未保存修改的确认；保存动作在此完成，返回 'clean'、'discard' 或 'cancel'。
function! s:CloseDecision() abort
  if !&modified
    return 'clean'
  endif
  let choice = confirm('Save changes before closing?', "&Save\n&Discard\n&Cancel", 3)
  if choice == 2
    return 'discard'
  endif
  if choice != 1
    return 'cancel'
  endif
  try
    if empty(bufname('%'))
      let name = input('Save as: ', '', 'file')
      if empty(name)
        return 'cancel'
      endif
      execute 'write ' . fnameescape(name)
    else
      update
    endif
  catch
    call s:Warn(v:exception)
    return 'cancel'
  endtry
  return 'clean'
endfunction

" 关闭 target 后接替它的 buffer：优先轮换 buffer，否则第一个其它 listed buffer。
function! s:Replacement(target) abort
  let replacement = bufnr('#')
  if replacement != a:target && buflisted(replacement)
    return replacement
  endif
  return filter(map(getbufinfo({'buflisted': 1}), 'v:val.bufnr'), 'v:val != a:target')[0]
endfunction

function! s:CloseBuffer() abort
  if &buftype ==# 'terminal' && exists('*term_getstatus')
        \ && term_getstatus(bufnr('%')) =~# 'running'
    call s:Warn('shell is running; exit the shell before deleting its buffer')
    return
  endif
  if &buftype !=# '' && &buftype !=# 'terminal'
    confirm quit
    return
  endif
  if len(getbufinfo({'buflisted': 1})) <= 1
    confirm qall
    return
  endif
  let decision = s:CloseDecision()
  if decision ==# 'cancel'
    return
  endif
  let target = bufnr('%')
  let replacement = s:Replacement(target)
  let origin = win_getid()
  let windows = copy(getbufinfo(target)[0].windows)
  try
    " 先在各窗口换上接替 buffer，再删除目标；失败时逐窗口换回。
    for window in windows
      if win_gotoid(window)
        execute 'keepalt buffer ' . replacement
      endif
    endfor
    execute 'bdelete' . (decision ==# 'discard' ? '!' : '') . ' ' . target
  catch
    for window in windows
      if win_gotoid(window) && bufexists(target)
        execute 'keepalt buffer ' . target
      endif
    endfor
    call s:Warn(v:exception)
  finally
    call win_gotoid(origin)
  endtry
endfunction

" H/L 与 <A-o>/<A-i> 前后切换，<leader>1-9 按顶部编号直达，<C-w> 关闭。
nnoremap <silent> <C-w> :call <SID>CloseBuffer()<CR>
nnoremap <silent> H :bprevious<CR>
nnoremap <silent> L :bnext<CR>
nnoremap <silent> <A-o> :bprevious<CR>
nnoremap <silent> <A-i> :bnext<CR>
nnoremap <silent> <leader>bn :enew<CR>
nnoremap <leader>bp :ls<CR>:buffer<Space>
for s:index in range(1, 9)
  execute 'nnoremap <silent> <leader>' . s:index . ' :call <SID>GoBuffer(' . s:index . ')<CR>'
endfor
