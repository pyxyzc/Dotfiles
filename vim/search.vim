" fd/rg 提供数据，fzf 运行于 Vim 自带终端；不加载第三方插件。
let s:helper = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/search.sh'
let s:active = {}

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
    if parent ==# directory | return getcwd() | endif
    let directory = parent
  endwhile
endfunction

function! s:Geometry() abort
  return [max([20, &columns * 9 / 10]), max([4, (&lines - 2) * 8 / 10])]
endfunction

function! s:Resize() abort
  if empty(s:active) || !get(s:active, 'popup', 0) | return | endif
  let [width, height] = s:Geometry()
  call popup_setoptions(s:active.popup, {'minwidth': width, 'maxwidth': width,
        \ 'minheight': height, 'maxheight': height,
        \ 'line': max([1, (&lines - height) / 2]), 'col': max([1, (&columns - width) / 2])})
  call term_setsize(s:active.buf, height, width)
endfunction

function! s:History(mode) abort
  let directory = (empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME) . '/vim-lite/search'
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

function! s:Colors() abort
  let transparent = get(g:, 'vimrc_lite_transparent', 1)
  if exists('+termguicolors') && &termguicolors
    return 'bg:' . (transparent ? '-1' : '#1a1b26')
          \ . ',fg:#c0caf5,bg+:#292e42,fg+:#c0caf5,hl:#7aa2f7,hl+:#7dcfff'
          \ . ',border:#565f89,prompt:#7aa2f7,pointer:#bb9af7,info:#9ece6a,header:#9aa5ce'
  endif
  return 'bg:' . (transparent ? '-1' : '234')
        \ . ',fg:153,bg+:236,fg+:153,hl:111,hl+:117,border:60,prompt:111,pointer:141,info:149,header:146'
endfunction

" done 标志也让退出回调在取消、重载或下一次搜索后安全失效。
function! s:Cleanup(state) abort
  if empty(a:state) || get(a:state, 'done', 0) | return | endif
  let a:state.done = 1
  if has_key(a:state, 'job') && job_status(a:state.job) ==# 'run'
    call job_stop(a:state.job, 'term')
  endif
  if get(a:state, 'popup', 0)
    silent! call popup_close(a:state.popup)
  endif
  if get(a:state, 'buf', 0) && bufexists(a:state.buf)
    execute 'silent! bwipeout! ' . a:state.buf
  endif
  let &ttimeout = a:state.ttimeout
  let &ttimeoutlen = a:state.ttimeoutlen
  if win_gotoid(a:state.origin) && get(a:state, 'split', 0)
    silent! execute a:state.layout
    call win_gotoid(a:state.origin)
  endif
  if exists('#User#VimrcLiteSearchClosed')
    doautocmd <nomodeline> User VimrcLiteSearchClosed
  endif
  call delete(a:state.directory, 'rf')
  if get(s:active, 'directory', '') ==# a:state.directory | let s:active = {} | endif
endfunction

function! s:Finish(state, status, timer) abort
  if get(a:state, 'done', 0) | return | endif
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
  call s:Cleanup(a:state)
  if !empty(error) | call s:Warn(error) | endif
  if empty(path) || len(position) != 2 | return | endif
  if !win_gotoid(a:state.origin)
    call s:Warn('original window closed; selection was not opened')
    return
  endif
  let path = a:state.root . '/' . path
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
endfunction

function! s:Exited(state, job, status) abort
  let a:state.status = a:status
  if get(a:state, 'closed', 0)
    call timer_start(0, function('s:Finish', [a:state, a:status]))
  endif
endfunction

function! s:Closed(state, channel) abort
  let a:state.closed = 1
  " 进程退出不代表终端通道已关闭；提前 wipe 会让旧输入循环吃掉下一次 leader。
  " 两个事件都收到后再延迟清理，让 Vim 先结束终端输入；兼容回调的两种顺序。
  if has_key(a:state, 'status')
    call timer_start(0, function('s:Finish', [a:state, a:state.status]))
  endif
endfunction

function! s:Open(mode) abort
  if !has('terminal') || !has('timers')
    call s:Warn('requires Vim +terminal and +timers')
    return
  endif
  let missing = filter(['bash', 'fzf'], '!executable(v:val)')
  if a:mode ==# 'files' && !executable('fd') && !executable('fdfind')
    call add(missing, 'fd/fdfind')
  elseif a:mode ==# 'grep' && !executable('rg')
    call add(missing, 'rg (ripgrep)')
  endif
  if !empty(missing)
    call s:Warn('missing ' . join(missing, ', ') . '; install manually (Debian/Ubuntu: sudo apt install fd-find ripgrep fzf)')
    return
  endif
  if !filereadable(s:helper)
    call s:Warn('missing search.sh; copy the complete vim directory')
    return
  endif
  if &columns < 30 || &lines < 8
    call s:Warn('terminal is too small; enlarge it before searching')
    return
  endif
  call s:Cleanup(s:active)
  let state = {'directory': tempname(), 'origin': win_getid(), 'layout': winrestcmd(),
        \ 'root': s:ProjectRoot(), 'mode': a:mode, 'popup': 0, 'split': 0, 'buf': 0, 'done': 0,
        \ 'ttimeout': &ttimeout, 'ttimeoutlen': &ttimeoutlen}
  let s:active = state
  try
    " 只在搜索期间缩短终端按键序列的等待，不改变普通映射的 timeoutlen。
    set ttimeout
    let &ttimeoutlen = min([30, state.ttimeoutlen < 0 ? &timeoutlen : state.ttimeoutlen])
    call mkdir(state.directory, '', 0700)
    let [width, height] = s:Geometry()
    " 由 Finish 统一关闭，避免自动关闭提前删除终端、打断 close_cb。
    let options = {'hidden': 1, 'cwd': state.root,
          \ 'term_kill': 'term', 'norestore': 1, 'term_rows': height, 'term_cols': width,
          \ 'exit_cb': function('s:Exited', [state]), 'close_cb': function('s:Closed', [state])}
    if exists('*term_setapi') | let options.term_api = '' | endif
    let state.buf = term_start([exepath('bash'), s:helper, 'run', a:mode,
          \ state.directory, s:History(a:mode), s:Colors()], options)
    if !state.buf
      throw 'could not start the search terminal'
    endif
    let state.job = term_getjob(state.buf)
    call setbufvar(state.buf, '&buflisted', 0)
    if exists('*popup_create')
      try
        let state.popup = popup_create(state.buf, {'minwidth': width, 'maxwidth': width,
              \ 'minheight': height, 'maxheight': height, 'highlight': 'Normal',
              \ 'line': max([1, (&lines - height) / 2]), 'col': max([1, (&columns - width) / 2])})
      catch
        let state.popup = 0
      endtry
    endif
    if !state.popup
      execute 'botright ' . height . 'new'
      let state.split = 1
      execute 'buffer ' . state.buf
      let window = win_getid()
      startinsert
    else
      let window = state.popup
    endif
    " Vim 确认单次 Esc 后发送无歧义的 Ctrl-c，避免 fzf 再等 Alt/方向键序列。
    if state.popup
      call win_execute(window, 'tnoremap <silent><nowait><buffer> <Esc> <C-c>')
    else
      tnoremap <silent><nowait><buffer> <Esc> <C-c>
    endif
  catch
    let error = v:exception
    call s:Cleanup(state)
    call s:Warn(error)
  endtry
endfunction

command! VimFind call <SID>Open('files')
command! VimSearch call <SID>Open('grep')
augroup vimrc_lite_search
  autocmd!
  autocmd VimResized * call s:Resize()
  autocmd User VimrcLiteReload call s:Cleanup(s:active)
  autocmd VimLeavePre * call s:Cleanup(s:active)
augroup END
