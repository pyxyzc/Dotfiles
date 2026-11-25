" 显式启动的离线预览。仅文本变更触发同步，发送前按时间预算捕获快照。
let s:directory = fnamemodify(expand('<sfile>:p'), ':h')
let s:preview = {}

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Markdown preview: ' . a:message
  echohl None
endfunction

function! VimMarkdownPreviewStop() abort
  if empty(s:preview)
    return
  endif
  let previous = s:preview
  let s:preview = {}
  call timer_stop(get(previous, 'timer', -1))
  if has_key(previous, 'job') && job_status(previous.job) ==# 'run'
    call job_stop(previous.job)
  endif
  unlet! g:vimrc_lite_markdown_preview_url
endfunction

function! VimMarkdownPreviewInfo() abort
  return empty(s:preview) ? {'running': 0, 'tick': -1, 'inflight': 0, 'url': ''}
        \ : {'running': 1, 'tick': s:preview.tick, 'inflight': s:preview.inflight,
        \ 'url': s:preview.url}
endfunction

function! s:Schedule(delay) abort
  if empty(s:preview)
    return
  endif
  call timer_stop(get(s:preview, 'timer', -1))
  let s:preview.timer = timer_start(a:delay, function('<SID>Capture'))
endfunction

function! s:Capture(timer) abort
  if empty(s:preview) || !bufloaded(s:preview.buf)
    return
  endif
  let s:preview.timer = -1
  if mode(1) !~# '^c' && getchar(1) != 0
    call s:Schedule(10)
    return
  endif
  if s:preview.inflight
    let s:preview.dirty = 1
    return
  endif
  let buf = s:preview.buf
  let tick = getbufvar(buf, 'changedtick')
  let snapshot = get(s:preview, 'snapshot', {})
  if empty(snapshot) || snapshot.tick != tick
    let snapshot = {'tick': tick, 'next': 1, 'lines': [], 'bytes': 0}
    let s:preview.snapshot = snapshot
  endif
  let last = getbufinfo(buf)[0].linecount
  let started = reltime()
  while snapshot.next <= last
    let stop = min([last, snapshot.next + 63])
    let lines = getbufline(buf, snapshot.next, stop)
    for text in lines
      let snapshot.bytes += strlen(text) + 1
    endfor
    if snapshot.bytes > 1024 * 1024
      call s:Warn('preview limited to 1 MiB; source editing remains available')
      call VimMarkdownPreviewStop()
      return
    endif
    call extend(snapshot.lines, lines)
    let snapshot.next = stop + 1
    if reltimefloat(reltime(started)) >= 0.003
      call s:Schedule(1)
      return
    endif
  endwhile
  let path = fnamemodify(bufname(buf), ':p')
  let path = empty(path) ? getcwd() . '/Untitled.md' : path
  let payload = {'text': join(snapshot.lines, "\n"), 'path': path,
        \ 'root': fnamemodify(path, ':h'), 'name': fnamemodify(path, ':t'), 'tick': tick,
        \ 'line': s:preview.line}
  let s:preview.inflight = 1
  let s:preview.dirty = 0
  let s:preview.tick = tick
  let s:preview.snapshot = {}
  try
    call ch_sendraw(job_getchannel(s:preview.job), json_encode(payload) . "\n")
  catch
    call s:Warn(v:exception)
    call VimMarkdownPreviewStop()
  endtry
endfunction

function! s:Output(channel, message) abort
  if empty(s:preview) || a:channel != job_getchannel(s:preview.job)
    return
  endif
  try
    let payload = json_decode(a:message)
  catch
    return
  endtry
  if has_key(payload, 'url')
    let s:preview.url = payload.url
    let g:vimrc_lite_markdown_preview_url = payload.url
    echo payload.url
    if s:preview.open && empty($SSH_CONNECTION) && empty($SSH_TTY)
      let browser = get(g:, 'vimrc_lite_markdown_browser', ['xdg-open'])
      if type(browser) == type([]) && !empty(browser) && executable(browser[0])
        call job_start(browser + [payload.url], {'stoponexit': ''})
      endif
    endif
  elseif has_key(payload, 'ack')
    let s:preview.inflight = 0
    if s:preview.dirty || getbufvar(s:preview.buf, 'changedtick') != s:preview.tick
      call s:Schedule(60)
    endif
  endif
endfunction

function! s:Exit(job, status) abort
  if !empty(s:preview) && a:job == s:preview.job
    call VimMarkdownPreviewStop()
  endif
endfunction

function! VimMarkdownPreviewStart(no_browser) abort
  if &filetype !=# 'markdown' || &buftype !=# '' || !get(g:, 'vimrc_lite_markdown', 1)
        \ || get(b:, 'vimrc_lite_large_file', 0)
    return
  endif
  if !executable('python3') || !has('job') || !has('channel')
    call s:Warn('python3 and Vim +job +channel are required')
    return
  endif
  if !empty(s:preview)
    call VimMarkdownPreviewStop()
  endif
  let s:preview = {'buf': bufnr('%'), 'tick': -1, 'timer': -1, 'inflight': 0,
        \ 'dirty': 1, 'snapshot': {}, 'open': !a:no_browser, 'url': '', 'line': line('.')}
  let s:preview.job = job_start(['python3', s:directory . '/markdown/preview.py'],
        \ {'in_io': 'pipe', 'out_mode': 'nl', 'out_cb': function('<SID>Output'),
        \ 'exit_cb': function('<SID>Exit'), 'err_io': 'null', 'noblock': 1})
  if job_status(s:preview.job) !=# 'run'
    call s:Warn('failed to start preview server')
    call VimMarkdownPreviewStop()
    return
  endif
  call s:Schedule(1)
endfunction

function! s:Changed() abort
  if !empty(s:preview) && bufnr('%') == s:preview.buf
        \ && b:changedtick != s:preview.tick
    let s:preview.line = line('.')
    let s:preview.snapshot = {}
    call s:Schedule(250)
  endif
endfunction

function! s:Wipe(buf) abort
  if !empty(s:preview) && s:preview.buf == a:buf
    call VimMarkdownPreviewStop()
  endif
endfunction

function! s:Filetype() abort
  if &filetype !=# 'markdown'
    call s:Wipe(bufnr('%'))
  endif
endfunction

augroup vimrc_lite_markdown_preview
  autocmd!
  autocmd TextChanged,TextChangedI * call <SID>Changed()
  autocmd BufUnload * call <SID>Wipe(str2nr(expand('<abuf>')))
  autocmd FileType * call <SID>Filetype()
augroup END
