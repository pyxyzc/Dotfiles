" 原生首页：普通文本和直接按键，不进入普通 buffer 列表。
let s:dashboard_options = ['number', 'relativenumber', 'cursorline', 'cursorcolumn',
      \ 'foldcolumn', 'signcolumn', 'foldenable', 'wrap', 'list', 'spell',
      \ 'colorcolumn', 'scrolloff', 'sidescrolloff', 'fillchars']
let s:dashboard_stdin = get(s:, 'dashboard_stdin', 0)

function! s:DashboardRestoreStatus() abort
  if exists('s:dashboard_laststatus')
    let &laststatus = s:dashboard_laststatus
    unlet s:dashboard_laststatus
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
  let indent = repeat(' ', max([0, (winwidth(0) - strdisplaywidth(slogan)) / 2]))
  let menu = ['[f]  Find file', '[n]  New file', '[e]  Browse directory',
        \ '[r]  Recent files', '[t]  Find text', '[c]  Config', '[q]  Quit']
  let lines = [indent . slogan, ''] + map(menu, 'indent . v:val')
  let padding = max([0, (winheight(0) - len(lines)) / 2])
  setlocal modifiable
  try
    silent %delete _
    call setline(1, repeat([''], padding) + lines)
  finally
    setlocal nomodified nomodifiable
  endtry
  call cursor(1, 1)
  normal! zt
endfunction

function! s:DashboardEnter() abort
  if !get(b:, 'vimrc_lite_dashboard', 0)
    call s:DashboardLeave()
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
    set laststatus=0
  else
    call s:DashboardRestoreStatus()
  endif
  call s:DashboardRender()
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
  nnoremap <nowait><buffer> f :find<Space>
  nnoremap <silent><nowait><buffer> n :enew<Bar>startinsert<CR>
  nnoremap <silent><nowait><buffer> e :execute 'Explore ' . fnameescape(getcwd())<CR>
  nnoremap <nowait><buffer> r :browse oldfiles<CR>
  nnoremap <silent><nowait><buffer> t :VimSearch<CR>
  nnoremap <silent><nowait><buffer> c :VimConfig<CR>
  nnoremap <silent><nowait><buffer> q :confirm qall<CR>
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
  autocmd StdinReadPre * let s:dashboard_stdin = 1
  autocmd VimEnter * call s:DashboardStartup()
  autocmd WinLeave * call s:DashboardRestoreStatus()
  autocmd BufWinEnter,WinEnter,VimResized * call s:DashboardEnter()
augroup END
if get(b:, 'vimrc_lite_dashboard', 0)
  call s:DashboardEnter()
endif
