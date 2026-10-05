" 手动会话使用 JSON 保存布局，不 source 可执行的会话脚本。
function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim session: ' . a:message
  echohl None
endfunction

function! s:Directory() abort
  if !exists('*sha256') || !exists('*json_encode') || !exists('*win_execute')
    throw 'requires Vim JSON, sha256 and win_execute support'
  endif
  let directory = VimLiteStateDir('sessions') . '/' . sha256(VimLiteProjectRoot())
  if !isdirectory(directory)
    call mkdir(directory, 'p', 0700)
  endif
  return directory
endfunction

function! s:Path(name) abort
  let name = empty(a:name) ? 'default' : a:name
  if name !~# '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$'
    throw 'session name must contain letters, digits, _, - or .'
  endif
  return s:Directory() . '/' . name . '.json'
endfunction

function! s:Capture(layout) abort
  if a:layout[0] ==# 'leaf'
    let window = a:layout[1]
    let info = getwininfo(window)[0]
    let buffer = info.bufnr
    let path = fnamemodify(bufname(buffer), ':p')
    if getbufvar(buffer, '&buftype') !=# '' || empty(bufname(buffer))
          \ || !filereadable(path) || isdirectory(path)
      return []
    endif
    call win_execute(window, 'let w:vimrc_lite_saved_view = winsaveview()')
    let view = gettabwinvar(info.tabnr, info.winnr, 'vimrc_lite_saved_view')
    call win_execute(window, 'unlet w:vimrc_lite_saved_view')
    return ['leaf', {'path': path, 'view': view, 'width': info.width,
          \ 'height': info.height, 'active': window == win_getid()}]
  endif
  let children = []
  for child in a:layout[1]
    let captured = s:Capture(child)
    if !empty(captured)
      call add(children, captured)
    endif
  endfor
  return empty(children) ? [] : len(children) == 1 ? children[0] : [a:layout[0], children]
endfunction

function! s:Save(name) abort
  let temporary = ''
  try
    let path = s:Path(a:name)
    let tabs = []
    for tab in gettabinfo()
      let layout = s:Capture(winlayout(tab.tabnr))
      if !empty(layout)
        call add(tabs, layout)
      endif
    endfor
    if empty(tabs)
      throw 'no saved files are visible; save a file before saving a session'
    endif
    let buffers = map(filter(getbufinfo({'buflisted': 1}),
          \ 'getbufvar(v:val.bufnr, "&buftype") ==# "" && !empty(v:val.name)'
          \ . ' && filereadable(v:val.name)'), 'fnamemodify(v:val.name, ":p")')
    let data = {'version': 1, 'root': VimLiteProjectRoot(), 'tabs': tabs, 'buffers': buffers}
    let temporary = path . '.tmp.' . getpid()
    call writefile([json_encode(data)], temporary)
    call setfperm(temporary, 'rw-------')
    if rename(temporary, path) != 0
      throw 'could not replace session file'
    endif
    echom 'Vim session: saved ' . fnamemodify(path, ':t:r')
          \ . ' (files/layout only; save file edits separately)'
  catch
    call s:Warn(v:exception)
  finally
    if !empty(temporary)
      call delete(temporary)
    endif
  endtry
endfunction

function! s:Validate(node, depth) abort
  if a:depth > 20 || type(a:node) != type([]) || len(a:node) != 2
    throw 'invalid session layout'
  endif
  if a:node[0] ==# 'leaf'
    let leaf = a:node[1]
    if type(leaf) != type({}) || type(get(leaf, 'path', 0)) != type('')
          \ || !filereadable(leaf.path) || isdirectory(leaf.path)
          \ || type(get(leaf, 'view', 0)) != type({})
      throw 'session contains an invalid or missing file'
    endif
    for [key, value] in items(leaf.view)
      if index(['lnum', 'col', 'coladd', 'curswant', 'topline', 'topfill',
            \ 'leftcol', 'skipcol'], key) < 0 || type(value) != type(0) || value < 0
        throw 'invalid saved view'
      endif
    endfor
    for key in ['width', 'height', 'active']
      if type(get(leaf, key, 0)) != type(0) || get(leaf, key, 0) < 0
        throw 'invalid window dimensions'
      endif
    endfor
    return
  endif
  if index(['row', 'col'], a:node[0]) < 0 || type(a:node[1]) != type([])
        \ || empty(a:node[1]) || len(a:node[1]) > 30
    throw 'invalid session layout'
  endif
  for child in a:node[1]
    call s:Validate(child, a:depth + 1)
  endfor
endfunction

function! s:Restore(node, windows) abort
  if a:node[0] ==# 'leaf'
    let leaf = a:node[1]
    execute 'edit ' . fnameescape(leaf.path)
    call winrestview(leaf.view)
    call add(a:windows, [win_getid(), leaf])
    return
  endif
  let windows = [win_getid()]
  for child in a:node[1][1:]
    execute a:node[0] ==# 'row' ? 'rightbelow vsplit' : 'belowright split'
    call add(windows, win_getid())
  endfor
  for index in range(len(windows))
    call win_gotoid(windows[index])
    call s:Restore(a:node[1][index], a:windows)
  endfor
endfunction

function! s:Load(name) abort
  let origin = win_getid()
  let original_tabs = tabpagenr('$')
  let building = 0
  try
    if !empty(filter(getbufinfo(), 'getbufvar(v:val.bufnr, "&modified")'))
      throw 'save or discard modified buffers before restoring a session'
    endif
    let path = s:Path(a:name)
    let data = json_decode(join(readfile(path), "\n"))
    if type(data) != type({}) || get(data, 'version', 0) != 1
          \ || get(data, 'root', '') !=# VimLiteProjectRoot()
          \ || type(get(data, 'tabs', 0)) != type([])
          \ || empty(data.tabs) || len(data.tabs) > 30
      throw 'invalid session or project root mismatch'
    endif
    for tab in data.tabs
      call s:Validate(tab, 0)
    endfor
    let buffers = get(data, 'buffers', [])
    if type(buffers) != type([])
      throw 'invalid session buffer list'
    endif
    for path in buffers
      if type(path) != type('') || !filereadable(path) || isdirectory(path)
        throw 'session contains an invalid or missing file'
      endif
    endfor
    let building = 1
    let windows = []
    for tab in data.tabs
      $tabnew
      call s:Restore(tab, windows)
    endfor
    for path in buffers
      execute 'badd ' . fnameescape(path)
    endfor
    for index in range(original_tabs)
      1tabclose
    endfor
    let building = 0
    let origin = windows[0][0]
    for [window, leaf] in windows
      call win_execute(window, 'vertical resize ' . min([&columns, leaf.width]))
      call win_execute(window, 'resize ' . min([&lines, leaf.height]))
      call win_execute(window, 'call winrestview(' . string(leaf.view) . ')')
      if leaf.active
        let origin = window
      endif
    endfor
    call win_gotoid(origin)
    echom 'Vim session: restored ' . fnamemodify(path, ':t:r')
  catch
    if building
      for index in range(len(data.tabs))
        if tabpagenr('$') <= original_tabs
          break
        endif
        let count = tabpagenr('$')
        silent! $tabclose
        if count == tabpagenr('$')
          break
        endif
      endfor
    endif
    call win_gotoid(origin)
    call s:Warn(v:exception)
  endtry
endfunction

function! s:Complete(lead, line, pos) abort
  try
    let paths = glob(s:Directory() . '/*.json', 0, 1)
    return filter(map(paths, 'fnamemodify(v:val, ":t:r")'), 'stridx(v:val, a:lead) == 0')
  catch
    return []
  endtry
endfunction

command! -nargs=? -complete=customlist,<SID>Complete VimSessionSave call <SID>Save(<q-args>)
command! -nargs=? -complete=customlist,<SID>Complete VimSessionLoad call <SID>Load(<q-args>)
command! VimSessionList echo join(<SID>Complete('', '', 0), "\n")
