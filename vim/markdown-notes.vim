" Markdown 笔记：章节路径、文内目录、按标题折叠及可配置自动保存。
let s:saves = {}

function! s:Markdown() abort
  return &filetype ==# 'markdown' && &buftype ==# '' && !get(b:, 'vimrc_lite_large_file', 0)
endfunction

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Markdown: ' . a:message
  echohl None
endfunction

function! s:Index() abort
  let structure = get(b:, 'vimrc_lite_markdown_headers', {})
  let tick = get(structure, 'tick', -1)
  if get(get(b:, 'vimrc_lite_markdown_notes', {}), 'tick', -2) == tick
    return
  endif
  let paths = []
  let parents = []
  for heading in get(structure, 'rows', [])
    while !empty(parents) && parents[-1].level >= heading.level
      call remove(parents, -1)
    endwhile
    call add(parents, heading)
    let labels = map(copy(parents), 'substitute(v:val.text, "[\\r\\n]", " ", "g")')
    call add(paths, {'line': heading.line, 'path': join(labels, ' › ')})
  endfor
  let b:vimrc_lite_markdown_notes = {'tick': tick, 'paths': paths}
endfunction

function! VimMarkdownBreadcrumb() abort
  if !s:Markdown() || !get(g:, 'vimrc_lite_markdown_breadcrumb', 1) || winwidth(0) < 60
    return ''
  endif
  " 状态栏只消费已有的结构缓存，不在输入和窗口重绘中重新扫描全文。
  call s:Index()
  let paths = get(get(b:, 'vimrc_lite_markdown_notes', {}), 'paths', [])
  let left = 0
  let right = len(paths) - 1
  let found = -1
  while left <= right
    let middle = (left + right) / 2
    if paths[middle].line <= line('.')
      let found = middle
      let left = middle + 1
    else
      let right = middle - 1
    endif
  endwhile
  if found < 0
    return ''
  endif
  let label = paths[found].path
  let width = max([12, min([get(g:, 'vimrc_lite_markdown_breadcrumb_width', 48),
        \ winwidth(0) / 3])])
  if strdisplaywidth(label) > width
    let label = '…' . strcharpart(label, max([0, strchars(label) - width + 1]))
    while strdisplaywidth(label) > width
      let label = '…' . strcharpart(label, 2)
    endwhile
  endif
  return ' [' . label . ']'
endfunction

function! s:Blocks() abort
  let blocks = []
  let protected = {}
  for region in VimMarkdownStructure(bufnr('%')).code
    for lnum in range(region[0], region[1])
      let protected[lnum] = 1
    endfor
  endfor
  let start = 0
  let depth = 3
  for lnum in range(1, line('$'))
    if has_key(protected, lnum)
      continue
    endif
    let text = getline(lnum)
    if text =~# '^<!-- vim-lite-toc start depth=[1-6] -->$'
      if start
        throw 'Markdown: nested TOC markers; repair the markers before updating'
      endif
      let start = lnum
      let depth = str2nr(matchstr(text, 'depth=\zs[1-6]'))
    elseif text ==# '<!-- vim-lite-toc end -->'
      if !start
        throw 'Markdown: TOC end marker has no start marker'
      endif
      call add(blocks, {'first': start, 'last': lnum, 'depth': depth})
      let start = 0
    endif
  endfor
  if start
    throw 'Markdown: TOC start marker has no end marker'
  endif
  return blocks
endfunction

function! s:TocLines(depth, blocks) abort
  let headings = copy(VimMarkdownStructure(bufnr('%')).rows)
  for block in a:blocks
    call filter(headings, 'v:val.line < block.first || v:val.line > block.last')
  endfor
  call filter(headings, 'v:val.level <= a:depth')
  let minimum = empty(headings) ? 1 : min(map(copy(headings), 'v:val.level'))
  let lines = ['<!-- vim-lite-toc start depth=' . a:depth . ' -->']
  for heading in headings
    let title = substitute(heading.text, '!\?\[\([^]]*\)\]([^)]*)', '\1', 'g')
    let title = escape(title, '\[]')
    call add(lines, repeat('  ', heading.level - minimum) . '- [' . title . '](#'
          \ . heading.slug . ')')
  endfor
  return lines + ['<!-- vim-lite-toc end -->']
endfunction

function! s:Replace(first, last, lines) abort
  if getline(a:first, a:last) ==# a:lines
    return 0
  endif
  let row_count = a:last - a:first + 1
  let shared = min([row_count, len(a:lines)])
  call setline(a:first, a:lines[0:shared - 1])
  if row_count > shared
    undojoin
    call deletebufline(bufnr('%'), a:first + shared, a:last)
  elseif len(a:lines) > shared
    undojoin
    call append(a:last, a:lines[shared:])
  endif
  return 1
endfunction

function! VimMarkdownToc(action, argument) abort
  if !s:Markdown() || !&modifiable || &readonly
    return
  endif
  let view = winsaveview()
  try
    let blocks = s:Blocks()
    if a:action ==# 'remove'
      let changed = 0
      for block in reverse(blocks)
        if changed
          undojoin
        endif
        call deletebufline(bufnr('%'), block.first, block.last)
        let changed = 1
      endfor
      return
    endif
    let depth = empty(a:argument) ? get(g:, 'vimrc_lite_markdown_toc_depth', 3)
          \ : str2nr(a:argument)
    if depth < 1 || depth > 6 || (!empty(a:argument) && a:argument !~# '^[1-6]$')
      call s:Warn('TOC depth must be 1 to 6')
      return
    endif
    if empty(blocks)
      if a:action ==# 'update'
        return
      endif
      let lines = s:TocLines(depth, [])
      if getline('.') ==# ''
        call setline(line('.'), lines[0])
        undojoin
        call append(line('.'), lines[1:])
      else
        call append(line('.'), [''] + lines + [''])
      endif
    else
      let replacements = []
      for block in blocks
        let chosen = empty(a:argument) ? block.depth : depth
        call add(replacements, [block, s:TocLines(chosen, blocks)])
      endfor
      let changed = 0
      for [block, lines] in reverse(replacements)
        if getline(block.first, block.last) !=# lines
          if changed
            undojoin
          endif
          let changed += s:Replace(block.first, block.last, lines)
        endif
      endfor
    endif
  catch /^Markdown:/
    call s:Warn(substitute(v:exception, '^Markdown: ', '', ''))
  finally
    call winrestview(view)
  endtry
endfunction

function! VimMarkdownFoldExpr(lnum) abort
  if !s:Markdown()
    return 0
  endif
  let cached = get(b:, 'vimrc_lite_markdown_folds', {})
  if get(cached, 'tick', -1) != b:changedtick
    let headers = VimMarkdownStructure(bufnr('%')).rows
    let levels = repeat([0], line('$'))
    let next = 0
    let level = 0
    for lnum in range(1, line('$'))
      if next < len(headers) && headers[next].line == lnum
        let level = headers[next].level
        let levels[lnum - 1] = '>' . level
        let next += 1
      else
        let levels[lnum - 1] = level
      endif
    endfor
    let cached = {'tick': b:changedtick, 'levels': levels}
    let b:vimrc_lite_markdown_folds = cached
  endif
  return get(cached.levels, a:lnum - 1, 0)
endfunction

function! VimMarkdownFoldText() abort
  return '▸ ' . substitute(getline(v:foldstart), '^\s*#\+\s*', '', '')
        \ . '  [' . (v:foldend - v:foldstart + 1) . ' 行]'
endfunction

function! VimMarkdownFold(arguments) abort
  if !s:Markdown()
    return
  endif
  let args = split(a:arguments)
  let action = get(args, 0, 'current')
  if index(['current', 'all', 'open', 'off', 'level'], action) < 0
        \ || (action ==# 'level' && get(args, 1, '') !~# '^[0-6]$')
    call s:Warn('fold: current, all, open, off, or level 0..6')
    return
  endif
  if action ==# 'off'
    setlocal nofoldenable foldmethod=manual
    return
  endif
  if &l:foldmethod !=# 'expr' || &l:foldexpr !=# 'VimMarkdownFoldExpr(v:lnum)'
    setlocal foldlevel=6
  endif
  setlocal foldmethod=expr foldexpr=VimMarkdownFoldExpr(v:lnum)
  setlocal foldtext=VimMarkdownFoldText() foldenable
  if action ==# 'all'
    setlocal foldlevel=0
  elseif action ==# 'open'
    setlocal foldlevel=6
  elseif action ==# 'level'
    let &l:foldlevel = str2nr(args[1])
  else
    let heading = 0
    for row in VimMarkdownStructure(bufnr('%')).rows
      if row.line > line('.')
        break
      endif
      let heading = row.line
    endfor
    if heading
      call cursor(heading, 1)
      normal! za
    endif
  endif
endfunction

function! s:Digest(path) abort
  return filereadable(a:path) ? sha256(join(readfile(a:path, 'b'), "\n")) : ''
endfunction

function! s:Baseline() abort
  if s:Markdown() && !empty(bufname('%'))
    let b:vimrc_lite_markdown_disk = s:Digest(expand('%:p'))
    unlet! b:vimrc_lite_markdown_save_warning
  endif
endfunction

function! s:Enabled() abort
  return s:Markdown() && get(b:, 'vimrc_lite_markdown_autosave',
        \ get(g:, 'vimrc_lite_markdown_autosave', 1))
endfunction

function! s:EventEnabled(event) abort
  return index(split(get(g:, 'vimrc_lite_markdown_autosave_events',
        \ 'InsertLeave,BufLeave,FocusLost,Idle'), ','), a:event) >= 0
endfunction

function! s:Save() abort
  if !s:Enabled() || !&modified || !&modifiable || &readonly || empty(bufname('%'))
        \ || !isdirectory(expand('%:p:h')) || get(b:, 'vimrc_lite_markdown_saving', 0)
    return
  endif
  let path = expand('%:p')
  if !exists('b:vimrc_lite_markdown_disk') || s:Digest(path) !=# b:vimrc_lite_markdown_disk
    if !get(b:, 'vimrc_lite_markdown_save_warning', 0)
      if get(b:, 'vimrc_lite_markdown_disk', 'unverified') ==# 'unverified'
        call s:Warn('auto-save skipped: save this existing modified buffer manually once')
      else
        call s:Warn('auto-save skipped: file changed on disk; review and save manually')
      endif
      let b:vimrc_lite_markdown_save_warning = 1
    endif
    return
  endif
  let b:vimrc_lite_markdown_saving = 1
  try
    silent keepalt update
  catch
    call s:Warn('auto-save failed: ' . v:exception)
  finally
    let b:vimrc_lite_markdown_saving = 0
  endtry
endfunction

function! s:Idle(buf, timer) abort
  if get(s:saves, a:buf, -1) != a:timer
    return
  endif
  call remove(s:saves, a:buf)
  let windows = win_findbuf(a:buf)
  if !empty(windows) && exists('*win_execute')
    call win_execute(windows[0], 'call VimMarkdownAutoSaveNow()')
  endif
endfunction

function! VimMarkdownAutoSaveNow() abort
  call s:Save()
endfunction

function! s:Event(event) abort
  if !s:Enabled() || !s:EventEnabled(a:event)
    return
  endif
  let buf = bufnr('%')
  if has_key(s:saves, buf)
    call timer_stop(remove(s:saves, buf))
  endif
  if s:EventEnabled(a:event) && a:event !=# 'Idle'
    call s:Save()
  elseif a:event ==# 'Idle' && s:EventEnabled('Idle') && &modified
    let delay = max([100, get(g:, 'vimrc_lite_markdown_autosave_delay', 1500)])
    let s:saves[buf] = timer_start(delay, function('<SID>Idle', [buf]))
  endif
endfunction

function! VimMarkdownAutoSaveToggle() abort
  if !s:Markdown()
    return
  endif
  let b:vimrc_lite_markdown_autosave = !get(b:, 'vimrc_lite_markdown_autosave',
        \ get(g:, 'vimrc_lite_markdown_autosave', 1))
  echom 'Markdown: auto-save ' . (b:vimrc_lite_markdown_autosave ? 'on' : 'off')
endfunction

function! VimMarkdownNotesAttach() abort
  if !s:Markdown()
    return
  endif
  if !exists('b:vimrc_lite_markdown_disk')
    if &modified
      " 首次接管已有的脏 buffer 时没有旧磁盘基线，先由用户手动保存一次。
      let b:vimrc_lite_markdown_disk = 'unverified'
    else
      call s:Baseline()
    endif
  endif
  nnoremap <silent><buffer> <leader>mc :VimMarkdownToc<CR>
  nnoremap <silent><buffer> <leader>mu :VimMarkdownTocUpdate<CR>
  nnoremap <silent><buffer> <leader>mz :VimMarkdownFold current<CR>
  nnoremap <silent><buffer> <leader>mZ :VimMarkdownFold all<CR>
  nnoremap <silent><buffer> <leader>ma :VimMarkdownAutoSave<CR>
endfunction

function! VimMarkdownNotesStop(...) abort
  for buf in keys(copy(s:saves))
    if !a:0 || str2nr(buf) == a:1
      call timer_stop(remove(s:saves, buf))
    endif
  endfor
endfunction

function! s:BeforeWrite() abort
  if s:Markdown() && get(g:, 'vimrc_lite_markdown_toc_on_save', 1)
    call VimMarkdownToc('update', '')
  endif
endfunction

command! -nargs=? VimMarkdownToc call VimMarkdownToc('create', <q-args>)
command! -nargs=? VimMarkdownTocUpdate call VimMarkdownToc('update', <q-args>)
command! VimMarkdownTocRemove call VimMarkdownToc('remove', '')
command! -nargs=* VimMarkdownFold call VimMarkdownFold(<q-args>)
command! VimMarkdownAutoSave call VimMarkdownAutoSaveToggle()

augroup vimrc_lite_markdown_notes
  autocmd!
  autocmd BufWritePre * call s:BeforeWrite()
  autocmd BufWritePost * call s:Baseline()
  autocmd InsertLeave * call s:Event('InsertLeave')
  autocmd BufLeave * call s:Event('BufLeave')
  autocmd FocusLost * call s:Event('FocusLost')
  autocmd TextChanged,TextChangedI * call s:Event('Idle')
  autocmd BufWipeout * call VimMarkdownNotesStop(str2nr(expand('<abuf>')))
augroup END
