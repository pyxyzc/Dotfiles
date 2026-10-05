" fd/rg 提供数据，fzf 运行于 Vim 自带终端；不加载第三方插件。
let s:helper = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/search.sh'
let s:active = {}
let s:capabilities = get(s:, 'capabilities', {})
let s:finders = get(s:, 'finders', {})
let s:ordinal = get(s:, 'ordinal', {})
let s:ordinal_cache = {}
let s:ordinal_timer = get(s:, 'ordinal_timer', -1)
let s:ordinal_supported = has('patch-9.0.0121') && has('textprop')
      \ && exists('*searchcount') && has('timers')

" /、?、n、N 使用原生搜索；只在当前匹配的行尾添加虚拟文字。
function! s:ClearOrdinal() abort
  if s:ordinal_timer != -1
    call timer_stop(s:ordinal_timer)
    let s:ordinal_timer = -1
  endif
  if !empty(s:ordinal) && bufloaded(s:ordinal.buffer)
    let options = {'bufnr': s:ordinal.buffer, 'type': 'VimrcLiteSearchOrdinal', 'all': 1}
    if getbufvar(s:ordinal.buffer, 'changedtick') == s:ordinal.tick
      call prop_remove(options, s:ordinal.line, s:ordinal.line)
    else
      " 编辑可能移动或删除原行；此时按类型清理，避免留下旧标记。
      call prop_remove(options)
    endif
  endif
  let s:ordinal = {}
endfunction

function! s:UpdateOrdinal(timer) abort
  let s:ordinal_timer = -1
  if !get(g:, 'vimrc_lite_search_ordinal', 1) || !v:hlsearch || empty(@/)
        \ || &buftype !=# '' || mode() =~# '^[iRt]' || !empty(getcmdtype())
    call s:ClearOrdinal()
    return
  endif
  let key = [bufnr('%'), b:changedtick, @/, &ignorecase, &smartcase, &magic]
  let position = getpos('.')[1:3]
  if get(s:ordinal_cache, 'key', []) !=# key
        \ || (get(s:ordinal_cache, 'position', []) !=# position
        \ && !get(get(s:ordinal_cache, 'count', {}), 'incomplete', 0))
    try
      " 不受默认 999 次计数上限影响；复杂正则最多占用 20 毫秒。
      let stats = searchcount({'recompute': 1, 'maxcount': 0, 'timeout': 20})
    catch
      call s:ClearOrdinal()
      let s:ordinal_cache = {}
      return
    endtry
    let s:ordinal_cache = {'key': key, 'position': position, 'count': stats}
  endif
  let stats = s:ordinal_cache.count
  if !get(stats, 'exact_match', 0) || get(stats, 'incomplete', 0)
        \ || !get(stats, 'current', 0)
    call s:ClearOrdinal()
    return
  endif
  let text = printf(' [%d/%d]', stats.current, stats.total)
  if get(s:ordinal, 'buffer', 0) == bufnr('%') && get(s:ordinal, 'line', 0) == line('.')
        \ && get(s:ordinal, 'text', '') ==# text && s:ordinal.tick == b:changedtick
    return
  endif
  call s:ClearOrdinal()
  call prop_add(line('.'), 0, {'type': 'VimrcLiteSearchOrdinal', 'text': text,
        \ 'text_align': 'after'})
  let s:ordinal = {'buffer': bufnr('%'), 'line': line('.'), 'tick': b:changedtick,
        \ 'text': text}
endfunction

function! s:QueueOrdinal(...) abort
  if s:ordinal_timer != -1
    call timer_stop(s:ordinal_timer)
    let s:ordinal_timer = -1
  endif
  if !get(g:, 'vimrc_lite_search_ordinal', 1)
        \ || (!a:0 && (!v:hlsearch || empty(@/) || &buftype !=# ''))
    call s:ClearOrdinal()
    return
  endif
  " CmdlineLeave 在命令执行前触发，延后才能读取新搜索或 :nohlsearch 的状态。
  let s:ordinal_timer = timer_start(0, function('s:UpdateOrdinal'))
endfunction

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim search: ' . a:message
  echohl None
endfunction

function! s:ProjectRoot() abort
  let directory = &buftype ==# '' && !empty(bufname('%')) && !isdirectory(expand('%:p'))
        \ ? expand('%:p:h') : getcwd()
  while 1
    for marker in ['.git', '_darcs', '.hg', '.bzr', '.svn', 'Makefile', 'package.json', 'pom.xml']
      let path = directory . '/' . marker
      if isdirectory(path) || filereadable(path)
        return directory
      endif
    endfor
    let parent = fnamemodify(directory, ':h')
    if parent ==# directory
      return getcwd()
    endif
    let directory = parent
  endwhile
endfunction

function! s:Geometry() abort
  return [max([20, &columns * 9 / 10]), max([4, (&lines - 2) * 8 / 10])]
endfunction

function! s:Resize() abort
  if empty(s:active) || !get(s:active, 'popup', 0)
    return
  endif
  let [width, height] = s:Geometry()
  call popup_setoptions(s:active.popup, {'minwidth': width, 'maxwidth': width,
        \ 'minheight': height, 'maxheight': height,
        \ 'line': max([1, (&lines - height) / 2]), 'col': max([1, (&columns - width) / 2])})
  call term_setsize(s:active.buf, height, width)
endfunction

function! s:History(mode) abort
  let state_home = empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME
  let directory = state_home . '/vim-lite/search'
  try
    if !isdirectory(directory)
      call mkdir(directory, 'p', 0700)
    endif
    let path = directory . '/' . a:mode . '.history'
    if (!empty(getftype(path)) && (!filereadable(path) || filewritable(path) != 1))
          \ || filewritable(directory) != 2
      throw 'history directory is not writable'
    endif
    return path
  catch
    call s:Warn('history unavailable; searching without saved history')
    return ''
  endtry
endfunction

function! s:EncodePath(path) abort
  let encoded = substitute(a:path, '%', '%25', 'g')
  let encoded = substitute(encoded, "\t", '%09', 'g')
  let encoded = substitute(encoded, "\n", '%0A', 'g')
  let encoded = substitute(encoded, "\r", '%0D', 'g')
  return substitute(encoded, "\e", '%1B', 'g')
endfunction

function! s:WriteRecent(state) abort
  let paths = []
  let seen = {}
  for path in get(v:, 'oldfiles', [])
    if empty(path) || has_key(seen, path)
      continue
    endif
    let seen[path] = 1
    call add(paths, s:EncodePath(path))
  endfor
  if empty(paths)
    throw 'no recent files in viminfo'
  endif
  " 会话临时文件只用于进程间传递，不需要同步刷盘。
  call writefile(paths, a:state.directory . '/recent', 'bS')
endfunction

function! s:Colors() abort
  let transparent = get(g:, 'vimrc_lite_transparent', 1)
  if exists('+termguicolors') && &termguicolors
    return 'bg:' . (transparent ? '-1' : '#1a1b26')
          \ . ',fg:#c0caf5,bg+:#292e42,fg+:#c0caf5,hl:#7aa2f7,hl+:#7dcfff'
          \ . ',border:#565f89,prompt:#7aa2f7,pointer:#bb9af7,info:#9ece6a,header:#9aa5ce'
  endif
  return 'bg:' . (transparent ? '-1' : '234')
        \ . ',fg:153,bg+:236,fg+:153,hl:111,hl+:117,border:60,'
        \ . 'prompt:111,pointer:141,info:149,header:146'
endfunction

" 依赖检查：返回缺失工具列表；bash 与 fzf 为两种模式共用的底线。
function! s:MissingTools(mode) abort
  " 只查外部程序；缓存已找到的 fd/fdfind，避免每次遍历 PATH 查找缺失的 fd。
  let missing = filter(['bash', 'fzf', 'gawk'], 'empty(exepath(v:val))')
  if a:mode ==# 'files'
    let key = string([$PATH, getcwd()])
    let finder = get(s:finders, key, '')
    if empty(finder) || empty(exepath(finder))
      let finder = exepath('fd')
      let s:finders[key] = empty(finder) ? exepath('fdfind') : finder
    endif
    if empty(s:finders[key])
      call add(missing, 'fd/fdfind')
    endif
  elseif a:mode ==# 'grep' && empty(exepath('rg'))
    call add(missing, 'rg (ripgrep)')
  endif
  return missing
endfunction

" done 标志也让退出回调在取消、重载或下一次搜索后安全失效。
function! s:Cleanup(state, ...) abort
  if empty(a:state) || get(a:state, 'done', 0)
    return
  endif
  let a:state.done = 1
  if has_key(a:state, 'exit_poll')
    call timer_stop(a:state.exit_poll)
  endif
  if has_key(a:state, 'cancel_timer')
    call timer_stop(a:state.cancel_timer)
  endif
  if has_key(a:state, 'capability_key') && filereadable(a:state.directory . '/capabilities')
    let capabilities = get(readfile(a:state.directory . '/capabilities'), 0, '')
    if capabilities =~# '^baseline\%(,path\)\?\%(,layout\)\?$'
      let s:capabilities[a:state.capability_key] = capabilities
    endif
  endif
  if has_key(a:state, 'job') && job_status(a:state.job) ==# 'run'
    call job_stop(a:state.job, 'term')
  endif
  if get(a:state, 'popup', 0)
    silent! call popup_close(a:state.popup)
  endif
  if get(a:state, 'buf', 0) && bufexists(a:state.buf)
    execute 'silent! bwipeout! ' . a:state.buf
    " 让旧终端输入循环返回，下一次 leader 才能按普通模式映射解码。
    call feedkeys("\<Ignore>", 'in')
  endif
  let &ttimeout = a:state.ttimeout
  let &ttimeoutlen = a:state.ttimeoutlen
  if win_gotoid(a:state.origin) && get(a:state, 'split', 0)
    silent! execute a:state.layout
    call win_gotoid(a:state.origin)
  endif
  if !get(a:000, 0, 0) && exists('#User#VimrcLiteSearchClosed')
    doautocmd <nomodeline> User VimrcLiteSearchClosed
  endif
  call delete(a:state.directory, 'rf')
  if get(s:active, 'directory', '') ==# a:state.directory
    let s:active = {}
  endif
endfunction

function! s:Finish(state, status, timer) abort
  if get(a:state, 'done', 0)
    return
  endif
  " 取消后即使进程恰好以成功状态退出，也不能再打开已生成的选择结果。
  if get(a:state, 'cancelled', 0)
    call s:Cleanup(a:state)
    return
  endif
  let path = ''
  let position = []
  let error = ''
  if a:status == 0 && filereadable(a:state.directory . '/path')
    " 文件名独占二进制文件；换行、冒号等字符不参与字段解析。
    let path = join(readfile(a:state.directory . '/path', 'b'), "\n")
    let position = readfile(a:state.directory . '/position')
  elseif a:status != 130 && a:status != 1
    let error = filereadable(a:state.directory . '/error')
          \ ? join(readfile(a:state.directory . '/error'), ' ') : 'search process failed'
  endif
  call s:Cleanup(a:state, !empty(path))
  if !empty(error)
    call s:Warn(error)
  endif
  if empty(path) || len(position) != 2
    return
  endif
  if !win_gotoid(a:state.origin)
    call s:Warn('original window closed; selection was not opened')
    return
  endif
  let path = a:state.mode ==# 'recent' ? fnamemodify(path, ':p') : a:state.root . '/' . path
  if !filereadable(path)
    call s:Warn('selected file is no longer readable')
    return
  endif
  try
    execute 'edit ' . fnameescape(path)
    call cursor(max([1, str2nr(position[0])]), max([1, str2nr(position[1])]))
    normal! zvzz
  catch
    call s:Warn(v:exception)
  endtry
  if exists('#User#VimrcLiteSearchClosed')
    doautocmd <nomodeline> User VimrcLiteSearchClosed
  endif
endfunction

function! s:ScheduleFinish(state) abort
  if get(a:state, 'closed', 0) && has_key(a:state, 'status')
        \ && !get(a:state, 'done', 0) && !has_key(a:state, 'finish_timer')
    let a:state.finish_timer = timer_start(0, function('s:Finish', [a:state, a:state.status]))
  endif
endfunction

function! s:PollExit(state, timer) abort
  if get(a:state, 'done', 0) || has_key(a:state, 'finish_timer')
    call timer_stop(a:timer)
    return
  endif
  if !has_key(a:state, 'status')
    if job_status(a:state.job) ==# 'dead' && !has_key(a:state, 'status')
      let a:state.status = get(job_info(a:state.job), 'exitval', -1)
    endif
  endif
  " close_cb 可能延迟数秒；只在缓冲数据已耗尽、通道实际关闭时补齐状态。
  if has_key(a:state, 'status') && ch_status(job_getchannel(a:state.job)) ==# 'closed'
    let a:state.closed = 1
  endif
  call s:ScheduleFinish(a:state)
endfunction

function! s:Exited(state, job, status) abort
  if get(a:state, 'done', 0)
    return
  endif
  let a:state.job = a:job
  let a:state.status = a:status
  if ch_status(job_getchannel(a:job)) ==# 'closed'
    let a:state.closed = 1
  endif
  call s:ScheduleFinish(a:state)
  if !get(a:state, 'done', 0) && !has_key(a:state, 'finish_timer')
        \ && !has_key(a:state, 'exit_poll')
    let a:state.exit_poll = timer_start(2, function('s:PollExit', [a:state]), {'repeat': -1})
  endif
endfunction

function! s:Closed(state, channel) abort
  if get(a:state, 'done', 0)
    return
  endif
  let a:state.closed = 1
  " 进程退出不代表终端通道已关闭；提前 wipe 会让旧输入循环吃掉下一次 leader。
  " 确认退出与通道关闭后再延迟清理，让 Vim 先结束终端输入；兼容两种回调顺序。
  if !has_key(a:state, 'status') && has_key(a:state, 'job')
    call job_status(a:state.job)
    if !has_key(a:state, 'status') && !has_key(a:state, 'exit_poll')
      let a:state.exit_poll = timer_start(2, function('s:PollExit', [a:state]), {'repeat': -1})
    endif
  endif
  call s:ScheduleFinish(a:state)
endfunction

function! s:CancelStalled(state, timer) abort
  if !get(a:state, 'done', 0) && job_status(a:state.job) ==# 'run'
    " 能力探测或卡住的子进程可能不处理终端 Ctrl-C；仅终止本次搜索作业组。
    " 后续仍等退出和通道关闭，由既有 Finish 流程恢复编辑，不提前删除终端。
    call job_stop(a:state.job, 'term')
  endif
endfunction

function! s:CancelKey() abort
  if !empty(s:active) && !get(s:active, 'done', 0)
    let s:active.cancelled = 1
    " 直接送到子终端，避免 Ctrl-c 作为 Vim 输入时中断回调或清空待处理按键。
    call term_sendkeys(s:active.buf, "\<C-c>")
    if !has_key(s:active, 'cancel_timer')
      let s:active.cancel_timer = timer_start(100, function('s:CancelStalled', [s:active]))
    endif
  endif
  " 先让 Vim 退出终端输入循环；否则旧版可能把下一次 leader 按终端规则解码。
  " 作业退出和通道排空仍由 Finish 确认，不提前删除终端，也不增加固定等待。
  return "\<C-\>\<C-n>"
endfunction

" 弹窗可用时居中显示搜索终端，否则退回底部 split。
function! s:Show(state, width, height) abort
  if exists('*popup_create')
    try
      let a:state.popup = popup_create(a:state.buf, {
            \ 'minwidth': a:width, 'maxwidth': a:width,
            \ 'minheight': a:height, 'maxheight': a:height,
            \ 'highlight': 'Normal',
            \ 'line': max([1, (&lines - a:height) / 2]),
            \ 'col': max([1, (&columns - a:width) / 2]),
            \ })
    catch
      let a:state.popup = 0
    endtry
  endif
  if a:state.popup
    call win_execute(a:state.popup,
          \ 'tnoremap <silent><nowait><buffer><expr> <Esc> <SID>CancelKey()')
  else
    execute 'botright ' . a:height . 'new'
    let a:state.split = 1
    execute 'buffer ' . a:state.buf
    startinsert
    tnoremap <silent><nowait><buffer><expr> <Esc> <SID>CancelKey()
  endif
endfunction

function! s:Open(mode) abort
  if !has('terminal') || !has('timers')
    call s:Warn('requires Vim +terminal and +timers')
    return
  endif
  let missing = s:MissingTools(a:mode)
  if !empty(missing)
    let message = 'missing ' . join(missing, ', ')
          \ . '; install manually (Debian/Ubuntu: sudo apt install fd-find ripgrep fzf gawk)'
    call s:Warn(message)
    return
  endif
  if !filereadable(s:helper) || !filereadable(fnamemodify(s:helper, ':h') . '/search.awk')
    call s:Warn('missing search.sh/search.awk; copy the complete vim directory')
    return
  endif
  if &columns < 30 || &lines < 8
    call s:Warn('terminal is too small; enlarge it before searching')
    return
  endif
  call s:Cleanup(s:active)
  let state = {'directory': tempname(), 'origin': win_getid(), 'layout': winrestcmd(),
        \ 'root': a:mode ==# 'recent' ? getcwd() : s:ProjectRoot(),
        \ 'mode': a:mode, 'popup': 0, 'split': 0, 'buf': 0, 'done': 0,
        \ 'ttimeout': &ttimeout, 'ttimeoutlen': &ttimeoutlen}
  let state.capability_key = exepath('fzf') . ':' . getftime(exepath('fzf'))
  let s:active = state
  try
    " 只在搜索期间缩短终端按键序列的等待，不改变普通映射的 timeoutlen。
    set ttimeout
    let &ttimeoutlen = min([30, state.ttimeoutlen < 0 ? &timeoutlen : state.ttimeoutlen])
    call mkdir(state.directory, '', 0700)
    let [width, height] = s:Geometry()
    if a:mode ==# 'recent'
      call s:WriteRecent(state)
    endif
    " 由 Finish 统一关闭，避免自动关闭提前删除终端、打断 close_cb。
    let options = {'hidden': 1, 'cwd': state.root,
          \ 'term_rows': height, 'term_cols': width,
          \ 'exit_cb': function('s:Exited', [state]), 'close_cb': function('s:Closed', [state])}
    if exists('*term_setkill')
      let options.term_kill = 'term'
    endif
    if exists('*term_setrestore')
      let options.norestore = 1
    endif
    if exists('*term_setapi')
      let options.term_api = ''
    endif
    let state.buf = term_start([exepath('bash'), s:helper, 'run', a:mode,
          \ state.directory, s:History(a:mode), s:Colors(),
          \ get(s:capabilities, state.capability_key, ''),
          \ get(s:finders, string([$PATH, getcwd()]), '')], options)
    if !state.buf
      throw 'could not start the search terminal'
    endif
    let state.job = term_getjob(state.buf)
    " 退出回调本身也可能延迟；从创建时检查，避免回车后偶发等待数秒。
    let state.exit_poll = timer_start(5, function('s:PollExit', [state]), {'repeat': -1})
    call setbufvar(state.buf, '&buflisted', 0)
    call s:Show(state, width, height)
  catch
    let error = v:exception
    call s:Cleanup(state)
    call s:Warn(error)
  endtry
endfunction

command! VimFind call <SID>Open('files')
command! VimSearch call <SID>Open('grep')
command! VimRecent call <SID>Open('recent')
call s:ClearOrdinal()
if s:ordinal_supported
  highlight default link VimrcLiteSearchOrdinal Comment
  if empty(prop_type_get('VimrcLiteSearchOrdinal'))
    call prop_type_add('VimrcLiteSearchOrdinal', {'highlight': 'VimrcLiteSearchOrdinal'})
  endif
endif
augroup vimrc_lite_search_ordinal
  autocmd!
  if s:ordinal_supported
    autocmd CursorMoved,BufEnter,WinEnter,InsertLeave,TextChanged * call s:QueueOrdinal()
    autocmd CmdlineLeave * call s:QueueOrdinal(1)
    autocmd InsertEnter,CmdlineEnter,BufLeave,WinLeave * call s:ClearOrdinal()
    autocmd OptionSet hlsearch,ignorecase,smartcase,magic call s:QueueOrdinal()
    autocmd User VimrcLiteReload call s:ClearOrdinal()
    autocmd VimLeavePre * call s:ClearOrdinal()
    autocmd ColorScheme * highlight default link VimrcLiteSearchOrdinal Comment
  endif
augroup END
augroup vimrc_lite_search
  autocmd!
  autocmd VimResized * call s:Resize()
  autocmd User VimrcLiteReload call s:Cleanup(s:active)
  autocmd VimLeavePre * call s:Cleanup(s:active)
augroup END
