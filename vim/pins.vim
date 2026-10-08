" 行级 pin：文字锚点跟随编辑，持久状态只保存数据，不执行项目脚本。
let s:supported = v:version >= 802 && has('textprop') && exists('*listener_add')
      \ && exists('*prop_find') && exists('*json_encode') && exists('*sha256')
      \ && exists('*timer_start')
let s:projects = get(s:, 'projects', {})
let s:buffers = get(s:, 'buffers', {})
let s:next_id = get(s:, 'next_id', 1)
let s:type = 'VimrcLitePinAnchor'

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim pins: ' . a:message
  echohl None
endfunction

function! s:Highlights() abort
  highlight default VimrcLitePin guibg=#2de2c2 guifg=#1a1b26 gui=NONE
        \ ctermbg=43 ctermfg=234 cterm=NONE
endfunction

function! s:StatePath(root) abort
  let home = empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME
  return home . '/vim-lite/pins/' . sha256(a:root) . '.json'
endfunction

function! s:ValidRecord(record) abort
  if type(a:record) != v:t_dict || type(get(a:record, 'line', '')) != v:t_number
        \ || a:record.line < 1 || type(get(a:record, 'text', 0)) != v:t_string
        \ || type(get(a:record, 'hash', 0)) != v:t_string
        \ || a:record.hash !~# '^\x\{64}$'
    return 0
  endif
  for key in ['before', 'after']
    let lines = get(a:record, key, 0)
    if type(lines) != v:t_list || len(lines) > 2
          \ || !empty(filter(copy(lines), 'type(v:val) != v:t_string'))
      return 0
    endif
  endfor
  return 1
endfunction

function! s:Project(root) abort
  if has_key(s:projects, a:root)
    return s:projects[a:root]
  endif
  let project = {'root': a:root, 'files': {}, 'error': 0}
  let s:projects[a:root] = project
  let path = s:StatePath(a:root)
  if !filereadable(path)
    return project
  endif
  try
    let data = json_decode(join(readfile(path), "\n"))
    if type(data) != v:t_dict || get(data, 'version', 0) != 1
          \ || get(data, 'root', '') !=# a:root || type(get(data, 'files', 0)) != v:t_dict
      throw 'invalid pin state'
    endif
    for [file, records] in items(data.files)
      if file !~# '^/' || type(records) != v:t_list
        throw 'invalid pin file entry'
      endif
      for record in records
        if !s:ValidRecord(record)
          throw 'invalid pin anchor'
        endif
      endfor
    endfor
    let project.files = data.files
  catch
    let project.error = 1
    call s:Warn('cannot read ' . path . ': ' . v:exception . '; original state preserved')
  endtry
  return project
endfunction

function! s:Store(project) abort
  let temporary = ''
  try
    if a:project.error
      throw 'invalid state file; changes remain in memory'
    endif
    let directory = VimLiteStateDir('pins')
    let path = directory . '/' . sha256(a:project.root) . '.json'
    let files = filter(copy(a:project.files), '!empty(v:val)')
    let data = {'version': 1, 'root': a:project.root, 'files': files}
    let temporary = path . '.tmp.' . getpid()
    if writefile([json_encode(data)], temporary) != 0
      throw 'could not write pin state'
    endif
    call setfperm(temporary, 'rw-------')
    if rename(temporary, path) != 0
      throw 'could not replace pin state'
    endif
    return 1
  catch
    call s:Warn('could not save pins: ' . v:exception)
    return 0
  finally
    if !empty(temporary)
      call delete(temporary)
    endif
  endtry
endfunction

function! s:Records(state) abort
  let project = s:Project(a:state.root)
  if !has_key(project.files, a:state.path)
    let project.files[a:state.path] = []
  endif
  return project.files[a:state.path]
endfunction

function! s:Capture(lines, line, hash) abort
  return {'line': a:line, 'text': a:lines[a:line - 1], 'hash': a:hash,
        \ 'before': a:line > 1 ? a:lines[max([0, a:line - 3]) : a:line - 2] : [],
        \ 'after': a:line < len(a:lines) ? a:lines[a:line : a:line + 1] : []}
endfunction

function! s:Locate(record, lines, hash, candidates) abort
  if a:record.hash ==# a:hash && a:record.line <= len(a:lines)
        \ && a:lines[a:record.line - 1] ==# a:record.text
    return a:record.line
  endif
  let candidates = get(a:candidates, a:record.text, [])
  if len(candidates) == 1
    return candidates[0]
  endif
  let best = 0
  let score = 0
  for line in candidates
    let context = s:Capture(a:lines, line, a:hash)
    let matched = 0
    for key in ['before', 'after']
      let actual = key ==# 'before' ? reverse(copy(context[key])) : context[key]
      let expected = key ==# 'before' ? reverse(copy(a:record[key])) : a:record[key]
      for index in range(min([len(actual), len(expected)]))
        let matched += actual[index] ==# expected[index]
      endfor
    endfor
    if matched > score
      let score = matched
      let best = line
    elseif matched == score
      let best = 0
    endif
  endfor
  return best
endfunction

function! s:Anchor(state, id, line) abort
  call prop_add(a:line, 1, {'bufnr': a:state.buffer, 'type': s:type,
        \ 'id': str2nr(a:id), 'length': 0})
endfunction

function! s:Positions(state) abort
  let positions = {}
  let start = 1
  let last = getbufinfo(a:state.buffer)[0].linecount
  while start <= last
    let found = prop_find({'bufnr': a:state.buffer, 'type': s:type,
          \ 'lnum': start, 'col': 1}, 'f')
    if empty(found)
      break
    endif
    for property in prop_list(found.lnum, {'bufnr': a:state.buffer})
      if get(property, 'type', '') ==# s:type
        let positions[string(property.id)] = found.lnum
      endif
    endfor
    let start = found.lnum + 1
  endwhile
  return positions
endfunction

function! s:Sync(state, changes) abort
  let positions = s:Positions(a:state)
  for [id, line] in items(positions)
    if !has_key(a:state.pins, id)
      " 已清除的 ID 即使随代码撤销重新出现，也不再成为 pin。
      call prop_remove({'bufnr': a:state.buffer, 'type': s:type, 'id': str2nr(id),
            \ 'both': 1, 'all': 1})
    endif
  endfor
  let empty_buffer = !empty(a:changes) && getbufinfo(a:state.buffer)[0].linecount == 1
        \ && getbufline(a:state.buffer, 1)[0] ==# ''
  for [id, pin] in items(a:state.pins)
    if empty_buffer && has_key(positions, id)
      for change in a:changes
        if change.added < 0 && pin.line >= change.lnum
              \ && pin.line < change.lnum - change.added
          " 删除最后一行后 Vim 保留空 buffer，有时也保留旧锚点。
          call prop_remove({'bufnr': a:state.buffer, 'type': s:type, 'id': str2nr(id),
                \ 'both': 1, 'all': 1})
          call remove(positions, id)
          break
        endif
      endfor
    endif
    if has_key(positions, id)
      let pin.line = positions[id]
      let pin.status = 'live'
      continue
    endif
    let line = pin.line
    let replaced = 0
    for change in a:changes
      if line == 0
        break
      endif
      if change.added == 0
        let replaced = replaced || (line >= change.lnum && line < change.end)
      elseif change.added > 0
        if line >= change.end
          let line += change.added
        endif
      elseif line >= change.lnum && line < change.lnum - change.added
        let line = 0
      elseif line >= change.lnum - change.added
        let line += change.added
      endif
    endfor
    if line > 0 && replaced
      " setline()/setbufline() 会丢弃文字属性，但并没有删除这一行。
      call s:Anchor(a:state, id, line)
      let pin.line = line
      let pin.status = 'live'
    elseif pin.line > 0
      let pin.line = 0
      let pin.status = 'deleted'
    endif
  endfor
endfunction

function! s:CleanWindow(window) abort
  for match in getmatches(a:window)
    if match.group ==# 'VimrcLitePin'
      call matchdelete(match.id, a:window)
    endif
  endfor
endfunction

function! s:Lines(state) abort
  let lines = {}
  for pin in values(a:state.pins)
    if pin.line > 0
      let lines[string(pin.line)] = pin.line
    endif
  endfor
  return sort(values(lines), 'n')
endfunction

function! s:Render(state) abort
  let positions = []
  for line in s:Lines(a:state)
    let length = strlen(getbufline(a:state.buffer, line)[0])
    if length > 0
      call add(positions, [line, 1, length])
    endif
  endfor
  for window in getwininfo()
    if window.bufnr != a:state.buffer
      continue
    endif
    call s:CleanWindow(window.winid)
    for index in range(0, len(positions) - 1, 8)
      call matchaddpos('VimrcLitePin', positions[index : index + 7], -1, -1,
            \ {'window': window.winid})
    endfor
  endfor
endfunction

function! s:Refresh(buffer) abort
  if !has_key(s:buffers, a:buffer) || !bufloaded(a:buffer)
    return
  endif
  let state = s:buffers[a:buffer]
  call listener_flush(a:buffer)
  if state.timer != -1
    call timer_stop(state.timer)
    let state.timer = -1
  endif
  call s:Sync(state, [])
  call s:Render(state)
endfunction

function! s:Timer(buffer, timer) abort
  if has_key(s:buffers, a:buffer)
    let s:buffers[a:buffer].timer = -1
    call s:Refresh(a:buffer)
  endif
endfunction

function! s:Changed(buffer, start, end, added, changes) abort
  if !has_key(s:buffers, a:buffer)
    return
  endif
  let state = s:buffers[a:buffer]
  call s:Sync(state, a:changes)
  if state.timer == -1
    let state.timer = timer_start(0, function('s:Timer', [a:buffer]))
  endif
endfunction

function! s:Enter() abort
  call s:CleanWindow(win_getid())
  if !s:supported || &buftype !=# '' || empty(bufname('%'))
    return
  endif
  let buffer = bufnr('%')
  if has_key(s:buffers, buffer)
    call s:Refresh(buffer)
    return
  endif
  let root = VimLiteProjectRoot()
  let path = resolve(expand('%:p'))
  let records = get(s:Project(root).files, path, [])
  if empty(records)
    return
  endif
  call s:Attach(buffer, root, path, records)
endfunction

function! s:Attach(buffer, root, path, records) abort
  let state = {'buffer': a:buffer, 'root': a:root, 'path': a:path, 'pins': {},
        \ 'listener': 0, 'timer': -1}
  let s:buffers[a:buffer] = state
  let candidates = {}
  if !empty(a:records)
    let lines = getbufline(a:buffer, 1, '$')
    let hash = sha256(join(lines, "\n"))
    for index in range(len(lines))
      let text = lines[index]
      if !has_key(candidates, text)
        let candidates[text] = []
      endif
      call add(candidates[text], index + 1)
    endfor
  endif
  for record in a:records
    let id = string(s:next_id)
    let s:next_id += 1
    let line = s:Locate(record, lines, hash, candidates)
    let state.pins[id] = {'record': record, 'line': line,
          \ 'status': line > 0 ? 'live' : 'pending'}
    if line > 0
      call s:Anchor(state, id, line)
    endif
  endfor
  let state.listener = listener_add(function('s:Changed'), a:buffer)
  call s:Render(state)
  let pending = len(filter(copy(state.pins), 'v:val.status ==# "pending"'))
  if pending > 0
    call s:Warn(pending . ' pin(s) await reliable relocation; records preserved')
  endif
  return state
endfunction

function! s:Current() abort
  if !s:supported
    call s:Warn('requires Vim 8.2/9 with +textprop, listeners, JSON and sha256')
    return {}
  endif
  if &buftype !=# '' || empty(bufname('%'))
    call s:Warn('pin a named normal file; save unnamed buffers first')
    return {}
  endif
  call s:Enter()
  let buffer = bufnr('%')
  if !has_key(s:buffers, buffer)
    call s:Attach(buffer, VimLiteProjectRoot(), resolve(expand('%:p')), [])
  endif
  return s:buffers[buffer]
endfunction

function! s:Remove(state, id) abort
  let pin = remove(a:state.pins, a:id)
  call filter(s:Records(a:state), 'v:val isnot pin.record')
  call prop_remove({'bufnr': a:state.buffer, 'type': s:type, 'id': str2nr(a:id),
        \ 'both': 1, 'all': 1})
endfunction

function! s:Toggle(first, last) abort
  let state = s:Current()
  if empty(state)
    return
  endif
  let lines = getline(1, '$')
  let hash = sha256(join(lines, "\n"))
  for line in range(a:first, a:last)
    let ids = keys(filter(copy(state.pins), 'v:val.line == line'))
    if !empty(ids)
      for id in ids
        call s:Remove(state, id)
      endfor
    else
      let id = string(s:next_id)
      let s:next_id += 1
      let record = s:Capture(lines, line, hash)
      let state.pins[id] = {'record': record, 'line': line, 'status': 'live'}
      call add(s:Records(state), record)
      call s:Anchor(state, id, line)
    endif
  endfor
  call s:Store(s:Project(state.root))
  call s:Render(state)
endfunction

function! s:Clear(scope) abort
  let state = s:Current()
  if empty(state)
    return
  endif
  let project = s:Project(state.root)
  if a:scope ==# 'line'
    for id in keys(filter(copy(state.pins), 'v:val.line == line(".")'))
      call s:Remove(state, id)
    endfor
  else
    for target in values(s:buffers)
      if target.root ==# state.root && (a:scope ==# 'project' || target.path ==# state.path)
        let target.pins = {}
        call prop_remove({'bufnr': target.buffer, 'type': s:type, 'all': 1})
        call s:Render(target)
      endif
    endfor
    if a:scope ==# 'project'
      let project.files = {}
    else
      let project.files[state.path] = []
    endif
  endif
  call s:Store(project)
  call s:Render(state)
endfunction

function! s:Jump(direction, count) abort
  let state = s:Current()
  if empty(state)
    return
  endif
  let lines = s:Lines(state)
  if empty(lines)
    return
  endif
  let candidates = filter(copy(lines), a:direction > 0 ? 'v:val > line(".")'
        \ : 'v:val < line(".")')
  let first = empty(candidates) ? (a:direction > 0 ? lines[0] : lines[-1])
        \ : a:direction > 0 ? candidates[0] : candidates[-1]
  let index = (index(lines, first) + a:direction * ((a:count - 1) % len(lines))
        \ + len(lines)) % len(lines)
  if lines[index] != line('.')
    normal! m'
    call cursor(lines[index], 1)
    normal! ^zv
  endif
endfunction

function! s:Saved(buffer) abort
  if !has_key(s:buffers, a:buffer)
    return
  endif
  call s:Refresh(a:buffer)
  let state = s:buffers[a:buffer]
  let lines = getbufline(a:buffer, 1, '$')
  let hash = sha256(join(lines, "\n"))
  let records = []
  for pin in values(state.pins)
    if pin.line > 0
      call extend(pin.record, s:Capture(lines, pin.line, hash), 'force')
      call add(records, pin.record)
    elseif pin.status ==# 'pending'
      call add(records, pin.record)
    endif
  endfor
  let project = s:Project(state.root)
  let project.files[state.path] = records
  call s:Store(project)
endfunction

function! s:Drop(buffer) abort
  if !has_key(s:buffers, a:buffer)
    return
  endif
  let state = remove(s:buffers, a:buffer)
  call listener_remove(state.listener)
  if state.timer != -1
    call timer_stop(state.timer)
  endif
  for window in getwininfo()
    if window.bufnr == a:buffer
      call s:CleanWindow(window.winid)
    endif
  endfor
endfunction

function! s:Renamed() abort
  let buffer = bufnr('%')
  if !has_key(s:buffers, buffer)
    return
  endif
  let state = s:buffers[buffer]
  let path = resolve(expand('%:p'))
  let root = VimLiteProjectRoot()
  if path ==# state.path && root ==# state.root
    return
  endif
  let original = s:Project(state.root)
  let records = get(original.files, state.path, [])
  if has_key(original.files, state.path)
    call remove(original.files, state.path)
  endif
  let state.root = root
  let state.path = path
  let target = s:Project(root)
  let target.files[path] = records
  call s:Store(original)
  if target isnot original
    call s:Store(target)
  endif
endfunction

command! -range VimPinToggle call <SID>Toggle(<line1>, <line2>)
command! VimPinClear call <SID>Clear('line')
command! VimPinClearFile call <SID>Clear('file')
command! VimPinClearProject call <SID>Clear('project')
command! -count=1 VimPinNext call <SID>Jump(1, <count>)
command! -count=1 VimPinPrev call <SID>Jump(-1, <count>)

call s:Highlights()
if s:supported && empty(prop_type_get(s:type))
  call prop_type_add(s:type, {})
endif
augroup vimrc_lite_pins
  autocmd!
  autocmd ColorScheme * call s:Highlights()
  if s:supported
    autocmd BufEnter,WinEnter * call s:Enter()
    autocmd TextChanged,TextChangedI * call s:Refresh(str2nr(expand('<abuf>')))
    autocmd BufWritePost * call s:Saved(str2nr(expand('<abuf>')))
    autocmd BufUnload,BufWipeout * call s:Drop(str2nr(expand('<abuf>')))
    autocmd BufFilePost * call s:Renamed()
  endif
augroup END
if s:supported
  call s:Enter()
endif
