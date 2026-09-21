" Git hunk 导航与 LazyGit 入口；终端的启动与退出交给 terminal.vim。
function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim Git: ' . a:message
  echohl None
endfunction

function! s:Command(args) abort
  return join(map(copy(a:args), 'shellescape(v:val)'), ' ')
endfunction

function! s:PathWithoutTrailingSlash(path) abort
  let path = fnamemodify(a:path, ':p')
  return path ==# '/' ? path : substitute(path, '/$', '', '')
endfunction

function! s:GitRoot(file) abort
  let output = systemlist(s:Command(['git', '-C', fnamemodify(a:file, ':h'),
        \ 'rev-parse', '--show-toplevel']))
  if v:shell_error != 0 || empty(output)
    return ''
  endif
  return s:PathWithoutTrailingSlash(output[0])
endfunction

function! s:RelativePath(root, file) abort
  let root = s:PathWithoutTrailingSlash(a:root)
  let file = s:PathWithoutTrailingSlash(a:file)
  if root ==# '/'
    return strpart(file, 1)
  endif
  if stridx(file, root . '/') != 0
    return ''
  endif
  return strpart(file, strlen(root) + 1)
endfunction

function! s:IsTracked(root, relative) abort
  call systemlist(s:Command(['git', '-C', a:root, 'ls-files', '--error-unmatch',
        \ '--', a:relative]))
  return v:shell_error == 0
endfunction

function! s:IsIgnored(root, relative) abort
  call systemlist(s:Command(['git', '-C', a:root, 'check-ignore', '-q', '--no-index',
        \ '--', a:relative]))
  return v:shell_error == 0
endfunction

function! s:HasBufferText() abort
  return line('$') > 1 || getline(1) !=# ''
endfunction

function! s:UntrackedHunks() abort
  if !s:HasBufferText()
    return []
  endif
  return [{'start': 1, 'end': line('$')}]
endfunction

function! s:IndexHunks(root, relative) abort
  let index = system(s:Command(['git', '-C', a:root, 'show', ':' . a:relative]))
  let index_status = v:shell_error
  if index_status != 0
    call s:Warn('could not read the Git index for ' . a:relative)
    return []
  endif

  let index_file = tempname()
  try
    call writefile(split(index, "\n", 1), index_file, 'b')
    let output = systemlist(s:Command(['git', 'diff', '--no-index', '--no-ext-diff',
          \ '--unified=0', '--no-color', '--no-renames', '--', index_file, '-']), bufnr('%'))
    let diff_status = v:shell_error
  catch
    call delete(index_file)
    throw v:exception
  endtry
  call delete(index_file)
  if diff_status > 1
    call s:Warn('could not compare the current buffer with the Git index')
    return []
  endif

  let hunks = []
  for line in output
    let parts = matchlist(line,
          \ '^@@ -\d\+\%([,]\d\+\)\? +\(\d\+\)\%([,]\(\d\+\)\)\? @@')
    if empty(parts)
      continue
    endif
    let start = str2nr(parts[1])
    let new_count = empty(parts[2]) ? 1 : str2nr(parts[2])
    call add(hunks, {'start': start, 'end': start + max([new_count - 1, 0])})
  endfor
  return hunks
endfunction

function! s:Hunks() abort
  if &buftype !=# '' || empty(bufname('%'))
    call s:Warn('current buffer has no file path')
    return []
  endif
  if !executable('git')
    call s:Warn('git requires git in PATH')
    return []
  endif

  let file = s:PathWithoutTrailingSlash(expand('%:p'))
  let root = s:GitRoot(file)
  if empty(root)
    call s:Warn('current file is not in a Git repository')
    return []
  endif
  let relative = s:RelativePath(root, file)
  if empty(relative)
    call s:Warn('could not determine the Git path for the current file')
    return []
  endif
  if s:IsTracked(root, relative)
    return s:IndexHunks(root, relative)
  endif
  if s:IsIgnored(root, relative)
    return []
  endif
  return s:UntrackedHunks()
endfunction

function! s:NearestHunk(hunks, current, direction, wrap, line_count) abort
  if a:direction ==# 'next'
    let current = a:current
    let last = a:hunks[-1]
    if a:current == a:line_count && last.start == a:line_count + 1
      let current += 1
    endif
    if a:hunks[0].start > current
      return 0
    endif
    for index in reverse(range(len(a:hunks) - 1))
      if a:hunks[index].start <= current
        if index + 1 < len(a:hunks) && a:hunks[index + 1].start > current
          return index + 1
        endif
        return a:wrap ? 0 : -1
      endif
    endfor
    return 0
  endif

  if a:hunks[-1].end < a:current
    return len(a:hunks) - 1
  endif
  for index in range(len(a:hunks))
    if a:current <= max([a:hunks[index].end, 1])
      if index > 0 && max([a:hunks[index - 1].end, 1]) < a:current
        return index - 1
      endif
      return a:wrap ? len(a:hunks) - 1 : -1
    endif
  endfor
  return len(a:hunks) - 1
endfunction

function! s:FirstTextColumn(lnum) abort
  let column = match(getline(a:lnum), '\S')
  return column < 0 ? 1 : column + 1
endfunction

function! s:NavigateHunk(direction, count) abort
  if &diff
    execute 'normal! ' . a:count . (a:direction ==# 'next' ? ']c' : '[c')
    return
  endif

  let hunks = s:Hunks()
  if empty(hunks)
    call s:Warn('no Git hunks')
    return
  endif

  let target = line('.')
  let index = -1
  let line_count = max([line('$'), 1])
  for _ in range(a:count)
    let index = s:NearestHunk(hunks, target, a:direction, &wrapscan, line_count)
    if index < 0
      call s:Warn('no more Git hunks')
      return
    endif
    let target = a:direction ==# 'next' ? hunks[index].start : hunks[index].end
    let target = min([max([target, 1]), line_count])
  endfor

  normal! m'
  call cursor(target, s:FirstTextColumn(target))
  if &foldopen =~# 'search'
    silent! foldopen!
  endif
  echo 'Git hunk ' . (index + 1) . '/' . len(hunks)
endfunction

function! s:LazyGit() abort
  if !executable('lazygit')
    call s:Warn('LazyGit requires lazygit in PATH')
    return
  endif
  VimTerminal lazygit
endfunction

command! VimGit call <SID>LazyGit()

nnoremap <silent> ]c :<C-U>call <SID>NavigateHunk('next', v:count1)<CR>
nnoremap <silent> [c :<C-U>call <SID>NavigateHunk('prev', v:count1)<CR>
