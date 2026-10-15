" Markdown 原生阅读层：装饰只影响显示，保留原始文本、撤销和保存语义。
let s:types = []
let s:virtual = -1
let s:resize_timer = -1

function! s:Colors() abort
  highlight VimMarkdownViewBorder guifg=#3d59a1 ctermfg=61
  highlight VimMarkdownViewTableHead gui=bold cterm=bold guifg=#7dcfff guibg=#24283b
        \ ctermfg=117 ctermbg=235
  highlight VimMarkdownViewTableCell guifg=#c0caf5 guibg=#1f2335 ctermfg=153 ctermbg=235
  highlight VimMarkdownViewChecked gui=strikethrough cterm=strikethrough
        \ guifg=#565f89 ctermfg=60
  highlight VimMarkdownViewTodo guifg=#e0af68 guibg=#302a26 ctermfg=179 ctermbg=235
  highlight VimMarkdownViewDone guifg=#9ece6a guibg=#232d29 ctermfg=149 ctermbg=235
  highlight VimMarkdownViewDoing guifg=#7aa2f7 guibg=#20263a ctermfg=111 ctermbg=235
  highlight VimMarkdownViewBlocked guifg=#f7768e guibg=#30232e ctermfg=210 ctermbg=235
  highlight VimMarkdownViewNote gui=bold cterm=bold guifg=#7dcfff guibg=#1c2c3b
        \ ctermfg=117 ctermbg=235
  highlight VimMarkdownViewTip gui=bold cterm=bold guifg=#9ece6a guibg=#232d29
        \ ctermfg=149 ctermbg=235
  highlight VimMarkdownViewImportant gui=bold cterm=bold guifg=#bb9af7 guibg=#28243b
        \ ctermfg=183 ctermbg=235
  highlight VimMarkdownViewWarning gui=bold cterm=bold guifg=#e0af68 guibg=#302a26
        \ ctermfg=179 ctermbg=235
  highlight VimMarkdownViewCaution gui=bold cterm=bold guifg=#f7768e guibg=#30232e
        \ ctermfg=210 ctermbg=235
  highlight VimMarkdownViewQuote guifg=#9aa5ce guibg=#202234 ctermfg=146 ctermbg=235
  highlight VimMarkdownViewComment gui=italic cterm=italic guifg=#565f89 ctermfg=60
  highlight VimMarkdownViewCodeLabel guifg=#bb9af7 guibg=#16161e ctermfg=183 ctermbg=234
  highlight VimMarkdownViewCodeBody guifg=NONE guibg=#16161e ctermfg=NONE ctermbg=234
  highlight VimMarkdownViewLink guifg=#7aa2f7 ctermfg=111
  highlight VimMarkdownViewImage guifg=#7dcfff ctermfg=117
  for name in ['Note', 'Tip', 'Important', 'Warning', 'Caution']
    execute 'highlight VimMarkdownView' . name . 'Body gui=NONE cterm=NONE guifg=#a9b1d6'
          \ . ' ctermfg=146 guibg=' . synIDattr(hlID('VimMarkdownView' . name), 'bg', 'gui')
          \ . ' ctermbg=235'
  endfor
endfunction

function! s:Virtual() abort
  if s:virtual >= 0
    return s:virtual
  endif
  let s:virtual = 0
  if !has('textprop')
    return 0
  endif
  let previous_error = v:errmsg
  let name = 'VimMarkdownViewProbe'
  try
    call prop_type_add(name, {'bufnr': bufnr('%')})
    let s:virtual = prop_add(1, 1, {'type': name, 'text': ' '}) < 0
  catch
  finally
    call prop_type_delete(name, {'bufnr': bufnr('%')})
    let v:errmsg = previous_error
  endtry
  return s:virtual
endfunction

function! s:Type(group) abort
  let name = 'VimMarkdownView_' . a:group
  if index(s:types, name) < 0
    if empty(prop_type_get(name))
      call prop_type_add(name, {'highlight': a:group, 'priority': 80, 'combine': 1})
    endif
    call add(s:types, name)
  endif
  return name
endfunction

function! s:Row(plan, line) abort
  let key = string(a:line)
  if !has_key(a:plan.rows, key)
    let a:plan.rows[key] = {'marks': [], 'masks': [], 'fallback': [], 'insert': [],
          \ 'borders': [], 'replace': [], 'fill': 0}
  endif
  return a:plan.rows[key]
endfunction

function! s:Plain(text) abort
  let text = a:text
  let literals = []
  for span in reverse(s:InlineCode(text))
    let literal = strpart(text, span[0], span[1] - span[0])
    let delimiter = strlen(matchstr(literal, '^`\+'))
    call add(literals, strpart(literal, delimiter, strlen(literal) - 2 * delimiter))
    let token = nr2char(1) . (len(literals) - 1) . nr2char(2)
    let text = strpart(text, 0, span[0]) . token . strpart(text, span[1])
  endfor
  let text = substitute(text, '!\?\[\([^]]*\)\]([^)]*)', '\1', 'g')
  let text = substitute(text, '\*\*\([^*]\+\)\*\*', '\1', 'g')
  let text = substitute(text, '\*\([^*]\+\)\*', '\1', 'g')
  let text = substitute(text, '\~\~\(.\{-}\)\~\~', '\1', 'g')
  let text = substitute(text, '\\\([|*_`\[\]]\)', '\1', 'g')
  for index in range(len(literals))
    let token = nr2char(1) . index . nr2char(2)
    let text = substitute(text, token, '\=literals[index]', 'g')
  endfor
  return text
endfunction

function! s:Pad(text, width, alignment) abort
  let gap = max([0, a:width - strdisplaywidth(a:text)])
  let left = a:alignment ==# 'right' ? gap : a:alignment ==# 'center' ? gap / 2 : 0
  return repeat(' ', left) . a:text . repeat(' ', gap - left)
endfunction

function! s:Edge(widths, left, middle, right) abort
  return a:left . join(map(copy(a:widths), 'repeat("─", v:val + 2)'), a:middle) . a:right
endfunction

function! s:Table(plan, lines, first, last) abort
  let cells = map(copy(a:lines[a:first - 1:a:last - 1]), 'VimMarkdownCells(v:val)')
  let columns = len(cells[0])
  if columns < 2 || !empty(filter(copy(cells), 'len(v:val) != columns'))
    return 0
  endif
  let alignment = map(copy(cells[1]), 'v:val =~# "^:.*:$" ? "center"'
        \ . ' : v:val =~# ":$" ? "right" : "left"')
  let widths = repeat([3], columns)
  for index in range(len(cells))
    if index == 1
      continue
    endif
    let cells[index] = map(cells[index], 's:Plain(v:val)')
    for column in range(columns)
      let widths[column] = max([widths[column], strdisplaywidth(cells[index][column])])
    endfor
  endfor
  for index in range(len(cells))
    let row = s:Row(a:plan, a:first + index)
    if index == 1
      let row.replace = [s:Edge(widths, '├', '┼', '┤'), 'VimMarkdownViewBorder']
    else
      let padded = []
      for column in range(columns)
        call add(padded, ' ' . s:Pad(cells[index][column], widths[column],
              \ alignment[column]) . ' ')
      endfor
      let row.replace = ['│' . join(padded, '│') . '│', index == 0
            \ ? 'VimMarkdownViewTableHead' : 'VimMarkdownViewTableCell']
    endif
    " 无虚拟文本的 Vim 保留边框、表头颜色和现有列宽。
    call add(row.marks, [1, max([1, strlen(a:lines[a:first + index - 1])]), index == 0
          \ ? 'VimMarkdownViewTableHead' : 'VimMarkdownViewTableCell'])
    let offset = 0
    let spans = s:InlineCode(a:lines[a:first + index - 1])
    while 1
      let pipe = match(a:lines[a:first + index - 1], '\%(^\|[^\\]\)\zs|', offset)
      if pipe < 0
        break
      endif
      if !s:Inside(spans, pipe)
        let border = index == 1 ? (pipe == 0 ? '├'
              \ : pipe == strlen(a:lines[a:first + index - 1]) - 1 ? '┤' : '┼') : '│'
        call add(row.fallback, [pipe + 1, 1, border])
      endif
      let offset = pipe + 1
    endwhile
    if index == 1
      for column in range(1, strlen(a:lines[a:first + index - 1]))
        if strpart(a:lines[a:first + index - 1], column - 1, 1) =~# '[-:]'
          call add(row.fallback, [column, 1, '─'])
        endif
      endfor
    endif
  endfor
  call add(s:Row(a:plan, a:first).borders,
        \ ['above', s:Edge(widths, '╭', '┬', '╮'), 'VimMarkdownViewBorder'])
  call add(s:Row(a:plan, a:last).borders,
        \ ['below', s:Edge(widths, '╰', '┴', '╯'), 'VimMarkdownViewBorder'])
  return 1
endfunction

function! s:InlineCode(text) abort
  let spans = []
  let offset = 0
  while offset < strlen(a:text)
    let opening = matchstrpos(a:text, '\%(^\|[^\\]\)\zs`\+', offset)
    if opening[1] < 0
      break
    endif
    let search = opening[2]
    let closing = ['', -1, -1]
    while search < strlen(a:text)
      let closing = matchstrpos(a:text, '`\+', search)
      if closing[1] < 0 || strlen(closing[0]) == strlen(opening[0])
        break
      endif
      let search = closing[2]
    endwhile
    if closing[1] < 0
      break
    endif
    call add(spans, [opening[1], closing[2]])
    let offset = spans[-1][1]
  endwhile
  return spans
endfunction

function! s:Inside(spans, position) abort
  for span in a:spans
    if span[0] <= a:position && a:position < span[1]
      return 1
    endif
  endfor
  return 0
endfunction

" 宽度变化只重排卡片；表格、任务和链接沿用内容解析及窗口 match。
function! s:Layout(plan, width) abort
  let changed = {}
  for [line, layout] in items(a:plan.layouts)
    let row = a:plan.rows[line]
    let previous = [row.replace, row.fill]
    let kind = layout[0]
    if kind ==# 'heading'
      let row.replace = [s:Pad(layout[1], min([a:width - 8, layout[2]]), 'left'), layout[3]]
    elseif kind ==# 'callout'
      let row.replace = ['╭─ ' . layout[1] . ' '
            \ . repeat('─', max([2, min([48, a:width]) - layout[2] - 5])) . '╮', layout[3]]
    elseif kind ==# 'rule'
      let row.replace = [repeat('─', min([a:width, 64])), 'VimMarkdownViewBorder']
    elseif kind ==# 'code_head'
      let width = min([a:width, layout[2]])
      let row.replace = ['╭─ ' . layout[1] . ' '
            \ . repeat('─', max([1, width - strdisplaywidth(layout[1]) - 5])) . '╮',
            \ 'VimMarkdownViewCodeLabel']
    elseif kind ==# 'code_foot'
      let row.replace = ['╰' . repeat('─', min([a:width, layout[1]]) - 2) . '╯',
            \ 'VimMarkdownViewCodeLabel']
    elseif kind ==# 'code_body'
      let row.fill = max([0, min([a:width, layout[1]]) - layout[2]])
    endif
    if previous !=# [row.replace, row.fill]
      let changed[line] = 1
    endif
  endfor
  let a:plan.width = a:width
  return changed
endfunction

function! s:Build(buf, width) abort
  let lines = getbufline(a:buf, 1, '$')
  let plan = {'rows': {}, 'layouts': {}, 'tick': getbufvar(a:buf, 'changedtick')}
  let structure = VimMarkdownStructure(a:buf)
  let protected = {}
  for region in structure.code
    let first = region[0]
    let last = region[1]
    for line in range(first, last)
      let protected[line] = 1
    endfor
    let language = first == 1 && lines[0] ==# '---' ? '文档属性'
          \ : matchstr(lines[first - 1], '^\s*\%(`\{3,}\|\~\{3,}\)\s*\zs\S\+')
    let language = empty(language) ? 'code' : language
    let code_width = max(map(copy(lines[first - 1:last - 1]), 'strdisplaywidth(v:val)')) + 2
    let width = max([24, code_width, strdisplaywidth(language) + 10])
    call s:Row(plan, first)
    let plan.layouts[first] = ['code_head', language, width]
    let opener = matchstr(lines[first - 1], '^\s*\zs\%(`\{3,}\|\~\{3,}\)')
    let closer = matchstr(lines[last - 1], '^\s*\zs\%(`\{3,}\|\~\{3,}\)\ze\s*$')
    let closed = first == 1 && lines[0] ==# '---'
          \ ? lines[last - 1] =~# '^\%(---\|\.\.\.\)\s*$'
          \ : !empty(opener) && !empty(closer) && closer[0] ==# opener[0]
          \ && strlen(closer) >= strlen(opener)
    if closed && last > first
      call s:Row(plan, last)
      let plan.layouts[last] = ['code_foot', width]
      let body_last = last - 1
    else
      let body_last = last
    endif
    for line in range(first + 1, body_last)
      call s:Row(plan, line)
      let plan.layouts[line] = ['code_body', width, strdisplaywidth(lines[line - 1])]
    endfor
  endfor
  let comment = 0
  let callout = ''
  let index = 0
  while index < len(lines)
    let lnum = index + 1
    let text = lines[index]
    if has_key(protected, lnum)
          \ || (text =~# '^\%( \{4}\|\t\)' && VimMarkdownInCode(lnum))
      let index += 1
      let callout = ''
      continue
    endif
    let spans = s:InlineCode(text)
    let offset = 0
    let commented = 0
    while offset < strlen(text) || comment
      let start = comment ? 0 : match(text, '<!--', offset)
      if start < 0
        break
      endif
      if !comment && s:Inside(spans, start)
        let offset = start + 4
        continue
      endif
      let ending = match(text, '-->', comment ? 0 : start + 4)
      let stop = ending < 0 ? strlen(text) : ending + 3
      if stop > start
        call add(s:Row(plan, lnum).masks, [start + 1, stop - start, ''])
      endif
      let commented = 1
      if !comment && strpart(text, 0, start) =~# '^\s*$'
            \ && (ending < 0 || strpart(text, stop) =~# '^\s*$')
        let srow = s:Row(plan, lnum)
        let srow.insert = [[start + 1, '  · 注释', 'VimMarkdownViewComment']]
      endif
      let comment = ending < 0
      if comment
        break
      endif
      let offset = stop
    endwhile
    if commented
      let index += 1
      continue
    endif
    if index + 1 < len(lines) && text =~# '|' && !has_key(protected, lnum + 1)
      let separator = VimMarkdownCells(lines[index + 1])
      if len(separator) >= 2 && empty(filter(copy(separator), 'v:val !~# "^:\\=-\\+:\\=$"'))
        let last = index + 2
        while last < len(lines) && lines[last] =~# '|' && !has_key(protected, last + 1)
          let last += 1
        endwhile
        if s:Table(plan, lines, lnum, last)
          let index = last
          continue
        endif
      endif
    endif
    let row = s:Row(plan, lnum)
    let task = matchstrpos(text,
          \ '^\s*\%([>]\s*\)*\%([-+*]\|\d\+[.)]\)\s\+\[[ xX!\-]\]\s*')
    if task[1] >= 0
      let state = matchstr(task[0], '\[\zs.\ze\]')
      let states = {' ': ['□', 'Todo'], 'x': ['✓', 'Done'], 'X': ['✓', 'Done'],
            \ '-': ['◐', 'Doing'], '!': ['!', 'Blocked']}
      let badge = states[state]
      let prefix = matchstr(task[0], '^\s*\%([>]\s*\)*')
      let marker = matchstr(strpart(task[0], strlen(prefix)), '^\%([-+*]\|\d\+[.)]\)')
      let box = match(task[0], '\[[ xX!\-]\]')
      call add(row.insert, [strlen(prefix) + 1, ' ' . badge[0] . ' ',
            \ 'VimMarkdownView' . badge[1]])
      call add(row.masks, [strlen(prefix) + 1, task[2] - strlen(prefix), '', 'virtual'])
      call add(row.fallback, [strlen(prefix) + 1, strlen(marker), ' '])
      call add(row.fallback, [box + 1, 3, badge[0]])
      if state =~# '[xX]' && task[2] < strlen(text)
        call add(row.marks, [task[2] + 1, strlen(text) - task[2], 'VimMarkdownViewChecked'])
      endif
    endif
    let alert = matchlist(text, '^\s*>\s*\[!\(NOTE\|TIP\|IMPORTANT\|WARNING\|CAUTION\)\]\s*\(.*\)')
    if !empty(alert)
      let callout = toupper(alert[1][0]) . tolower(alert[1][1:])
      let label = alert[1] . (empty(alert[2]) ? '' : ' · ' . alert[2])
      let plan.layouts[lnum] = ['callout', label, strdisplaywidth(label),
            \ 'VimMarkdownView' . callout]
    elseif text =~# '^\s*>'
      call add(row.marks, [1, max([1, strlen(text)]), empty(callout)
            \ ? 'VimMarkdownViewQuote' : 'VimMarkdownView' . callout . 'Body'])
      let quote = matchstrpos(text, '^\s*\zs>')
      call add(row.masks, [quote[1] + 1, 1, '│'])
    else
      let callout = ''
    endif
    let heading = matchlist(text, '^ \{0,3}\(#\{1,6}\)\s\+\(.*\)')
    if !empty(heading)
      let title = substitute(heading[2], '\s\+#*\s*$', '', '')
      let level = strlen(heading[1])
      let title = s:Plain(title)
      let plan.layouts[lnum] = ['heading', '▎ H' . level . '  ' . title,
            \ max([28, strdisplaywidth(title) + 12]), 'markdownH' . level]
    endif
    if text =~# '^ \{0,3}\%(-\s*\)\{3,}$\|^ \{0,3}\%(\*\s*\)\{3,}$'
      let plan.layouts[lnum] = ['rule']
    endif
    let offset = 0
    while offset < strlen(text)
      let link = matchstrpos(text, '!\?\[[^]]*\](\([^)]*\))', offset)
      if link[1] < 0
        break
      endif
      if !s:Inside(spans, link[1])
        let image = link[0][0] ==# '!'
        let label = matchstr(link[0], '\[\zs[^]]*\ze\]')
        let icon = image ? '▣ ' : '↗ '
        call add(row.insert, [link[1] + 1, icon . label,
              \ image ? 'VimMarkdownViewImage' : 'VimMarkdownViewLink'])
        call add(row.masks, [link[1] + 1, link[2] - link[1], '', 'virtual'])
        let prefix = image ? 2 : 1
        let ending = link[1] + prefix + strlen(label)
        call add(row.fallback, [link[1] + 1, prefix, ''])
        call add(row.fallback, [ending + 1, link[2] - ending, ''])
      endif
      let offset = link[2]
    endwhile
    let index += 1
  endwhile
  call s:Layout(plan, a:width)
  call filter(plan.rows, 'has_key(plan.layouts, v:key) || !empty(v:val.replace)'
        \ . ' || !empty(v:val.insert)'
        \ . ' || !empty(v:val.marks) || !empty(v:val.masks) || !empty(v:val.borders)'
        \ . ' || v:val.fill > 0')
  return plan
endfunction

function! s:WindowClear(window) abort
  let matches = getwinvar(a:window, 'vimrc_lite_markdown_view_matches', {})
  for ids in values(matches)
    for id in ids
      silent! call matchdelete(id, a:window)
    endfor
  endfor
  call setwinvar(a:window, 'vimrc_lite_markdown_view_matches', {})
  call setwinvar(a:window, 'vimrc_lite_markdown_view_stamp', [])
endfunction

function! VimMarkdownViewLeave() abort
  call s:WindowClear(win_getid())
endfunction

function! VimMarkdownViewClear(buf) abort
  if s:virtual == 1 && !empty(s:types) && bufexists(a:buf)
        \ && getbufvar(a:buf, 'vimrc_lite_markdown_view_applied', -1) >= 0
    call prop_remove({'types': s:types, 'bufnr': a:buf, 'all': 1}, 1,
          \ max([1, getbufinfo(a:buf)[0].linecount]))
  endif
  for window in getwininfo()
    if window.bufnr == a:buf
      call s:WindowClear(window.winid)
    endif
  endfor
  call setbufvar(a:buf, 'vimrc_lite_markdown_view_hidden', [])
  call setbufvar(a:buf, 'vimrc_lite_markdown_view_applied', -1)
endfunction

function! s:Hidden(buf) abort
  let hidden = []
  for window in getwininfo()
    if window.bufnr == a:buf
      let line = getcurpos(window.winid)[1]
      if line > 0
        call add(hidden, line)
      endif
    endif
  endfor
  if mode(1) =~# '^[vV\x16]'
    let first = min([line('v'), line('.')])
    let last = max([line('v'), line('.')])
    let hidden += range(first, last)
  endif
  return uniq(sort(hidden, 'n'))
endfunction

function! s:ApplyRow(buf, line, row, hidden) abort
  if !s:virtual || index(a:hidden, a:line) >= 0
    return
  endif
  let fields = {'bufnr': a:buf}
  if !empty(a:row.replace)
    call prop_add(a:line, 1, extend(copy(fields), {'type': s:Type(a:row.replace[1]),
          \ 'text': a:row.replace[0]}))
  else
    for item in a:row.insert
      call prop_add(a:line, item[0], extend(copy(fields), {'type': s:Type(item[2]),
            \ 'text': item[1]}))
    endfor
  endif
  for border in a:row.borders
    call prop_add(a:line, 0, extend(copy(fields), {'type': s:Type(border[2]),
          \ 'text': border[1], 'text_align': border[0]}))
  endfor
  if a:row.fill > 0
    call prop_add(a:line, 0, extend(copy(fields), {'type': s:Type('VimMarkdownViewCodeBody'),
          \ 'text': repeat(' ', a:row.fill), 'text_align': 'after'}))
  endif
endfunction

function! s:MatchRow(window, buf, line, row) abort
  let ids = []
  for mark in a:row.marks
    let priority = mark[2] ==# 'VimMarkdownViewChecked' ? 18 : 12
    call add(ids, matchaddpos(mark[2], [[a:line, mark[0], mark[1]]], priority, -1,
          \ {'window': a:window}))
  endfor
  let masks = copy(a:row.masks)
  if s:virtual
    if !empty(a:row.replace)
      let masks = [[1, max([1, strlen(getbufline(a:buf, a:line)[0])]), ' ']]
    elseif !empty(a:row.insert)
      let masks = map(masks, 'len(v:val) >= 4 && v:val[3] ==# "virtual"'
            \ . ' ? [v:val[0], v:val[1], " "] : v:val')
    endif
  else
    call filter(masks, 'len(v:val) < 4 || v:val[3] !=# "virtual"')
    let masks += a:row.fallback
    if !empty(a:row.replace)
      call add(ids, matchaddpos(a:row.replace[1], [[a:line, 1,
            \ max([1, strlen(getbufline(a:buf, a:line)[0])])]], 12, -1,
            \ {'window': a:window}))
    endif
  endif
  for mask in masks
    call add(ids, matchaddpos('Conceal', [[a:line, mask[0], mask[1]]], 30, -1,
          \ {'window': a:window, 'conceal': mask[2]}))
  endfor
  return ids
endfunction

function! s:Matches(buf, plan, hidden) abort
  let stamp = [a:buf, a:plan.tick]
  let previous = getbufvar(a:buf, 'vimrc_lite_markdown_view_hidden', [])
  for window in getwininfo()
    if window.bufnr != a:buf
      continue
    endif
    let full = getwinvar(window.winid, 'vimrc_lite_markdown_view_stamp', []) !=# stamp
    if full
      call s:WindowClear(window.winid)
      let changed = keys(a:plan.rows)
    else
      let changed = map(uniq(sort(previous + a:hidden, 'n')), 'string(v:val)')
    endif
    let matches = getwinvar(window.winid, 'vimrc_lite_markdown_view_matches', {})
    for line in changed
      let lnum = str2nr(line)
      if !full && (index(previous, lnum) >= 0) == (index(a:hidden, lnum) >= 0)
        continue
      endif
      if has_key(matches, line)
        for id in remove(matches, line)
          silent! call matchdelete(id, window.winid)
        endfor
      endif
      if has_key(a:plan.rows, line) && index(a:hidden, lnum) < 0
        let matches[line] = s:MatchRow(window.winid, a:buf, lnum, a:plan.rows[line])
      endif
    endfor
    call setwinvar(window.winid, 'vimrc_lite_markdown_view_matches', matches)
    call setwinvar(window.winid, 'vimrc_lite_markdown_view_stamp', stamp)
  endfor
endfunction

function! VimMarkdownViewRefresh() abort
  if &filetype !=# 'markdown' || &buftype !=# '' || get(b:, 'vimrc_lite_large_file', 0)
    return
  endif
  let buf = bufnr('%')
  if get(b:, 'vimrc_lite_markdown_raw', !get(g:, 'vimrc_lite_markdown_render', 1))
        \ || mode(1) =~# '^i'
    call VimMarkdownViewClear(buf)
    return
  endif
  call s:Virtual()
  let windows = filter(getwininfo(), 'v:val.bufnr == buf')
  let width = min(map(windows, 'max([24, v:val.width - get(v:val, "textoff", 4) - 1])'))
  let plan = get(b:, 'vimrc_lite_markdown_view_plan', {})
  let hidden = s:Hidden(buf)
  let resized = {}
  if get(plan, 'tick', -1) != b:changedtick || !has_key(plan, 'layouts')
    call VimMarkdownViewClear(buf)
    let plan = s:Build(buf, width)
    let b:vimrc_lite_markdown_view_plan = plan
  elseif plan.width != width
    let resized = s:Layout(plan, width)
  endif
  if get(b:, 'vimrc_lite_markdown_view_applied', -1) != b:changedtick
    for [line, row] in items(plan.rows)
      call s:ApplyRow(buf, str2nr(line), row, hidden)
    endfor
    let b:vimrc_lite_markdown_view_applied = b:changedtick
  elseif s:virtual && !empty(s:types)
    let previous = get(b:, 'vimrc_lite_markdown_view_hidden', [])
    for line in uniq(sort(previous + hidden + map(keys(resized), 'str2nr(v:val)'), 'n'))
      if !has_key(resized, line) && (index(previous, line) >= 0) == (index(hidden, line) >= 0)
        continue
      endif
      call prop_remove({'types': s:types, 'bufnr': buf, 'all': 1}, line, line)
      if has_key(plan.rows, string(line))
        call s:ApplyRow(buf, line, plan.rows[string(line)], hidden)
      endif
    endfor
  endif
  if get(b:, 'vimrc_lite_markdown_view_hidden', []) !=# hidden
        \ || get(w:, 'vimrc_lite_markdown_view_stamp', []) !=# [buf, plan.tick]
    call s:Matches(buf, plan, hidden)
  endif
  let b:vimrc_lite_markdown_view_hidden = hidden
endfunction

function! VimMarkdownViewStop() abort
  if s:resize_timer != -1
    call timer_stop(s:resize_timer)
    let s:resize_timer = -1
  endif
endfunction

function! s:Resize(timer) abort
  let s:resize_timer = -1
  let seen = {}
  for window in getwininfo()
    if has_key(seen, window.bufnr) || getbufvar(window.bufnr, '&filetype') !=# 'markdown'
      continue
    endif
    let seen[window.bufnr] = 1
    if exists('*win_execute')
      call win_execute(window.winid, 'call VimMarkdownViewRefresh()')
    else
      let origin = win_getid()
      try
        noautocmd call win_gotoid(window.winid)
        call VimMarkdownViewRefresh()
      finally
        noautocmd call win_gotoid(origin)
      endtry
    endif
  endfor
endfunction

" netrw 分屏期间会先出现短暂的 Markdown 副本，等本次窗口操作结束再读取最终宽度。
function! VimMarkdownViewSchedule() abort
  call VimMarkdownViewStop()
  if empty(filter(getwininfo(), 'getbufvar(v:val.bufnr, "&filetype") ==# "markdown"'
        \ . ' && getbufvar(v:val.bufnr, "&buftype") ==# ""'
        \ . ' && !getbufvar(v:val.bufnr, "vimrc_lite_large_file", 0)'
        \ . ' && !getbufvar(v:val.bufnr, "vimrc_lite_markdown_raw", 0)'))
    return
  endif
  let s:resize_timer = timer_start(0, function('<SID>Resize'))
endfunction

function! VimMarkdownViewInvalidate() abort
  if &filetype ==# 'markdown' && !get(b:, 'vimrc_lite_markdown_raw', 0)
        \ && get(get(b:, 'vimrc_lite_markdown_view_plan', {}),
        \ 'tick', -1) != b:changedtick
    call VimMarkdownViewClear(bufnr('%'))
    return 1
  endif
  return 0
endfunction

augroup vimrc_lite_markdown_view
  autocmd!
  autocmd ColorScheme * call s:Colors()
  if exists('##WinResized')
    autocmd WinResized * call VimMarkdownViewSchedule()
  endif
augroup END
call s:Colors()
