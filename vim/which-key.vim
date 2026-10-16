" 前缀提示只绘制 UI；原映射、计数、寄存器和超时仍由 Vim 解析。
" SafeState 用于在原映射结束后恢复钩子；旧 Vim 保留 :VimKeys 查询。
let s:supported = exists('*popup_create') && exists('*timer_start')
      \ && exists('*maplist') && exists('##SafeState')
let s:buffers = get(s:, 'buffers', {})
let s:generation = get(s:, 'generation', 0) + 1
let s:suspended = get(s:, 'suspended', [])
let s:cancels = get(s:, 'cancels', [])
let s:pending = get(s:, 'pending', {})
let s:timer = get(s:, 'timer', -1)
let s:escape_timer = get(s:, 'escape_timer', -1)
let s:popup = get(s:, 'popup', 0)
let s:manual = 0
let s:key_names = get(s:, 'key_names', {' ': '<Space>', '<': '<lt>', '|': '<Bar>'})
let s:script_id = str2nr(matchstr(expand('<SID>'), '\d\+'))

function! s:Special(key) abort
  if a:key ==? '<leader>'
    return get(g:, 'mapleader', "\\")
  endif
  if a:key ==? '<localleader>'
    return get(g:, 'maplocalleader', "\\")
  endif
  " 仅将键名交给 eval；引号、反斜线和表达式不能进入字符串。
  let raw = a:key =~# '^<[-A-Za-z0-9_]\+>$' ? eval('"\' . a:key . '"') : a:key
  if raw !=# a:key
    let s:key_names[raw] = a:key
  endif
  return raw
endfunction

function! s:Raw(key) abort
  return substitute(a:key, '<[^<>]\+>', '\=s:Special(submatch(0))', 'g')
endfunction

function! s:Name(key) abort
  if exists('*keytrans')
    return substitute(keytrans(a:key), '|', '<Bar>', 'g')
  endif
  let tail = a:key
  let name = ''
  while !empty(tail)
    let next = s:First(tail)
    let name .= get(s:key_names, next, next)
    let tail = strpart(tail, strlen(next))
  endwhile
  return name
endfunction

function! s:First(key) abort
  if strlen(a:key) > 3 && strpart(a:key, 0, 2) ==# strpart("\<C-F6>", 0, 2)
    return strpart(a:key, 0, 3) . s:First(strpart(a:key, 3))
  endif
  " Vim 内部特殊键占三个字节；普通 Unicode 字符按完整码点处理。
  return char2nr(strpart(a:key, 0, 1)) == 128 ? strpart(a:key, 0, 3)
        \ : matchstr(a:key, '^.')
endfunction

function! s:Own(mapping) abort
  return get(a:mapping, 'sid', -1) == s:script_id
        \ && get(a:mapping, 'rhs', '') =~# '\%(<SID>\|<SNR>\d\+_\)Prefix('
endfunction

function! s:Hook(mode, key) abort
  execute a:mode . 'map <special><silent><buffer><nowait><expr> '
        \ . s:Name(a:key) . ' <SID>Prefix(' . string(s:Name(a:key))
        \ . ', ' . string(a:mode) . ')'
endfunction

function! s:Unhook(mode, key) abort
  if s:Own(maparg(s:Name(a:key), a:mode, 0, 1))
    execute a:mode . 'unmap <buffer> ' . s:Name(a:key)
  endif
endfunction

function! s:Hide() abort
  if s:timer != -1
    call timer_stop(s:timer)
    let s:timer = -1
  endif
  if s:popup
    call popup_close(s:popup)
    let s:popup = 0
  endif
endfunction

function! s:Finish() abort
  call s:Hide()
  if s:escape_timer != -1
    call timer_stop(s:escape_timer)
    let s:escape_timer = -1
  endif
  augroup vimrc_lite_which_key_pending
    autocmd!
  augroup END
  " 最短前缀最后注册，避免更长的候选映射遮住 <nowait> 钩子。
  for hook in s:cancels
    if hook.buffer == bufnr('%')
      let mapping = maparg(s:Name(hook.key), hook.mode, 0, 1)
      if get(mapping, 'sid', -1) == s:script_id && mapping.rhs =~# '\%(Cancel()\|Escape(\)'
        execute hook.mode . 'unmap <buffer> ' . s:Name(hook.key)
      endif
    endif
  endfor
  let s:cancels = []
  for hook in sort(s:suspended, {left, right -> strlen(right.key) - strlen(left.key)})
    if hook.buffer == bufnr('%') && empty(maparg(s:Name(hook.key), hook.mode, 0, 1))
      call s:Hook(hook.mode, hook.key)
    endif
  endfor
  let s:suspended = []
  let s:pending = {}
endfunction

function! s:Collect(roots) abort
  let maps = {'n': {}, 'x': {}}
  for mapping in maplist()
    if mapping.abbr || mapping.lhs =~? '^<Plug>' || s:Own(mapping)
      continue
    endif
    let key = has_key(mapping, 'lhsraw') ? mapping.lhsraw : s:Raw(mapping.lhs)
    if empty(filter(copy(a:roots), 'stridx(key, v:val) == 0'))
      continue
    endif
    if !exists('*keytrans')
      call s:Raw(mapping.lhs)
    endif
    for mode in ['n', 'x']
      let matches = mode ==# 'n' ? mapping.mode =~# '[n ]' : mapping.mode =~# '[xv ]'
      if matches && (!has_key(maps[mode], key) || mapping.buffer)
        let maps[mode][key] = mapping
      endif
    endfor
  endfor
  return maps
endfunction

function! s:Setup(force) abort
  if !a:force && !v:vim_did_enter
    return
  endif
  let buffer = bufnr('%')
  let old = get(s:buffers, buffer, {})
  if !a:force && get(old, 'generation', -1) == s:generation
        \ && get(old, 'filetype', '') ==# &filetype
    return
  endif
  call s:Finish()
  for hook in get(old, 'hooks', [])
    call s:Unhook(hook.mode, hook.key)
  endfor
  let state = {'generation': s:generation, 'filetype': &filetype,
        \ 'hooks': [], 'maps': {}, 'menus': {}, 'ancestors': {'n': {}, 'x': {}},
        \ 'cancel_blocked': {'n': {}, 'x': {}}}
  let s:buffers[buffer] = state
  if !s:supported || !get(g:, 'vimrc_lite_which_key', 1) || &buftype ==# 'terminal'
    return
  endif
  let roots = map(copy(get(g:, 'vimrc_lite_which_key_triggers', ['<leader>'])), 's:Raw(v:val)')
  call filter(roots, '!empty(v:val)')
  let state.maps = s:Collect(roots)
  for mode in ['n', 'x']
    let prefixes = {}
    for key in keys(state.maps[mode])
      let escape = stridx(key, "\<Esc>")
      if escape >= 0
        let state.cancel_blocked[mode][strpart(key, 0, escape)] = 1
      endif
      for root in roots
        if empty(root) || stridx(key, root) != 0 || key ==# root
          continue
        endif
        let prefix = root
        let tail = strpart(key, strlen(root))
        while !empty(tail)
          if has_key(state.maps[mode], prefix)
            break
          endif
          let prefixes[prefix] = 1
          let next = s:First(tail)
          let prefix .= next
          let tail = strpart(tail, strlen(next))
        endwhile
      endfor
    endfor
    for prefix in sort(keys(prefixes), {left, right -> strlen(right) - strlen(left)})
      let state.ancestors[mode][prefix] = []
      let head = ''
      let tail = prefix
      while !empty(tail)
        let next = s:First(tail)
        let head .= next
        let tail = strpart(tail, strlen(next))
        if has_key(prefixes, head)
          call add(state.ancestors[mode][prefix], head)
        endif
      endwhile
      call s:Hook(mode, prefix)
      call add(state.hooks, {'mode': mode, 'key': prefix})
    endfor
  endfor
endfunction

function! s:EscapeReady(mode, prefix, buffer, timer) abort
  if a:timer == s:escape_timer && a:buffer == bufnr('%') && !empty(s:pending)
    let s:escape_timer = -1
    let key = s:Name(a:prefix . "\<Esc>")
    if empty(maparg(key, a:mode, 0, 1))
      execute a:mode . 'noremap <special><silent><buffer><nowait><expr> '
            \ . key . ' <SID>Cancel()'
    endif
  endif
endfunction

function! s:Escape(lhs, mode) abort
  call s:Hide()
  let prefix = s:Raw(a:lhs)
  execute a:mode . 'unmap <buffer> ' . s:Name(prefix . "\<Esc>")
  let delay = &ttimeout && &ttimeoutlen >= 0 ? &ttimeoutlen : &timeoutlen
  let s:escape_timer = timer_start(max([0, delay]),
        \ function('s:EscapeReady', [a:mode, prefix, bufnr('%')]))
  " 先允许 Vim 在原 ttimeoutlen 内拼接终端分片，再用完整 Esc 映射取消。
  " t 标记让 Vim 照常解码终端序列；宏录制和回放期间不安装此映射。
  call feedkeys(prefix . "\<Esc>", 'it')
  return ''
endfunction

function! s:Cancel() abort
  call s:Finish()
  return "\<Esc>"
endfunction

function! s:Prefix(lhs, mode) abort
  let key = s:Raw(a:lhs)
  " 深层前缀整批到达时，一并挂起祖先钩子，避免回放再次经过根前缀。
  for ancestor in s:buffers[bufnr('%')].ancestors[a:mode][key]
    if s:Own(maparg(s:Name(ancestor), a:mode, 0, 1))
      call s:Unhook(a:mode, ancestor)
      call add(s:suspended, {'mode': a:mode, 'key': ancestor, 'buffer': bufnr('%')})
    endif
  endfor
  " 仅在等待期间接入 Esc，避免前缀回退对终端 Esc 再次计时。
  if (&timeout || &ttimeout) && empty(reg_recording()) && empty(reg_executing())
        \ && !has_key(s:buffers[bufnr('%')].cancel_blocked[a:mode], key)
    let cancel = key . "\<Esc>"
    execute a:mode . 'noremap <special><silent><buffer><nowait><expr> '
          \ . s:Name(cancel) . ' <SID>Escape(' . string(s:Name(key))
          \ . ', ' . string(a:mode) . ')'
    call add(s:cancels, {'mode': a:mode, 'key': cancel, 'buffer': bufnr('%')})
  endif
  if empty(s:pending)
    augroup vimrc_lite_which_key_pending
      autocmd!
      autocmd SafeState * call s:Finish()
      autocmd BufLeave,WinLeave,InsertEnter,CmdlineEnter,FocusLost,VimLeavePre * call s:Finish()
    augroup END
  endif
  let shown = s:popup != 0
  if s:timer != -1
    call timer_stop(s:timer)
  endif
  let s:pending = {'key': key, 'mode': a:mode, 'buffer': bufnr('%'), 'window': win_getid()}
  let delay = shown || s:manual ? 0 : max([0, get(g:, 'vimrc_lite_which_key_delay', 200)])
  let s:manual = 0
  " 宏中的回放只经过原生映射路径，不绘制提示、不启动计时器。
  let s:timer = empty(reg_executing()) && empty(reg_recording())
        \ ? timer_start(delay, function('s:Render')) : -1
  " 原生展开前缀；Ignore 避免同 lhs 的递归防护禁止首键重映射。
  " 不读取按键、不改 timeoutlen、不执行 RHS，也不额外回填 typeahead。
  return "\<Ignore>" . key
endfunction

function! s:Description(mapping) abort
  let custom = get(g:, 'vimrc_lite_which_key_labels', {})
  let key = s:Name(get(a:mapping, 'lhsraw', s:Raw(a:mapping.lhs)))
  let description = get(custom, key, exists('*VimKeyDescription')
        \ ? VimKeyDescription(a:mapping) : a:mapping.rhs)
  return substitute(get(split(description, ' / '), 0, ''), '[\r\n\t]', ' ', 'g')
endfunction

function! s:Menu(state, mode, prefix) abort
  let cache = a:mode . ':' . a:prefix
  if has_key(a:state.menus, cache)
    return a:state.menus[cache]
  endif
  let entries = {}
  for [key, mapping] in items(a:state.maps[a:mode])
    if stridx(key, a:prefix) != 0 || key ==# a:prefix
      continue
    endif
    let tail = strpart(key, strlen(a:prefix))
    let next = s:First(tail)
    if !has_key(entries, next)
      let entries[next] = {'key': s:Name(next), 'count': 0, 'label': '', 'group': 0}
    endif
    let entry = entries[next]
    let entry.count += 1
    let entry.group = entry.group || tail !=# next
    if tail ==# next
      let entry.label = s:Description(mapping)
    endif
  endfor
  let groups = {'a': '标签页', 'b': 'Buffer', 'c': '代码 / LSP', 'f': '搜索',
        \ 'g': 'Git', 'm': 'Markdown', 'n': '消息', 'p': 'Pin', 'r': '重命名 / 任务',
        \ 's': '会话', 't': '终端', 'x': '结果列表'}
  let rows = []
  for key in sort(keys(entries))
    let entry = entries[key]
    let label = empty(entry.label) ? get(groups, key, '更多按键') : entry.label
    call add(rows, printf('%-7s %s%s', entry.key, label,
          \ entry.group ? ' + (' . entry.count . ')' : ''))
  endfor
  let a:state.menus[cache] = rows
  return rows
endfunction

function! s:Filter(id, key) abort
  if a:key ==# "\<Ignore>"
    return 0
  endif
  " 只关闭提示，不消费任何按键；mapping=1 保留原生映射解析。
  call s:Hide()
  return 0
endfunction

function! s:Closed(id, result) abort
  if s:popup == a:id
    let s:popup = 0
  endif
endfunction

function! s:Render(timer) abort
  if a:timer != s:timer || empty(s:pending)
    return
  endif
  let s:timer = -1
  let pending = s:pending
  if pending.buffer != bufnr('%') || pending.window != win_getid()
        \ || mode(1) !~# '^[nvV\x16]$' || !empty(reg_executing()) || !empty(reg_recording())
    return
  endif
  let rows = s:Menu(s:buffers[pending.buffer], pending.mode, pending.key)
  if empty(rows) || &columns < 12 || &lines < 6
    return
  endif
  let width = min([&columns - 4, 100])
  let columns = max([1, width / 32])
  let cell = width / columns
  let height = (len(rows) + columns - 1) / columns
  let lines = []
  for row in range(height)
    let line = ''
    for column in range(columns)
      let index = column * height + row
      if index < len(rows)
        let text = strcharpart(rows[index], 0, cell - 2)
        while strdisplaywidth(text) > cell - 2
          let text = strcharpart(text, 0, strchars(text) - 1)
        endwhile
        let line .= text . repeat(' ', cell - strdisplaywidth(text))
      endif
    endfor
    call add(lines, line)
  endfor
  let options = {'pos': 'botleft', 'line': &lines - &cmdheight - 1, 'col': 2,
        \ 'minwidth': width, 'maxwidth': width, 'maxheight': max([1, &lines / 2 - 3]),
        \ 'padding': [0, 1, 0, 1], 'border': [], 'borderchars': ['─', '│', '─', '│'],
        \ 'title': ' 按键 ' . s:Name(pending.key) . ' · '
        \ . (pending.mode ==# 'n' ? '普通' : '选区') . ' · Esc 取消 ',
        \ 'mapping': 1, 'filter': function('s:Filter'), 'filtermode': 'nx',
        \ 'callback': function('s:Closed'), 'highlight': 'Pmenu', 'borderhighlight': ['Comment'],
        \ 'scrollbar': 1, 'zindex': 90, 'drag': 0}
  if s:popup && !empty(popup_getpos(s:popup))
    call popup_settext(s:popup, lines)
    call popup_setoptions(s:popup, options)
  else
    let s:popup = popup_create(lines, options)
  endif
endfunction

function! s:Forget(buffer) abort
  if has_key(s:buffers, a:buffer)
    call remove(s:buffers, a:buffer)
  endif
endfunction

function! s:Ready() abort
  let s:generation += 1
  if v:vim_did_enter
    call s:Setup(1)
  endif
endfunction

function! s:Refresh() abort
  let s:generation += 1
  call s:Setup(1)
endfunction

function! s:Enable(enabled) abort
  let g:vimrc_lite_which_key = a:enabled
  call s:Refresh()
endfunction

function! s:Manual(prefix) abort
  if !s:supported
    VimKeys
    return
  endif
  call s:Setup(1)
  let prefix = empty(a:prefix) ? '<leader>' : a:prefix
  if !s:Own(maparg(s:Name(s:Raw(prefix)), 'n', 0, 1))
    echo 'Vim which-key: no free prefix; use :VimKeys or :VimWhichKeyEnable'
    return
  endif
  let s:manual = 1
  call feedkeys(s:Raw(prefix), 't')
endfunction

function! VimWhichKeyStatus() abort
  if s:popup && empty(popup_getpos(s:popup))
    let s:popup = 0
  endif
  return {'supported': s:supported, 'enabled': get(g:, 'vimrc_lite_which_key', 1),
        \ 'timer': s:timer, 'escape_timer': s:escape_timer,
        \ 'popup': s:popup, 'pending': !empty(s:pending)}
endfunction

call s:Finish()
command! -nargs=? VimWhichKey call <SID>Manual(<q-args>)
command! VimWhichKeyRefresh call <SID>Refresh()
command! VimWhichKeyEnable call <SID>Enable(1)
command! VimWhichKeyDisable call <SID>Enable(0)
augroup vimrc_lite_which_key
  autocmd!
  autocmd User VimrcLiteReady call s:Ready()
  autocmd VimEnter * call s:Setup(0)
  autocmd BufEnter * call s:Setup(0)
  autocmd FileType * call s:Setup(0)
  autocmd BufWipeout * call s:Forget(expand('<abuf>'))
augroup END
