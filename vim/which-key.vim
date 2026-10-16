" 快速输入沿用 Vim 的原生映射；面板展开后暂停映射超时，等候用户选择。
" 完成或取消时恢复输入选项和钩子；旧 Vim 保留 :VimKeys 查询。
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
let s:controls = get(s:, 'controls', [])
let s:timeout = get(s:, 'timeout', -1)
let s:panel_rows = 0
let s:geometry = {}
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
    let popup = s:popup
    let s:popup = 0
    call popup_close(popup)
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
  for control in s:controls
    if control.buffer == bufnr('%') && s:OwnControl(maparg(control.lhs, control.mode, 0, 1))
      execute control.mode . 'unmap <buffer> ' . control.lhs
    endif
  endfor
  let s:controls = []
  if s:timeout != -1
    let &timeout = s:timeout
    let s:timeout = -1
  endif
  let s:panel_rows = 0
  let s:geometry = {}
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
  let s:pending = {'key': key, 'mode': a:mode, 'buffer': bufnr('%'),
        \ 'window': win_getid(), 'page': 0}
  let delay = shown || s:manual ? 0 : max([0, get(g:, 'vimrc_lite_which_key_delay', 200)])
  let s:manual = 0
  " 宏中的回放只经过原生映射路径，不绘制提示、不启动计时器。
  let s:timer = empty(reg_executing()) && empty(reg_recording())
        \ ? timer_start(delay, function('s:Render')) : -1
  " 原生展开前缀；Ignore 避免同 lhs 的递归防护禁止首键重映射。
  " 不读取按键、不改 timeoutlen、不执行 RHS，也不额外回填 typeahead。
  return "\<Ignore>" . key
endfunction

function! s:Highlights() abort
  highlight default VimrcLiteWhichKeyNormal guifg=#c0caf5 guibg=#1f2335
        \ ctermfg=153 ctermbg=235
  highlight default VimrcLiteWhichKeyBorder guifg=#3b4261 guibg=#1f2335
        \ ctermfg=60 ctermbg=235
  highlight default VimrcLiteWhichKeyTitle guifg=#7aa2f7 gui=bold ctermfg=111 cterm=bold
  highlight default VimrcLiteWhichKeyKey guifg=#7dcfff gui=bold ctermfg=117 cterm=bold
  highlight default VimrcLiteWhichKeyGroup guifg=#bb9af7 ctermfg=141
  highlight default VimrcLiteWhichKeyMuted guifg=#737aa2 ctermfg=103
  if exists('*prop_type_add')
    for name in ['Title', 'Key', 'Group', 'Muted']
      let type = 'VimrcLiteWhichKey' . name
      if empty(prop_type_get(type))
        call prop_type_add(type, {'highlight': type, 'combine': 1})
      endif
    endfor
  endif
endfunction

function! s:OwnControl(mapping) abort
  return get(a:mapping, 'sid', -1) == s:script_id
        \ && get(a:mapping, 'rhs', '') =~# '\%(Resume(\|Page(\)'
endfunction

function! s:Control(suffix, rhs) abort
  let pending = s:pending
  let key = pending.key . a:suffix
  let state = s:buffers[pending.buffer]
  if has_key(state.maps[pending.mode], key) || has_key(state.ancestors[pending.mode], key)
    return 0
  endif
  let lhs = s:Name(key)
  let mapping = maparg(lhs, pending.mode, 0, 1)
  if !empty(mapping)
    return s:OwnControl(mapping)
  endif
  execute pending.mode . 'map <special><silent><buffer><nowait><expr> ' . lhs . ' ' . a:rhs
  call add(s:controls, {'lhs': lhs, 'mode': pending.mode, 'buffer': pending.buffer})
  return 1
endfunction

function! s:Resume(lhs) abort
  let lhs = s:Name(s:Raw(a:lhs) . s:Raw('<Plug>') . '(VimLiteWhichKeyHold)')
  if s:OwnControl(maparg(lhs, s:pending.mode, 0, 1))
    execute s:pending.mode . 'unmap <buffer> ' . lhs
  endif
  return "\<Ignore>" . s:Raw(a:lhs)
endfunction

function! s:Hold() abort
  if s:timeout != -1
    return
  endif
  let s:timeout = &timeout
  set notimeout
  " 已在等待的原生映射不会因选项改变自动醒来；只在面板首次出现时重入一次。
  " 仍由 Vim 解析按键，不使用读取循环，也不延长快速连按的路径。
  let signal = s:Raw('<Plug>') . '(VimLiteWhichKeyHold)'
  if s:Control(signal, expand('<SID>') . 'Resume(' . string(s:Name(s:pending.key)) . ')')
    call feedkeys(signal, 'm')
  endif
endfunction

function! s:Page(direction) abort
  let s:pending.page = max([0, s:pending.page + a:direction])
  call s:QueueRender()
  return "\<Ignore>" . s:pending.key
endfunction

function! s:QueueRender() abort
  if !empty(s:pending) && s:popup
    if s:timer != -1
      call timer_stop(s:timer)
    endif
    let s:timer = timer_start(0, function('s:Render'))
  endif
endfunction

function! s:Description(mapping) abort
  let custom = get(g:, 'vimrc_lite_which_key_labels', {})
  let key = s:Name(get(a:mapping, 'lhsraw', s:Raw(a:mapping.lhs)))
  let description = get(custom, key, exists('*VimKeyDescription')
        \ ? VimKeyDescription(a:mapping) : a:mapping.rhs)
  if description ==# a:mapping.rhs
    let description = '自定义映射'
  endif
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
  let menu = []
  for key in sort(keys(entries))
    let entry = entries[key]
    let entry.label = empty(entry.label) ? get(groups, key, '更多按键') : entry.label
    call add(menu, entry)
  endfor
  let a:state.menus[cache] = menu
  return menu
endfunction

function! s:Clip(text, width) abort
  if strdisplaywidth(a:text) <= a:width
    return a:text
  endif
  let text = strcharpart(a:text, 0, max([0, a:width - 1]))
  while strdisplaywidth(text) > a:width - 1
    let text = strcharpart(text, 0, strchars(text) - 1)
  endwhile
  return text . '…'
endfunction

function! s:Property(row, column, length, name) abort
  if a:length > 0 && exists('*prop_type_add')
    call add(a:row.props, {'col': a:column, 'length': a:length,
          \ 'type': 'VimrcLiteWhichKey' . a:name})
  endif
endfunction

function! s:Bar(left, right, width, style) abort
  let right = s:Clip(a:right, a:width / 2)
  let left = s:Clip(a:left, max([1, a:width - strdisplaywidth(right) - 2]))
  let row = {'text': left . repeat(' ', a:width - strdisplaywidth(left)
        \ - strdisplaywidth(right)) . right, 'props': []}
  call s:Property(row, 1, strlen(left), a:style)
  call s:Property(row, strlen(row.text) - strlen(right) + 1, strlen(right), 'Muted')
  return row
endfunction

function! s:Layout(menu, width) abort
  let columns = min([6, len(a:menu), max([1, a:width / 24])])
  let rows = (len(a:menu) + columns - 1) / columns
  let columns = (len(a:menu) + rows - 1) / rows
  let compact = &lines - &cmdheight < 8
  let limit = max([1, (&lines - &cmdheight) * 2 / 3 - (compact ? 2 : 4)])
  let s:panel_rows = min([limit, max([s:panel_rows, 4, rows])])
  let capacity = columns * s:panel_rows
  let pages = (len(a:menu) + capacity - 1) / capacity
  let s:pending.page = min([s:pending.page, pages - 1])
  let start = s:pending.page * capacity
  let visible = min([capacity, len(a:menu) - start])
  let used_rows = (visible + columns - 1) / columns
  let label = substitute(s:Name(s:pending.key), '<Space>', 'SPC ', 'g')
  let label = substitute(label, '\s\+$', '', '')
  let mode = s:pending.mode ==# 'n' ? '普通模式' : '选区模式'
  let lines = [s:Bar(label . '  /  快捷键', mode . ' · ' . len(a:menu) . ' 项', a:width, 'Title')]
  if !compact
    call add(lines, {'text': '', 'props': []})
  endif
  for row in range(s:panel_rows)
    let line = {'text': '', 'props': []}
    for column in range(columns)
      let cell = column == columns - 1 ? a:width - column * (a:width / columns)
            \ : a:width / columns
      let index = start + column * used_rows + row
      let text = ''
      if row < used_rows && index < len(a:menu)
        let entry = a:menu[index]
        let key = s:Clip(entry.key, min([7, cell / 3]))
        let key .= repeat(' ', max([0, 2 - strdisplaywidth(key)]))
        let description = (entry.group ? '+ ' : '') . entry.label
        let description = s:Clip(description, max([1, cell - strdisplaywidth(key) - 5]))
        let offset = strlen(line.text)
        let text = key . ' → ' . description
        call s:Property(line, offset + 1, strlen(key), 'Key')
        call s:Property(line, offset + strlen(key) + 1, strlen(' → '), 'Muted')
        if entry.group
          call s:Property(line, offset + strlen(key . ' → ') + 1, strlen(description), 'Group')
        endif
      endif
      let line.text .= text . repeat(' ', max([0, cell - strdisplaywidth(text)]))
    endfor
    call add(lines, line)
  endfor
  if !compact
    call add(lines, {'text': '', 'props': []})
  endif
  let help = '按键选择   Esc 取消'
  if pages > 1
    let help = a:width < 40 ? 'Esc  ^D/^U' : help . '   Ctrl-D / Ctrl-U 翻页'
  endif
  call add(lines, s:Bar(help, pages > 1 ? (s:pending.page + 1) . '/' . pages : '',
        \ a:width, 'Muted'))
  return lines
endfunction

function! s:Closed(id, result) abort
  if s:popup == a:id
    let s:popup = 0
    call s:Finish()
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
  let menu = s:Menu(s:buffers[pending.buffer], pending.mode, pending.key)
  if empty(menu) || &columns < 12 || &lines < 6
    return
  endif
  let width = &columns - 4
  let lines = s:Layout(menu, width)
  let options = {'pos': 'botleft', 'line': &lines - &cmdheight, 'col': 1,
        \ 'minwidth': width, 'maxwidth': width, 'minheight': len(lines), 'maxheight': len(lines),
        \ 'padding': [0, 2, 0, 2], 'border': [1, 0, 0, 0], 'borderchars': ['─'],
        \ 'mapping': 1, 'callback': function('s:Closed'), 'wrap': 0,
        \ 'highlight': 'VimrcLiteWhichKeyNormal', 'borderhighlight': ['VimrcLiteWhichKeyBorder'],
        \ 'scrollbar': 0, 'zindex': 90, 'drag': 0}
  let geometry = {'line': options.line, 'col': 1, 'minwidth': width, 'maxwidth': width,
        \ 'minheight': len(lines), 'maxheight': len(lines)}
  if s:popup && !empty(popup_getpos(s:popup))
    call popup_settext(s:popup, lines)
    if geometry != s:geometry
      call popup_move(s:popup, geometry)
    endif
  else
    let s:popup = popup_create(lines, options)
  endif
  let s:geometry = geometry
  call s:Hold()
  call s:Control("\<C-d>", expand('<SID>') . 'Page(1)')
  call s:Control("\<C-u>", expand('<SID>') . 'Page(-1)')
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
        \ 'popup': s:popup, 'pending': !empty(s:pending), 'held': s:timeout != -1,
        \ 'prefix': empty(s:pending) ? '' : s:Name(s:pending.key)}
endfunction

call s:Finish()
call s:Highlights()
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
  autocmd ColorScheme * call s:Highlights()
  autocmd VimResized * call s:QueueRender()
  autocmd BufWipeout * call s:Forget(expand('<abuf>'))
augroup END
