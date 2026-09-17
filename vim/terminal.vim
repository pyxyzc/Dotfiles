" 普通 shell 与 Git 共用终端生命周期；每次启动的状态由回调独立持有。
function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim terminal: ' . a:message
  echohl None
endfunction

function! s:Finish(state, timer) abort
  if a:state.done | return | endif
  if !bufexists(a:state.buf) || getbufvar(a:state.buf, '&buftype') !=# 'terminal'
    let a:state.done = 1
    return
  endif
  let a:state.done = 1
  let focus = win_getid()
  let return_to_origin = bufnr('%') == a:state.buf
  try
    " 先关窗口，避免直接删除最后一个 listed buffer 时生成空 buffer。
    for window in getbufinfo(a:state.buf)[0].windows
      if !win_gotoid(window) || bufnr('%') != a:state.buf | continue | endif
      if tabpagenr('$') == 1 && winnr('$') == 1
        confirm quit
      else
        close
      endif
    endfor
    if bufexists(a:state.buf) && empty(getbufinfo(a:state.buf)[0].windows)
      execute 'bwipeout ' . a:state.buf
    endif
  catch
    call s:Warn(v:exception)
  finally
    call win_gotoid(return_to_origin ? a:state.origin : focus)
  endtry
endfunction

function! s:Exited(state, job, status) abort
  let a:state.exited = 1
  if a:state.closed
    call timer_start(0, function('s:Finish', [a:state]))
  endif
endfunction

function! s:Closed(state, channel) abort
  let a:state.closed = 1
  " 两个事件都收到后只延迟清理一次；不轮询，也不丢弃剩余终端输出。
  if a:state.exited
    call timer_start(0, function('s:Finish', [a:state]))
  endif
endfunction

function! s:Open(command) abort
  if !has('terminal') || !has('timers')
    call s:Warn('requires Vim +terminal and +timers')
    return
  endif
  let command = empty(a:command) ? &shell : a:command
  let state = {'origin': win_getid(), 'buf': 0, 'done': 0, 'exited': 0, 'closed': 0}
  let directory = getcwd()
  let window = 0
  try
    tabnew
    let window = win_getid()
    let placeholder = bufnr('%')
    " 不启用 term_finish=close，由 Finish 明确控制窗口与 buffer 的清理顺序。
    let state.buf = term_start(command, {'curwin': 1, 'cwd': directory,
          \ 'exit_cb': function('s:Exited', [state]), 'close_cb': function('s:Closed', [state])})
    if !state.buf || job_status(term_getjob(state.buf)) ==# 'fail'
      throw 'could not start terminal: ' . command
    endif
    startinsert
  catch
    let error = v:exception
    if state.buf
      call s:Finish(state, 0)
    elseif window && win_gotoid(window)
          \ && bufnr('%') == placeholder && !&modified && empty(bufname('%'))
      close
      if bufexists(placeholder)
        execute 'bwipeout ' . placeholder
      endif
      call win_gotoid(state.origin)
    endif
    call s:Warn(error)
  endtry
endfunction

command! -nargs=* -complete=shellcmd VimTerminal call <SID>Open(<q-args>)
