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
  let first = 0
  let last = strchars(a:name)
  while first < last
    let middle = (first + last + 1) / 2
    if strdisplaywidth(strcharpart(a:name, 0, middle)) <= a:width - 1
      let first = middle
    else
      let last = middle - 1
    endif
  endwhile
  return strcharpart(a:name, 0, first) . '~'
endfunction

" 单个标签的宽度上限，防止长文件名挤掉其它标签。
let s:label_max_width = 32
" 多 buffer 时为两端的 "< " 与 " >" 溢出指示预留的列宽。
let s:overflow_reserve = 4

" 从焦点向两侧扩展连续区间，直到预算装不下相邻标签；隐藏项不参与重新编号。
function! s:VisibleRange(buffers, names, focus, budget) abort
  let first = a:focus
  let last = a:focus
  let labels = {a:focus: s:Label(a:buffers, a:names, a:focus, a:budget)}
  let used = strdisplaywidth(labels[a:focus])
  while 1
    let expanded = 0
    if last + 1 < len(a:buffers)
      let label = s:Label(a:buffers, a:names, last + 1, a:budget)
      let width = strdisplaywidth(label)
      let markers = (first > 0 ? 2 : 0) + (last + 2 < len(a:buffers) ? 2 : 0)
      if used + width + markers <= a:budget
        let last += 1
        let used += width
        let labels[last] = label
        let expanded = 1
      endif
    endif
    if first > 0
      let label = s:Label(a:buffers, a:names, first - 1, a:budget)
      let width = strdisplaywidth(label)
      let markers = (first > 1 ? 2 : 0) + (last + 1 < len(a:buffers) ? 2 : 0)
      if used + width + markers <= a:budget
        let first -= 1
        let used += width
        let labels[first] = label
        let expanded = 1
      endif
    endif
    if !expanded
      break
    endif
  endwhile
  let used += (first > 0 ? 2 : 0) + (last + 1 < len(a:buffers) ? 2 : 0)
  return [first, last, labels, used]
endfunction

" 只为当前可见区间及相邻候选项生成标签；隐藏项无需查询选项或截断路径。
function! s:Label(buffers, names, index, budget) abort
  let buffer = a:buffers[a:index]
  let prefix = printf(' %d:', a:index + 1)
  let flags = (buffer.changed ? ' +' : '')
        \ . (getbufvar(buffer.bufnr, '&readonly') ? ' [RO]' : '') . ' '
  if getbufvar(buffer.bufnr, '&buftype') ==# 'terminal'
    let flags = ' [term]' . flags
  endif
  let reserve = len(a:buffers) > 1 ? s:overflow_reserve : 0
  let available = a:budget - reserve - strdisplaywidth(prefix . flags)
  let width = max([1, min([s:label_max_width, available])])
  return prefix . s:BufferLabel(a:names[a:index], width) . flags
endfunction

" 重载时保留当前句子；配置及显示宽度变化时重新建立候选缓存。
let s:slogan_cache = get(s:, 'slogan_cache', {
      \ 'source': [], 'display': [], 'entries': [], 'current': {}, 'miss': -1, 'rotate': 0})
let s:slogan_seed = get(s:, 'slogan_seed', [])

" 新打开的 buffer 也会触发 BufEnter；只排队一次选择，重绘时按最终空间挑句子。
function! s:RotateSlogan(buffer) abort
  if buflisted(a:buffer)
    let s:slogan_cache.rotate = 1
  endif
endfunction

function! s:SloganIndex(count) abort
  if exists('*rand') && exists('*srand')
    if empty(s:slogan_seed)
      let s:slogan_seed = srand()
    endif
    return rand(s:slogan_seed) % a:count
  endif
  " 旧 Vim 的 16 位伪随机回退；乘积不会溢出 32 位整数。
  let seed = get(s:, 'slogan_fallback_seed', (localtime() % 65536 + getpid() % 65536) % 65536)
  let s:slogan_fallback_seed = (seed * 25173 + 13849) % 65536
  return s:slogan_fallback_seed % a:count
endfunction

function! s:Slogan(width) abort
  let source = get(g:, 'vimrc_lite_buffer_slogans', [])
  if type(source) != type([])
    let source = []
  endif
  let display = [&encoding, &ambiwidth, exists('+emoji') ? &emoji : 0]
  let cache = s:slogan_cache
  if source !=# cache.source || display !=# cache.display
    let previous = get(cache.current, 'text', '')
    let cache.source = deepcopy(source)
    let cache.display = display
    let cache.entries = []
    let cache.current = {}
    let cache.miss = -1
    for text in source
      if type(text) != type('') || text !~# '\S' || text =~# '[[:cntrl:]]'
        continue
      endif
      let entry = {'text': text, 'width': strdisplaywidth(text)}
      call add(cache.entries, entry)
      if text ==# previous
        let cache.current = entry
      endif
    endfor
  endif
  let rotate = get(cache, 'rotate', 0)
  if !rotate && !empty(cache.current) && cache.current.width <= a:width
    return cache.current.text
  endif
  let previous = get(cache.current, 'text', '')
  let cache.current = {}
  let cache.rotate = 0
  if a:width <= 0 || cache.miss == a:width
    return ''
  endif
  let candidates = filter(copy(cache.entries), 'v:val.width <= a:width')
  if empty(candidates)
    let cache.miss = a:width
    return ''
  endif
  if rotate && !empty(previous)
    let alternatives = filter(copy(candidates), 'v:val.text !=# previous')
    if !empty(alternatives)
      let candidates = alternatives
    endif
  endif
  let cache.current = candidates[s:SloganIndex(len(candidates))]
  let cache.miss = -1
  return cache.current.text
endfunction

let s:name_key = []
let s:names = []
function! s:BufferLine() abort
  let buffers = s:ListedBuffers()
  if empty(buffers)
    return '%#VimrcBufferLine#'
  endif
  " 对比真实名称列表，兼容 :file、:badd、重载及 noautocmd 修改。
  let key = map(copy(buffers), 'v:val.name')
  if key !=# s:name_key
    let s:name_key = key
    let s:names = s:BufferNames(buffers)
  endif
  let numbers = map(copy(buffers), 'v:val.bufnr')
  let current = index(numbers, bufnr('%'))
  let focus = current >= 0 ? current : max([0, index(numbers, bufnr('#'))])
  let tabs = tabpagenr('$') > 1 ? printf(' Tab %d/%d ', tabpagenr(), tabpagenr('$')) : ''
  " 极窄窗口优先保留当前 buffer 编号和状态。
  if &columns < 40
    let tabs = ''
  endif
  let budget = &columns - strdisplaywidth(tabs)
  let [first, last, labels, used] = s:VisibleRange(buffers, s:names, focus, budget)
  let line = '%#VimrcBufferLine#' . (first > 0 ? '< ' : '')
  for index in range(first, last)
    let line .= index == current ? '%#VimrcBufferLineCurrent#' : '%#VimrcBufferLine#'
    let line .= substitute(labels[index], '%', '%%', 'g')
  endfor
  " buffer 与溢出标记优先；slogan 左侧留两列，右侧留一列。
  let slogan = s:Slogan(budget - used - 3)
  let suffix = empty(slogan) ? '' : '  %#VimrcBufferSlogan#'
        \ . substitute(slogan, '%', '%%', 'g') . '%#VimrcBufferLine# '
  return line . '%#VimrcBufferLine#' . (last + 1 < len(buffers) ? ' >' : '')
        \ . '%=' . suffix . tabs
endfunction

function! s:BufferLineColors() abort
  let status = synIDtrans(hlID('StatusLine'))
  let normal = synIDtrans(hlID('Normal'))
  let fill = synIDtrans(hlID('TabLineFill'))
  let selected = synIDtrans(hlID('TabLineSel'))
  " 恢复整条浅色横栏：以正文前景作底色、填充区背景作字色，直接设色而不依赖反色。
  for [group, style] in [['VimrcBufferLine', 'NONE'],
        \ ['VimrcBufferLineCurrent', 'NONE'], ['VimrcBufferSlogan', 'italic']]
    execute 'highlight! ' . group . ' gui=' . style . ' cterm=' . style . ' term=' . style
    for mode in ['gui', 'cterm']
      let foreground = synIDattr(fill, 'bg', mode)
      if empty(foreground)
        let foreground = synIDattr(status, 'bg', mode)
      endif
      let background = synIDattr(normal, 'fg', mode)
      if empty(background)
        let background = synIDattr(status, 'fg', mode)
      endif
      if group ==# 'VimrcBufferLineCurrent'
        let foreground = synIDattr(selected, 'fg', mode)
        let background = synIDattr(selected, 'bg', mode)
      endif
      execute 'highlight ' . group . ' ' . mode . 'fg='
            \ . (empty(foreground) ? 'NONE' : foreground) . ' ' . mode . 'bg='
            \ . (empty(background) ? 'NONE' : background)
    endfor
  endfor
endfunction
call s:BufferLineColors()
set showtabline=2
if has('gui_running')
  set guioptions-=e
endif
let &tabline = '%!' . matchstr(string(function('s:BufferLine')), '<SNR>\d\+_BufferLine') . '()'
let s:redrawtabline = exists(':redrawtabline') == 2 ? 'redrawtabline' : 'redraw'
augroup vimrc_lite_buffers
  autocmd!
  autocmd ColorScheme * call <SID>BufferLineColors()
  autocmd BufEnter * call <SID>RotateSlogan(str2nr(expand('<abuf>')))
  execute 'autocmd BufAdd,BufDelete,BufEnter,BufFilePost,BufWritePost * ' . s:redrawtabline
  execute 'autocmd VimResized * ' . s:redrawtabline
  if exists('##BufModifiedSet')
    execute 'autocmd BufModifiedSet * ' . s:redrawtabline
  else
    execute 'autocmd TextChanged,TextChangedI * ' . s:redrawtabline
  endif
  if exists('##OptionSet')
    execute 'autocmd OptionSet readonly,buflisted,ambiwidth ' . s:redrawtabline
    if exists('+emoji')
      execute 'autocmd OptionSet emoji ' . s:redrawtabline
    endif
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
