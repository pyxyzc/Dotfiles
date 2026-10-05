" 按需读取项目任务；列表参数直接交给 job_start，不隐式执行 shell 文本。
let s:active = get(s:, 'active', {})
let s:last = get(s:, 'last', {})

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim task: ' . a:message
  echohl None
endfunction

function! s:Config(root) abort
  let tasks = deepcopy(get(g:, 'vimrc_lite_tasks', {}))
  let path = a:root . '/.vim-lite-tasks.json'
  if filereadable(path)
    let config = json_decode(join(readfile(path), "\n"))
    if type(config) != type({}) || type(get(config, 'tasks', 0)) != type({})
      throw 'expected a JSON object containing a tasks object: ' . path
    endif
    let tasks = config.tasks
  endif
  if type(tasks) != type({})
    throw 'g:vimrc_lite_tasks must be a dictionary'
  endif
  return tasks
endfunction

function! s:Complete(lead, line, pos) abort
  try
    return filter(sort(keys(s:Config(VimLiteProjectRoot()))),
          \ 'stridx(v:val, a:lead) == 0')
  catch
    return []
  endtry
endfunction

function! s:Output(state, channel, message) abort
  if len(a:state.lines) < get(g:, 'vimrc_lite_task_max_lines', 10000)
    let limit = max([256, get(g:, 'vimrc_lite_task_line_bytes', 16384)])
    if strlen(a:message) > limit
      let a:state.truncated = 1
    endif
    call add(a:state.lines, strpart(a:message, 0, limit))
  else
    let a:state.truncated = 1
  endif
endfunction

function! s:Finish(state) abort
  if a:state.done || !a:state.closed || !has_key(a:state, 'status')
    return
  endif
  let a:state.done = 1
  if has_key(a:state, 'poll')
    call timer_stop(a:state.poll)
  endif
  let title = a:state.name . ' (exit ' . a:state.status . ')'
  if get(a:state, 'cancelled', 0)
    let title .= ' cancelled'
  endif
  if a:state.truncated
    call add(a:state.lines, '[Output limit reached; lines or long-line suffixes omitted]')
  endif
  let lines = ['VimTask directory: ' . a:state.root] + a:state.lines
  let format = '%DVimTask directory: %f,' . a:state.errorformat
  let parsed = getqflist({'lines': lines, 'efm': format}).items
  call filter(parsed, 'v:val.valid')
  call setqflist([], 'r', {'id': a:state.qfid, 'title': title, 'items': parsed})
  let s:last = a:state
  if s:active is a:state
    let s:active = {}
  endif
  echom 'Vim task: ' . title . '; ' . len(parsed) . ' quickfix entries'
endfunction

function! s:Exited(state, job, status) abort
  let a:state.status = a:status
  call s:Finish(a:state)
endfunction

function! s:Closed(state, channel) abort
  let a:state.closed = 1
  call s:Finish(a:state)
endfunction

function! s:Poll(state, timer) abort
  if a:state.done
    call timer_stop(a:timer)
    return
  endif
  call job_status(a:state.job)
  if ch_status(job_getchannel(a:state.job)) ==# 'closed'
    let a:state.closed = 1
  endif
  call s:Finish(a:state)
endfunction

function! s:Run(name) abort
  if !has('job') || !has('channel') || !has('timers') || !exists('*json_decode')
    call s:Warn('requires Vim +job, +channel, +timers and JSON support')
    return
  endif
  if !empty(s:active)
    call s:Warn('a task is running; use :VimTaskStop before starting another')
    return
  endif
  try
    let root = VimLiteProjectRoot()
    let tasks = s:Config(root)
    let name = a:name
    if empty(name)
      let names = sort(keys(tasks))
      if empty(names)
        throw 'no tasks; configure .vim-lite-tasks.json or g:vimrc_lite_tasks'
      endif
      let choice = inputlist(['Choose task (0 cancels):']
            \ + map(copy(names), 'string(v:key + 1) . ": " . v:val'))
      if choice < 1 || choice > len(names)
        return
      endif
      let name = names[choice - 1]
    endif
    if !has_key(tasks, name)
      throw 'unknown task: ' . name
    endif
    let task = tasks[name]
    let command = type(task) == type([]) ? task : get(task, 'cmd', 0)
    if type(command) != type([]) || empty(command)
          \ || !empty(filter(copy(command), 'type(v:val) != type("")'))
          \ || empty(command[0])
      throw 'task cmd must be a nonempty list of strings'
    endif
    let format = type(task) == type({}) ? get(task, 'errorformat', &errorformat)
          \ : &errorformat
    if type(format) != type('')
      throw 'task errorformat must be a string'
    endif
    let state = {'name': name, 'root': root, 'lines': [], 'closed': 0,
          \ 'done': 0, 'truncated': 0, 'errorformat': format}
    call setqflist([], ' ', {'title': name . ' (running)', 'items': []})
    let state.qfid = getqflist({'id': 0}).id
    let s:active = state
    let s:last = state
    let state.job = job_start(command, {'cwd': root, 'in_io': 'null',
          \ 'out_mode': 'nl', 'err_mode': 'nl',
          \ 'out_cb': function('s:Output', [state]), 'err_cb': function('s:Output', [state]),
          \ 'exit_cb': function('s:Exited', [state]), 'close_cb': function('s:Closed', [state])})
    if job_status(state.job) ==# 'fail'
      throw 'could not start: ' . command[0]
    endif
    if state.done
      return
    endif
    let state.poll = timer_start(20, function('s:Poll', [state]), {'repeat': -1})
    echom 'Vim task: running ' . name . ' in ' . root
  catch
    if exists('state') && s:active is state
      let state.done = 1
      let state.status = -1
      let s:active = {}
      call setqflist([], 'r', {'id': state.qfid, 'title': name . ' (failed to start)',
            \ 'items': []})
    endif
    call s:Warn(v:exception)
  endtry
endfunction

function! s:Stop() abort
  if !empty(s:active)
    let s:active.cancelled = 1
    call job_stop(s:active.job, 'kill')
  else
    call s:Warn('no task is running')
  endif
endfunction

function! s:Status() abort
  let state = empty(s:active) ? s:last : s:active
  if empty(state)
    echom 'Vim task: no task has run'
  else
    echom 'Vim task: ' . state.name . ' / '
          \ . (state.done ? 'exit ' . state.status : 'running') . ' / ' . state.root
  endif
endfunction

function! s:ShowOutput() abort
  if empty(s:last)
    call s:Warn('no task output')
    return
  endif
  botright new
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
  call setline(1, ['Task: ' . s:last.name . ' / ' . s:last.root] + s:last.lines)
  setlocal nomodifiable
  nnoremap <silent><buffer> q :close<CR>
endfunction

command! -nargs=? -complete=customlist,<SID>Complete VimTask call <SID>Run(<q-args>)
command! VimTaskStop call <SID>Stop()
command! VimTaskStatus call <SID>Status()
command! VimTaskOutput call <SID>ShowOutput()
