" 原生首页：只显示居中的 slogan，不进入普通 buffer 列表。
let s:dashboard_options = ['number', 'relativenumber', 'cursorline', 'cursorcolumn',
      \ 'foldcolumn', 'signcolumn', 'foldenable', 'wrap', 'list', 'spell',
      \ 'colorcolumn', 'scrolloff', 'sidescrolloff', 'fillchars']
let s:dashboard_stdin = get(s:, 'dashboard_stdin', 0)

function! s:DashboardRestoreStatus() abort
  if exists('s:dashboard_laststatus')
    let &laststatus = s:dashboard_laststatus
    unlet s:dashboard_laststatus
  endif
  if exists('s:dashboard_showtabline')
    let &showtabline = s:dashboard_showtabline
    unlet s:dashboard_showtabline
  endif
endfunction

function! s:DashboardLeave() abort
  call s:DashboardRestoreStatus()
  if exists('w:vimrc_lite_dashboard_options')
    for [option, value] in items(w:vimrc_lite_dashboard_options)
      call setwinvar(0, '&' . option, value)
    endfor
    unlet w:vimrc_lite_dashboard_options
  endif
endfunction

function! s:DashboardRender() abort
  if !get(b:, 'vimrc_lite_dashboard', 0) | return | endif
  let slogan = 'Les annees heureuses sont des annees perdues.'
  let width = strdisplaywidth(slogan)
  let [row, column] = win_screenpos(0)
  " 以整个屏幕为锚点，再换算到窗口内；空间不足时收回窗口边界。
  let left = (&columns - width) / 2 - column + 1
  let top = (&lines - &cmdheight - 1) / 2 - row + 1
  let indent = repeat(' ', max([0, min([left, winwidth(0) - width])]))
  let padding = max([0, min([top, winheight(0) - 1])])
  setlocal modifiable
  try
    silent %delete _
    call setline(1, repeat([''], padding) + [indent . slogan])
  finally
    setlocal nomodified nomodifiable
  endtry
  call cursor(1, 1)
  normal! zt
endfunction

" 文件树获得焦点后，也重绘仍然可见的首页。
function! s:DashboardRedraw() abort
  let origin = win_getid()
  try
    for window in getwininfo()
      if window.tabnr == tabpagenr() && getbufvar(window.bufnr, 'vimrc_lite_dashboard', 0)
        if exists('*win_execute')
          call win_execute(window.winid, 'noautocmd call ' . expand('<SID>') . 'DashboardRender()')
        else
          noautocmd call win_gotoid(window.winid)
          call s:DashboardRender()
        endif
      endif
    endfor
  finally
    if win_getid() != origin
      noautocmd call win_gotoid(origin)
    endif
  endtry
endfunction

function! s:DashboardEnter() abort
  if !get(b:, 'vimrc_lite_dashboard', 0)
    call s:DashboardLeave()
    call s:DashboardRedraw()
    return
  endif
  if !exists('w:vimrc_lite_dashboard_options')
    " 分屏继承首页选项时，也使用进入首页前的原始选项。
    let w:vimrc_lite_dashboard_options = copy(b:dashboard_window_options)
  endif
  setlocal nonumber norelativenumber nocursorline nocursorcolumn
  setlocal foldcolumn=0 signcolumn=no nofoldenable nowrap nolist nospell
  setlocal colorcolumn= scrolloff=0 sidescrolloff=0
  execute 'setlocal fillchars+=eob:\ '
  if winnr('$') == 1
    if !exists('s:dashboard_laststatus')
      let s:dashboard_laststatus = &laststatus
    endif
    if !exists('s:dashboard_showtabline')
      let s:dashboard_showtabline = &showtabline
    endif
    set laststatus=0 showtabline=0
  else
    call s:DashboardRestoreStatus()
  endif
  call s:DashboardRedraw()
endfunction

function! s:Dashboard() abort
  if get(b:, 'vimrc_lite_dashboard', 0)
    call s:DashboardEnter()
    return
  endif
  let options = {}
  for option in s:dashboard_options
    let options[option] = getwinvar(0, '&' . option)
  endfor
  enew
  let b:vimrc_lite_dashboard = 1
  let b:dashboard_window_options = options
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
  setlocal undolevels=-1 filetype=vimdashboard
  call s:DashboardEnter()
endfunction

function! s:DashboardStartup() abort
  if !get(g:, 'vimrc_lite_dashboard', 1) || s:dashboard_stdin
        \ || !(has('gui_running') || (has('ttyin') && has('ttyout')))
        \ || argc() || !empty(v:this_session) || tabpagenr('$') != 1 || winnr('$') != 1
        \ || len(getbufinfo({'buflisted': 1})) != 1 || &modified || &buftype !=# ''
        \ || !empty(bufname('%')) || line('$') != 1 || getline(1) !=# ''
    return
  endif
  " --cmd 可设置首页开关；-c、+cmd、-S 和 Ex/脚本启动交还调用者。
  let skip = 0
  for arg in v:argv[1:]
    if skip
      let skip = 0
    elseif index(['--cmd', '-u', '-U', '-i', '-T', '-w', '-W'], arg) >= 0
      let skip = 1
    elseif arg =~# '^+' || arg =~# '^-[cS]' || arg =~# '^-[a-zA-Z]*[eEs][a-zA-Z]*$'
      return
    endif
  endfor
  call s:Dashboard()
endfunction

command! Dashboard call <SID>Dashboard()
augroup vimrc_lite_dashboard
  autocmd!
  autocmd User VimrcLiteReload call s:DashboardLeave()
  autocmd User VimrcLiteSearchClosed call s:DashboardEnter()
  autocmd StdinReadPre * let s:dashboard_stdin = 1
  autocmd VimEnter * call s:DashboardStartup()
  autocmd WinLeave * call s:DashboardRestoreStatus()
  autocmd BufWinEnter,WinEnter,VimResized * call s:DashboardEnter()
  if exists('##WinResized')
    autocmd WinResized * call s:DashboardEnter()
  endif
augroup END
if get(b:, 'vimrc_lite_dashboard', 0)
  call s:DashboardEnter()
endif
