" 使用 Vim 自带 netrw 管理侧边文件树；关闭插件自动加载时也显式启用。
runtime plugin/netrwPlugin.vim

let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_winsize = 25
let g:netrw_keepdir = 1

nnoremap <silent> <leader>e :call <SID>ToggleTree()<CR>

" 沿用 nvimtree/neotree 的按键习惯，为 netrw 增加文件操作：
"   a 新建（名称以 / 结尾则建目录）、r 重命名、d 删除、R 刷新、H 显示隐藏文件
"   c 复制、x 剪切、p 粘贴、y 复制文件名、Y 复制相对路径
" 通过 netrw 官方的 g:Netrw_UserMaps 注册，操作后由 netrw 自行刷新列表。
let s:sid = expand('<SID>')
let s:clip = {'op': '', 'path': ''}

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim tree: ' . a:message
  echohl None
endfunction

" 当前 tab 已有 netrw 窗口时，保持 <leader>e 的关闭行为。
function! s:TreeOpen() abort
  for window in getwininfo()
    if getbufvar(window.bufnr, '&filetype') ==# 'netrw'
      return 1
    endif
  endfor
  return 0
endfunction

" 有名 buffer 使用文件所在目录；无名或无效路径退回 Vim 当前目录。
function! s:TreeDirectory() abort
  let path = expand('%:p')
  if path ==# ''
    return getcwd()
  endif
  if isdirectory(path)
    return path
  endif
  let directory = fnamemodify(path, ':h')
  return isdirectory(directory) ? directory : getcwd()
endfunction

function! s:ToggleTree() abort
  if s:TreeOpen()
    Lexplore
    return
  endif
  execute 'Lexplore ' . fnameescape(s:TreeDirectory())
endfunction

" 树形列表每层以 "| " 或 "│ " 缩进；统计深度，并去掉缩进、提示文本和尾部标记。
let s:indent = '^\%(\%(|\|│\) \)*'

function! s:Depth(line) abort
  return strchars(matchstr(a:line, s:indent)) / 2
endfunction

function! s:Name(line) abort
  let name = substitute(a:line, s:indent, '', '')
  let name = substitute(name, '\t -->.*$', '', '')
  return substitute(name, '[@*]$', '', '')
endfunction

function! s:Join(base, name) abort
  return (a:base =~# '/$' ? a:base : a:base . '/') . a:name
endfunction

" 光标所在条目；path 为空表示树根、../ 或不可操作项。
function! s:Entry() abort
  let curdir = get(b:, 'netrw_curdir', '')
  if curdir ==# ''
    return {'name': '', 'path': '', 'dir': 0}
  endif
  let liststyle = get(w:, 'netrw_liststyle', get(g:, 'netrw_liststyle', 0))
  if liststyle != 3
    let name = netrw#Call('NetrwGetWord')
    if name ==# '' || name ==# '../' || name ==# './'
      return {'name': '', 'path': '', 'dir': 0}
    endif
    let path = s:Join(curdir, name)
    return {'name': name, 'path': path, 'dir': isdirectory(path)}
  endif
  let raw = getline('.')
  let depth = s:Depth(raw)
  let name = s:Name(raw)
  if depth == 0 || name ==# '' || name ==# '../' || name ==# './'
    return {'name': '', 'path': '', 'dir': 0}
  endif
  " 树根由 w:netrw_treetop 决定；进入子目录后它与当前浏览目录不同。
  " 列表按深度优先排列，向上取各层最近的父目录即可拼出完整路径。
  let root = get(w:, 'netrw_treetop', '')
  if root ==# ''
    let root = curdir
  endif
  let parts = []
  let parent = depth - 1
  let lnum = line('.') - 1
  while lnum >= 1 && parent >= 1
    if s:Depth(getline(lnum)) == parent
      call insert(parts, substitute(s:Name(getline(lnum)), '/$', '', ''))
      let parent -= 1
    endif
    let lnum -= 1
  endwhile
  let parts += [substitute(name, '/$', '', '')]
  let path = s:Join(root, join(parts, '/'))
  return {'name': name, 'path': path, 'dir': name =~# '/$'}
endfunction

" 新建/粘贴的目标目录：选中目录时用该目录，否则用当前浏览目录。
function! s:BaseDir() abort
  let entry = s:Entry()
  if entry.dir && entry.path !=# ''
    return entry.path
  endif
  return get(b:, 'netrw_curdir', '')
endfunction

" input() 收到 Esc 时会等待 ttimeoutlen（默认跟随 timeoutlen）来判断终端按键序列，
" 取消输入因此显得很慢；提示期间临时缩短，退出后立即返回并恢复原值。
function! s:Input(prompt, ...) abort
  let keep_ttimeout = &ttimeout
  let keep_ttimeoutlen = &ttimeoutlen
  try
    set ttimeout
    let &ttimeoutlen = 30
    return call('input', [a:prompt, a:0 ? a:1 : ''])
  finally
    let &ttimeout = keep_ttimeout
    let &ttimeoutlen = keep_ttimeoutlen
  endtry
endfunction

" 在 netrw 之外打开文件，优先使用 Lexplore 指定的编辑窗口。
function! s:Open(path) abort
  if !filereadable(a:path) && !isdirectory(a:path)
    return
  endif
  let chgwin = get(g:, 'netrw_chgwin', -1)
  if &l:filetype ==# 'netrw' && chgwin >= 1 && chgwin <= winnr('$') && chgwin != winnr()
    execute 'keepalt ' . chgwin . 'wincmd w'
  endif
  execute 'edit ' . fnameescape(a:path)
endfunction

function! s:Create(islocal) abort
  if !a:islocal
    return ''
  endif
  let name = s:Input('New file or directory: ')
  if name ==# ''
    return ''
  endif
  " 名称以 / 结尾则建目录；目标已存在时拒绝，缺失的父目录一并创建。
  let directory = name =~# '/$'
  let target = s:Join(s:BaseDir(), name)
  if directory
    let target = substitute(target, '/\+$', '', '')
  endif
  if isdirectory(target) || filereadable(target)
    call s:Warn('already exists: ' . target)
    return ''
  endif
  if directory
    call mkdir(target, 'p')
    return 'refresh'
  endif
  call mkdir(fnamemodify(target, ':h'), 'p')
  call writefile([], target)
  return ['refresh', 'call ' . s:sid . 'Open(' . string(target) . ')']
endfunction

function! s:Rename(islocal) abort
  if !a:islocal
    return ''
  endif
  let entry = s:Entry()
  if entry.path ==# ''
    return ''
  endif
  let oldname = substitute(entry.name, '/$', '', '')
  let newname = substitute(s:Input('Rename to: ', oldname), '/\+$', '', '')
  if newname ==# '' || newname ==# oldname
    return ''
  endif
  let target = s:Join(fnamemodify(entry.path, ':h'), newname)
  if filereadable(target) || isdirectory(target)
    call s:Warn('already exists: ' . target)
    return ''
  endif
  try
    call rename(entry.path, target)
  catch
    call s:Warn(v:exception)
  endtry
  return 'refresh'
endfunction

function! s:Delete(islocal) abort
  if !a:islocal
    return ''
  endif
  let entry = s:Entry()
  if entry.path ==# ''
    return ''
  endif
  if s:Input('Delete "' . fnamemodify(entry.path, ':t') . '" ? (y/N) ') !~? '^y'
    return ''
  endif
  try
    if entry.dir
      call delete(entry.path, 'rf')
    else
      call delete(entry.path)
    endif
  catch
    call s:Warn(v:exception)
  endtry
  return 'refresh'
endfunction

function! s:Copy(islocal) abort
  if !a:islocal
    return ''
  endif
  let entry = s:Entry()
  if entry.path ==# ''
    return ''
  endif
  let s:clip = {'op': 'copy', 'path': entry.path}
  echom 'Vim tree: copied ' . fnamemodify(entry.path, ':t')
  return ''
endfunction

function! s:Cut(islocal) abort
  if !a:islocal
    return ''
  endif
  let entry = s:Entry()
  if entry.path ==# ''
    return ''
  endif
  let s:clip = {'op': 'move', 'path': entry.path}
  echom 'Vim tree: cut ' . fnamemodify(entry.path, ':t')
  return ''
endfunction

function! s:Paste(islocal) abort
  if !a:islocal
    return ''
  endif
  if s:clip.path ==# ''
    call s:Warn('clipboard is empty')
    return ''
  endif
  let target = s:Join(s:BaseDir(), fnamemodify(s:clip.path, ':t'))
  if target ==# s:clip.path || stridx(target, s:clip.path . '/') == 0
    call s:Warn('cannot paste into itself')
    return ''
  endif
  if filereadable(target) || isdirectory(target)
    call s:Warn('already exists: ' . target)
    return ''
  endif
  try
    if s:clip.op ==# 'copy'
      call system('cp -r -- ' . shellescape(s:clip.path) . ' ' . shellescape(target))
      if v:shell_error
        throw 'copy failed: ' . s:clip.path
      endif
    else
      call rename(s:clip.path, target)
      let s:clip = {'op': '', 'path': ''}
    endif
  catch
    call s:Warn(v:exception)
  endtry
  return 'refresh'
endfunction

function! s:YankText(text) abort
  call setreg('"', a:text)
  " 剪贴板模块在场时经它同步（SSH 会话发送 OSC 52）；否则退回原生行为。
  if exists('*' . get(g:, 'vimrc_lite_clipboard_sync', ''))
    call call(function(g:vimrc_lite_clipboard_sync), [a:text, 'v'])
  elseif has('clipboard')
    call setreg('+', a:text)
  endif
  echom 'Vim tree: yanked ' . a:text
endfunction

function! s:YankName(islocal) abort
  let entry = s:Entry()
  if entry.name ==# ''
    return ''
  endif
  call s:YankText(substitute(entry.name, '/$', '', ''))
  return ''
endfunction

function! s:YankPath(islocal) abort
  let entry = s:Entry()
  if entry.path ==# ''
    return ''
  endif
  let base = get(w:, 'netrw_treetop', get(b:, 'netrw_curdir', ''))
  let rel = entry.path
  if base !=# ''
    let rel = base =~# '/$' ? rel[strlen(base):] : rel[strlen(base) + 1:]
  endif
  call s:YankText(rel)
  return ''
endfunction

function! s:Refresh(islocal) abort
  return 'refresh'
endfunction

function! s:Hidden(islocal) abort
  if !a:islocal
    return ''
  endif
  call netrw#Call('NetrwHidden', 1)
  return ''
endfunction

let g:Netrw_UserMaps = [
      \ ['a', s:sid . 'Create'],
      \ ['r', s:sid . 'Rename'],
      \ ['d', s:sid . 'Delete'],
      \ ['c', s:sid . 'Copy'],
      \ ['x', s:sid . 'Cut'],
      \ ['p', s:sid . 'Paste'],
      \ ['y', s:sid . 'YankName'],
      \ ['Y', s:sid . 'YankPath'],
      \ ['R', s:sid . 'Refresh'],
      \ ['H', s:sid . 'Hidden'],
      \ ]
