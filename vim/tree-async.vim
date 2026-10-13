" 大目录属性查询在独立 Vim 中运行；主进程分批接收完整快照。
let s:scans = get(s:, 'scans', {})
let s:snapshot = {}
let s:fallback = 0
let s:worker = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/tree-list.vim'

function! VimTreeSnapshot(directory) abort
  return get(s:snapshot, a:directory, -1)
endfunction

function! VimTreeEntryIgnored(name, directory) abort
  let ignored = get(g:, 'vimrc_lite_tree_ignore', [])
  if empty(ignored)
    return 0
  endif
  if !exists('s:ignore_key') || s:ignore_key !=# ignored
    let s:ignore_key = copy(ignored)
    let s:patterns = map(copy(ignored), '[v:val =~# "/$", glob2regpat(v:val)]')
  endif
  for pattern in s:patterns
    let name = pattern[0] && a:directory ? a:name . '/' : a:name
    if name =~# pattern[1]
      return 1
    endif
  endfor
  return 0
endfunction

function! s:Eligible() abort
  return !s:fallback && empty(s:snapshot) && get(g:, 'vimrc_lite_tree_async', 1)
        \ && get(g:, 'vimrc_lite_netrw_fast_listing', 1)
        \ && has('unix') && has('job') && has('channel') && has('timers')
        \ && exists('*json_encode') && exists('*json_decode') && filereadable(s:worker)
        \ && get(w:, 'netrw_liststyle', -1) == 3
        \ && !get(g:, 'netrw_dynamic_maxfilenamelen', 0)
        \ && get(g:, 'netrw_sort_by', 'name') =~# '^\%(n\|ext\)'
        \ && get(g:, 'vimrc_lite_tree_collect_ready', 0)
endfunction

function! s:Forget(state, ...) abort
  if get(s:scans, string(a:state.buffer), {}) is a:state
    call remove(s:scans, string(a:state.buffer))
  endif
  if has_key(a:state, 'timer')
    call timer_stop(a:state.timer)
  endif
  call delete(a:state.request)
  if bufexists(a:state.buffer)
    call setbufvar(a:state.buffer, 'vimrc_lite_tree_listing_pending', get(a:000, 0, 0))
  endif
endfunction

function! s:Apply(state) abort
  if winbufnr(a:state.window) != a:state.buffer
        \ || getwinvar(a:state.window, 'netrw_treetop', '') !=# a:state.root
        \ || getwinvar(a:state.window, 'netrw_liststyle', -1) != 3
    return
  endif
  if a:state.options !=# s:Options()
    call call(function(g:vimrc_lite_tree_refresh), [a:state.root])
    return
  endif
  let s:snapshot = a:state.entries
  let s:fallback = get(a:state, 'failed', 0)
  try
    call call(function(g:vimrc_lite_tree_refresh), [a:state.root])
  finally
    let s:snapshot = {}
    let s:fallback = 0
  endtry
endfunction

function! s:Options() abort
  return [&wildignore, &suffixes, string(get(g:, 'vimrc_lite_tree_ignore', [])),
        \ get(g:, 'vimrc_lite_tree_async', 1), get(g:, 'vimrc_lite_netrw_fast_listing', 1),
        \ get(g:, 'netrw_sort_by', 'name')]
endfunction

function! s:Drain(state, timer) abort
  if get(s:scans, string(a:state.buffer), {}) isnot a:state
    call timer_stop(a:timer)
    return
  endif
  if winbufnr(a:state.window) != a:state.buffer
    call job_stop(a:state.job)
    call s:Forget(a:state)
    return
  endif
  let started = reltime()
  try
    while !empty(a:state.queue) && reltimefloat(reltime(started)) < 0.004
      let value = json_decode(remove(a:state.queue, 0))
      if has_key(value, 'done')
        let a:state.received = 1
      else
        let a:state.entries[value.directory] += value.entries
      endif
    endwhile
  catch
    let a:state.failed = 1
    let a:state.error = v:exception
    call job_stop(a:state.job)
  endtry
  let status = job_status(a:state.job)
  if status !=# 'dead' || ch_status(job_getchannel(a:state.job)) !=# 'closed'
        \ || !empty(a:state.queue)
    return
  endif
  let a:state.failed = get(a:state, 'failed', 0) || !a:state.received
        \ || get(job_info(a:state.job), 'exitval', -1) != 0
  call s:Forget(a:state)
  if a:state.failed
    let a:state.entries = {}
    echohl WarningMsg
    echom 'Vim tree: background listing failed; using native listing. ' . a:state.error
    echohl None
  endif
  let origin = win_getid()
  try
    noautocmd let found = win_gotoid(a:state.window)
    if found
      call s:Apply(a:state)
    endif
  finally
    noautocmd call win_gotoid(origin)
  endtry
endfunction

function! s:Output(state, channel, message) abort
  call add(a:state.queue, a:message)
endfunction

function! s:Error(state, channel, message) abort
  let a:state.error = strpart(a:state.error . a:message, 0, 4096)
endfunction

function! s:Queue(root, files) abort
  let entry_count = 0
  try
    for [directory, files] in items(a:files)
      let names = exists('*readdir') ? readdir(directory)
            \ : call(function(g:vimrc_lite_tree_collect), [directory])
      let entry_count += len(names)
      if join(names, '') =~# '[\r\n]'
        return 0
      endif
    endfor
  catch
    return 0
  endtry
  if entry_count < max([1, get(g:, 'vimrc_lite_tree_async_threshold', 1000)])
    return 0
  endif
  call VimTreeCancelListing(bufnr('%'))
  let state = {'root': a:root, 'window': win_getid(), 'buffer': bufnr('%'),
        \ 'request': tempname(), 'queue': [], 'entries': deepcopy(get(w:, 'netrw_treedict', {})),
        \ 'received': 0, 'error': '', 'options': s:Options()}
  for directory in keys(a:files)
    let state.entries[directory] = []
  endfor
  try
    call writefile([json_encode({'files': a:files,
          \ 'backend': get(g:, 'vimrc_lite_tree_listing_backend', 'glob'),
          \ 'wildignore': &wildignore, 'suffixes': &suffixes,
          \ 'ignore': get(g:, 'vimrc_lite_tree_ignore', [])})], state.request)
    call setfperm(state.request, 'rw-------')
    let binary = exists('v:progpath') ? v:progpath : exepath('vim')
    let state.job = job_start([binary, '-Nu', 'NONE', '-i', 'NONE', '-n', '-es',
          \ '-S', s:worker, '--', state.request], {'in_io': 'null',
          \ 'out_cb': function('s:Output', [state]), 'err_cb': function('s:Error', [state])})
    if job_status(state.job) ==# 'fail'
      call delete(state.request)
      return 0
    endif
    let s:scans[string(state.buffer)] = state
    let b:vimrc_lite_tree_listing_pending = 1
    let state.timer = timer_start(1, function('s:Drain', [state]), {'repeat': -1})
    return 1
  catch
    call delete(state.request)
    return 0
  endtry
endfunction

function! VimTreeQueueListing(directory, files) abort
  let root = get(w:, 'netrw_treetop', a:directory)
  return s:Eligible() ? s:Queue(root, {a:directory: a:files}) : 0
endfunction

function! VimTreeAsyncRefresh(directory) abort
  if !s:Eligible()
    return 0
  endif
  let directories = keys(get(w:, 'netrw_treedict', {}))
  if index(directories, a:directory) < 0
    call add(directories, a:directory)
  endif
  let files = {}
  for directory in directories
    if isdirectory(directory)
      let files[directory] = []
    endif
  endfor
  return s:Queue(get(w:, 'netrw_treetop', a:directory), files)
endfunction

function! VimTreeCancelListing(buffer, ...) abort
  let buffers = a:buffer > 0 ? [string(a:buffer)] : keys(s:scans)
  for buffer in buffers
    if has_key(s:scans, buffer)
      let state = s:scans[buffer]
      call job_stop(state.job)
      call s:Forget(state, get(a:000, 0, 0))
    endif
  endfor
endfunction

function! s:Resume() abort
  let origin = win_getid()
  try
    for window in getwininfo()
      if getbufvar(window.bufnr, 'vimrc_lite_tree_listing_pending', 0)
        noautocmd call win_gotoid(window.winid)
        let root = get(w:, 'netrw_treetop', b:netrw_curdir)
        if !VimTreeAsyncRefresh(root)
          let b:vimrc_lite_tree_listing_pending = 0
          call call(function(g:vimrc_lite_tree_refresh), [root])
        endif
      endif
    endfor
  finally
    noautocmd call win_gotoid(origin)
  endtry
endfunction

function! VimTreeStatusLabel() abort
  return has_key(s:scans, string(bufnr('%'))) ? '[tree: loading]' : ''
endfunction

command! VimTreeListStatus echo empty(s:scans) ? 'no listings running' : len(s:scans) . ' listings'
command! VimTreeListCancel call VimTreeCancelListing(0)

augroup vimrc_lite_tree_listing
  autocmd!
  autocmd BufWipeout * call VimTreeCancelListing(str2nr(expand('<abuf>')))
  autocmd User VimrcLiteReload call VimTreeCancelListing(0, 1)
  autocmd User VimrcLiteReady call s:Resume()
  autocmd VimLeavePre * call VimTreeCancelListing(0)
augroup END
