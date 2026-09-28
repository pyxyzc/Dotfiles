" 使用 Vim 自带 netrw 管理侧边文件树；关闭插件自动加载时也显式启用。
" 必须早于 netrw 的 BufEnter：直接 vim 目录也走同一套可选工具探测。
augroup vimrc_lite_netrw_load
  autocmd!
  autocmd BufEnter * call <SID>PrepareDirectory()
augroup END

if !empty(globpath($VIMRUNTIME, 'pack/*/opt/netrw', 1, 1))
  " 新版 netrw 改为可选包；只临时开放 Vim 自带目录，保持用户插件隔离。
  " 重载 vimrc 会重建 runtimepath，因此每次都用 packadd 补回 netrw 路径。
  let s:packpath = &packpath
  try
    let &packpath = escape($VIMRUNTIME, ',')
    packadd netrw
  finally
    let &packpath = s:packpath
    unlet s:packpath
  endtry
else
  runtime plugin/netrwPlugin.vim
endif

let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_winsize = 25
let g:netrw_keepdir = 1

nnoremap <silent> <leader>e :call <SID>ToggleTree()<CR>

" 沿用 nvimtree/neotree 的按键习惯，为 netrw 增加文件操作：
"   a 新建（名称以 / 结尾则建目录）、r 重命名、d 删除、R 刷新、H 显示隐藏文件
"   c 复制、x 剪切、p 粘贴、y 复制文件名、Y 复制相对路径
" 通过 netrw 官方的 g:Netrw_UserMaps 注册，操作后由 netrw 自行刷新列表。
let s:clip = get(s:, 'clip', {'op': '', 'path': ''})
let s:copies = get(s:, 'copies', {})

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim tree: ' . a:message
  echohl None
endfunction

" 早期 Vim 8 的 expand('<SID>') 为空；从真实函数引用解析一次脚本前缀。
let s:sid = matchstr(string(function('s:Warn')), '<SNR>\d\+_')

" 不让 netrw 把历史写到 runtimepath 首项（隔离插件后它是 Vim 的系统目录）。
if !exists('g:netrw_home')
  let s:state_home = empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME
  let g:netrw_home = s:state_home . '/vim-lite/netrw'
  try
    if !isdirectory(g:netrw_home)
      call mkdir(g:netrw_home, 'p', 0700)
    endif
  catch
    let g:netrw_dirhistmax = 0
    let s:history_error = 'history unavailable: ' . v:exception
  endtry
endif

" 当前 tab 已有 netrw 窗口时，保持 <leader>e 的关闭行为。
function! s:TreeOpen() abort
  for buffer in tabpagebuflist()
    if getbufvar(buffer, '&filetype') ==# 'netrw'
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

" 批量查找可选工具：每个 PATH 目录只读取一次，避免多个缺失命令反复跨挂载点 stat。
function! s:FindPrograms(names) abort
  if !exists('*readdir')
    let found = {}
    for name in a:names
      if executable(name)
        let found[name] = 1
      endif
    endfor
    return found
  endif
  let wanted = {}
  for name in a:names
    let wanted[name] = 1
  endfor
  let found = {}
  let seen = {}
  for directory in split($PATH, ':', 1)
    " :p 会为目录追加 / 而查询文件系统；这里只需连接路径，不必提前 stat。
    if directory !~# '^/'
      let directory = getcwd() . '/' . directory
    endif
    if directory !~# '/$'
      let directory .= '/'
    endif
    if has_key(seen, directory)
      continue
    endif
    let seen[directory] = 1
    let previous_error = v:errmsg
    try
      let entries = readdir(directory, {entry -> has_key(wanted, entry)})
    catch
      " 目录可能只有执行权限而不能列举，此时仍逐项检查，不漏掉可执行文件。
      let entries = isdirectory(directory) ? keys(wanted) : []
      let v:errmsg = previous_error
    endtry
    for entry in entries
      if executable(directory . entry)
        let found[entry] = 1
        call remove(wanted, entry)
      endif
    endfor
    if empty(wanted)
      break
    endif
  endfor
  return found
endfunction

function! s:LoadNetrw() abort
  if !has('unix')
    return
  endif
  if exists('g:loaded_netrw')
    call s:InstallFastListing()
    return
  endif
  let names = []
  if !exists('g:netrw_dav_cmd')
    let names += ['cadaver', 'curl']
  endif
  if !exists('g:netrw_fetch_cmd')
    let names += ['fetch']
  endif
  if !exists('g:netrw_file_cmd')
    let names += ['elinks', 'links']
  endif
  if empty(names)
    runtime autoload/netrw.vim
    call s:InstallFastListing()
    return
  endif
  let found = s:FindPrograms(names)
  if !exists('g:netrw_dav_cmd')
    let g:netrw_dav_cmd = has_key(found, 'cadaver') ? 'cadaver'
          \ : has_key(found, 'curl') ? 'curl' : ''
  endif
  if !exists('g:netrw_fetch_cmd')
    let g:netrw_fetch_cmd = has_key(found, 'fetch') ? 'fetch -o' : ''
  endif
  let absent_file_command = !exists('g:netrw_file_cmd')
        \ && !has_key(found, 'elinks') && !has_key(found, 'links')
  if !exists('g:netrw_file_cmd')
    let g:netrw_file_cmd = has_key(found, 'elinks') ? 'elinks'
          \ : has_key(found, 'links') ? 'links' : ''
  endif
  try
    runtime autoload/netrw.vim
  finally
    " 上游用变量是否存在判断 file:// 支持；探测期间的占位值不能留下。
    if absent_file_command
      unlet! g:netrw_file_cmd
    endif
  endtry
  call s:InstallFastListing()
endfunction

" 只加速 Unix 本地树的名称/扩展名列举；其他布局、排序和特殊文件名沿用原实现。
function! s:FastListing() abort
  let directory = get(b:, 'netrw_curdir', '')
  if !get(g:, 'vimrc_lite_netrw_fast_listing', 1)
        \ || get(w:, 'netrw_liststyle', -1) != 3 || directory !~# '^/' || directory =~# '://'
        \ || get(g:, 'netrw_dynamic_maxfilenamelen', 0)
        \ || g:netrw_sort_by !~# '^\%(n\|ext\)'
    call call(s:NativeListing, [])
    return
  endif
  " 保留原生 glob，仍遵循 wildignore、suffixes、隐藏文件及失效链接规则。
  let files = call(s:NativeGlob, [directory, '*', 0])
        \ + call(s:NativeGlob, [directory, '.*', 0])
  if !empty(filter(copy(files), 'v:val =~# "[\r\n]"'))
    call call(s:NativeListing, [])
    return
  endif
  let offset = strlen(directory)
  let suffixes = {'link': '@', 'socket': '=', 'fifo': '|', 'dir': '/'}
  let lines = []
  for filename in files
    " 每项只查一次文件类型；绝对路径不再反复经过树路径解析和 isdirectory()。
    let kind = getftype(filename)
    let suffix = has_key(suffixes, kind) ? suffixes[kind] : executable(filename) ? '*' : ''
    let name = substitute(strpart(filename, offset), '^[/\\]', '', '')
    call add(lines, name . suffix)
  endfor
  " 替代每项 :put；后续排序、隐藏、树形渲染仍交给 netrw。
  let position = line('.')
  call append(position, lines)
  call cursor(position + len(lines), 1)
  silent! NetrwKeepj g/^$/d
  silent! NetrwKeepj %s/\r$//e
  call histdel('/', -1)
  let &l:tabstop = g:netrw_maxfilenamelen + 1
endfunction

function! s:FunctionBody(name) abort
  let body = filter(split(execute('function ' . a:name), "\n"),
        \ 'v:val =~# "^\\s*\\d\\+\\s"')
  call map(body, 'substitute(v:val, "^\\s*\\d\\+\\s\\+", "", "")')
  call filter(body, 'v:val !~# ''^\s*\%($\|"\)''')
  return body
endfunction

function! s:TreeIndent(directory, depth) abort
  " 用一个临时叶子读取原生缩进，不猜测 GUI/编码或 runtime 的初始化变量。
  let entries = w:netrw_treedict[a:directory]
  let hide = g:netrw_hide
  let last = line('$')
  let view = winsaveview()
  let probe = 'vim-lite-tree-indent-probe'
  try
    let w:netrw_treedict[a:directory] = [probe]
    let g:netrw_hide = 0
    call call(s:NativeTreeDisplay, [a:directory, a:depth])
    let row = getline('$')
    return strpart(row, 0, strlen(row) - strlen(probe) - strlen(a:depth))
  finally
    let w:netrw_treedict[a:directory] = entries
    let g:netrw_hide = hide
    if line('$') > last
      execute 'silent keepjumps ' . (last + 1) . ',$delete _'
    endif
    call winrestview(view)
  endtry
endfunction

function! s:AppendTreeLeaves(entries, first, last, depth) abort
  if a:first <= a:last
    silent! NetrwKeepj call append(line('$'),
          \ map(a:entries[a:first : a:last], 'a:depth . v:val'))
  endif
endfunction

function! s:FastTreeDisplay(directory, depth) abort
  if !exists('s:tree_indent')
    let s:tree_indent = s:TreeIndent(a:directory, a:depth)
  endif
  if !get(g:, 'vimrc_lite_netrw_fast_tree', 1) || has('gui_running') || a:directory !~# '^/'
    call s:ReferenceTreeDisplay(a:directory, a:depth)
    return
  endif
  " 目录标题和缓存过滤由已核对的原生前半段执行，保留各版本的隐藏规则。
  let depth = s:TreeHead(a:directory, a:depth)
  let entries = w:netrw_treedict[a:directory]
  let first = 0
  let index = match(entries, '\m[/@]$')
  while index >= 0
    let entry = entries[index]
    let path = substitute(s:Join(a:directory, entry), '[@/]$', '', 'e')
    let child = ''
    if entry =~ '/$' && has_key(w:netrw_treedict, path)
      let child = path
    elseif entry =~ '/$' && has_key(w:netrw_treedict, path . '/')
      let child = path . '/'
    elseif entry =~ '@$' && has_key(w:netrw_treedict, path . '@')
      let child = path . '/'
    endif
    if child !=# ''
      call s:AppendTreeLeaves(entries, first, index - 1, depth)
      call s:FastTreeDisplay(child, depth)
      let first = index + 1
    endif
    let index = match(entries, '\m[/@]$', index + 1)
  endwhile
  call s:AppendTreeLeaves(entries, first, len(entries) - 1, depth)
endfunction

function! s:InstallFastTree(prefix) abort
  if !get(g:, 'vimrc_lite_netrw_fast_tree', 1) || has('gui_running')
        \ || get(s:, 'fast_tree_prefix', '') ==# a:prefix
        \ || !exists('*' . a:prefix . 'NetrwTreeDisplay')
    return
  endif
  let body = s:FunctionBody(a:prefix . 'NetrwTreeDisplay')
  " 与列举适配相同，只接受已审查的 v156/v171/v173 完整函数体。
  let reviewed = [
        \ 'cffa2478ab99c62229ad34e1d0a2c076f495be49a21a1ad908bca8a10d305d41',
        \ 'b6dac9dfb933667731c9c1224eae6e4943c28f72914764b8d9fbdb9e819577a4',
        \ 'b63316cf759dcb25c71f8f1bb5a29646a6c83c289311129dfd0fc831d9a6c0fb']
  if index(reviewed, sha256(join(body, "\n"))) < 0
    return
  endif
  let loop = len(body) - index(reverse(copy(body)), 'for entry in w:netrw_treedict[dir]') - 1
  let head = body[: loop - 1]
  call map(head, 'substitute(v:val, "s:treedepthstring", "s:tree_indent", "g")')
  execute "function! s:TreeHead(dir, depth)\n" . join(head, "\n") . "\nreturn depth\nendfunction"
  " 回退复用原函数体，仅重绑定缩进和递归入口，避免每层都额外套上转发栈帧。
  let reference = map(copy(body),
        \ 'substitute(v:val, "s:treedepthstring", "s:tree_indent", "g")')
  " NetrwKeepj 在原生脚本上下文执行，递归入口必须绑定绝对 SID。
  call map(reference,
        \ 'substitute(v:val, "s:NetrwTreeDisplay", s:sid . "ReferenceTreeDisplay", "g")')
  execute "function! s:ReferenceTreeDisplay(dir, depth)\n" . join(reference, "\n") . "\nendfunction"
  let s:NativeTreeDisplay = funcref(a:prefix . 'NetrwTreeDisplay')
  execute 'function! ' . a:prefix . "NetrwTreeDisplay(dir, depth) abort\n"
        \ . 'call ' . s:sid . "FastTreeDisplay(a:dir, a:depth)\nendfunction"
  let s:fast_tree_prefix = a:prefix
  unlet! s:tree_indent
endfunction

function! s:InstallFastListing() abort
  if !has('unix') || !exists('*funcref') || !exists('*sha256')
    return
  endif
  let scripts = filter(split(execute('scriptnames'), "\n"),
        \ 'v:val =~# "/autoload/netrw\.vim$"')
  if len(scripts) != 1
    return
  endif
  let prefix = '<SNR>' . matchstr(scripts[0], '^\s*\zs\d\+\ze:') . '_'
  call s:InstallFastTree(prefix)
  if get(s:, 'fast_listing_prefix', '') ==# prefix
        \ || !exists('*' . prefix . 'LocalListing') || !exists('*' . prefix . 'NetrwGlob')
    return
  endif
  " 私有入口必须与已审查的完整函数体一致；未知 runtime 不替换，不按版本号猜测。
  let body = s:FunctionBody(prefix . 'LocalListing')
  " 依次为 Vim 8.0.1394/v156、8.2.5172/v171、系统 Vim 9.1/v173 的 LocalListing。
  let reviewed = [
        \ 'df93a842a9d4a1953f7bcc52e3c586775e8c6da54f8c2cffe416a4458e7600d7',
        \ '01da42ff5418ff9f4f3542f488d46dc98a1794d4ac79549593cb9e8769ffbffe',
        \ 'de05c1c827370c1695368876747648dc05e5161fd831e5dc1b57d07e71e5f2c9']
  if index(reviewed, sha256(join(body, "\n"))) < 0
    return
  endif
  " funcref 绑定原函数对象，重定义入口后回退不会递归到自身。
  let s:NativeListing = funcref(prefix . 'LocalListing')
  let s:NativeGlob = funcref(prefix . 'NetrwGlob')
  execute 'function! ' . prefix . "LocalListing() abort\n"
        \ . 'call ' . s:sid . "FastListing()\nendfunction"
  let s:fast_listing_prefix = prefix
endfunction

function! s:PrepareDirectory() abort
  if !exists('g:loaded_netrw') && isdirectory(expand('<amatch>'))
    call s:LoadNetrw()
  endif
endfunction

function! s:WindowCommand(window, command) abort
  if exists('*win_execute')
    call win_execute(a:window, 'noautocmd ' . a:command)
    return
  endif
  let origin = win_getid()
  try
    noautocmd let found = win_gotoid(a:window)
    if found
      execute 'noautocmd ' . a:command
    endif
  finally
    noautocmd call win_gotoid(origin)
  endtry
endfunction

function! s:OpenTree(directory) abort
  " 旧版 Lexplore 带目录参数会重复 Explore 两次。无参数入口只遍历一次。
  " 新树继承第一个窗口的 cwd；临时切换该窗口，最后连同目录作用域一起恢复。
  let first = win_getid(1)
  let directory = getcwd(1)
  let scope = haslocaldir(1)
  let restore = (scope == 1 ? 'lcd ' : scope == 2 ? 'tcd ' : 'cd ') . fnameescape(directory)
  let windows = map(getwininfo(), 'v:val.winid')
  try
    call s:WindowCommand(first, 'lcd ' . fnameescape(a:directory))
    Lexplore
  finally
    call s:WindowCommand(first, restore)
    " 即便 netrw 在创建窗口后报错，新窗口也不能遗留临时 cwd。
    let tree = win_getid()
    if index(windows, tree) < 0
      call s:WindowCommand(tree, restore)
    endif
  endtry
endfunction

" 早期 netrw#Call 把整个参数列表当作一个参数，且丢弃返回值。
" 仅在识别到此实现时解析一次脚本 ID；新版继续使用原生入口。
function! s:NetrwCall(name, ...) abort
  if !exists('s:netrw_legacy_sid')
    let s:netrw_legacy_sid = ''
    if stridx(execute('function netrw#Call'), 'string(a:000)') >= 0
      let scripts = filter(split(execute('scriptnames'), "\n"),
            \ 'v:val =~# "/autoload/netrw\.vim$"')
      if len(scripts) != 1
        unlet s:netrw_legacy_sid
        throw 'Vim tree: cannot identify legacy netrw script'
      endif
      let s:netrw_legacy_sid = '<SNR>' . matchstr(scripts[0], '^\s*\zs\d\+\ze:') . '_'
    endif
  endif
  return empty(s:netrw_legacy_sid) ? call('netrw#Call', [a:name] + a:000)
        \ : call(s:netrw_legacy_sid . a:name, a:000)
endfunction

function! s:CloseTree() abort
  let focus = win_getid()
  try
    " 常规侧栏仍由 Lexplore 保存宽度和视图；直接打开的目录没有此标记。
    let sidebar = get(t:, 'netrw_lexbufnr', -1)
    if winnr('$') > 1 && sidebar > 0 && bufwinnr(sidebar) > 0
          \ && getbufvar(sidebar, '&filetype') ==# 'netrw'
      Lexplore
    endif
    let tab = tabpagenr()
    let trees = filter(getwininfo(),
          \ 'v:val.tabnr == tab && getbufvar(v:val.bufnr, "&filetype") ==# "netrw"')
    for tree in trees
      if !win_gotoid(tree.winid)
        continue
      endif
      if winnr('$') > 1
        close
      else
        " 最后一个窗口不退出 Vim；优先回到已有编辑 buffer，否则留一个空窗口。
        let alternate = bufnr('#')
        if buflisted(alternate) && getbufvar(alternate, '&buftype') ==# ''
              \ && getbufvar(alternate, '&filetype') !=# 'netrw'
              \ && !isdirectory(bufname(alternate))
          execute 'buffer ' . alternate
        else
          enew
        endif
        unlet! t:netrw_lexbufnr
      endif
    endfor
  finally
    call win_gotoid(focus)
  endtry
endfunction

function! s:ToggleTree() abort
  if exists('s:history_error')
    call s:Warn(s:history_error)
    unlet s:history_error
  endif
  if s:TreeOpen()
    call s:CloseTree()
    return
  endif
  call s:LoadNetrw()
  call s:OpenTree(s:TreeDirectory())
endfunction

" 树形列表每层以 "| " 或 "│ " 缩进；统计深度，并去掉缩进、提示文本和尾部标记。
let s:indent = '^\%(\%(|\|│\) \)*'

function! s:Depth(line) abort
  return strchars(matchstr(a:line, s:indent)) / 2
endfunction

function! s:Name(line) abort
  let name = substitute(a:line, s:indent, '', '')
  let name = substitute(name, '\t -->.*$', '', '')
  return substitute(name, '[@*=|]$', '', '')
endfunction

function! s:Join(base, name) abort
  return (a:base =~# '/$' ? a:base : a:base . '/') . a:name
endfunction

function! s:ResolveTreeMark(raw, entry) abort
  let displayed = substitute(a:raw, '\t -->.*$', '', '')
  let mark = matchstr(displayed, '[@*=|]$')
  if empty(mark)
    return a:entry
  endif
  let literal = a:entry.path . mark
  let kind = getftype(literal)
  let suffixes = {'link': '@', 'socket': '=', 'fifo': '|', 'dir': '/'}
  let base_kind = getftype(a:entry.path)
  let base_mark = has_key(suffixes, base_kind) ? suffixes[base_kind]
        \ : executable(a:entry.path) ? '*' : ''
  " 只有不带类型后缀的真实文件，才可能与另一条目的类型标记显示相同。
  if kind !=# ''
    if has_key(suffixes, kind) || executable(literal) || base_mark ==# mark
      call s:Warn('ambiguous filename/type marker; use an explicit path: ' . literal)
      return {'name': '', 'path': '', 'dir': 0}
    endif
    return {'name': a:entry.name . mark, 'path': literal, 'dir': 0}
  endif
  if base_kind !=# '' && base_mark !=# mark
    call s:Warn('stale filename/type marker; refresh before operating: ' . literal)
    return {'name': '', 'path': '', 'dir': 0}
  endif
  return a:entry
endfunction

" 光标所在条目；path 为空表示树根、../ 或不可操作项。
function! s:Entry() abort
  let curdir = get(b:, 'netrw_curdir', '')
  if curdir ==# ''
    return {'name': '', 'path': '', 'dir': 0}
  endif
  let liststyle = get(w:, 'netrw_liststyle', get(g:, 'netrw_liststyle', 0))
  if liststyle != 3
    let name = s:NetrwCall('NetrwGetWord')
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
  let view = winsaveview()
  try
    " 原生向后搜索指定深度，跳过兄弟节点和已展开子树，避免逐行 Vimscript 调用。
    " 从行首搜索，不能把当前条目自身当成父目录；最终恢复光标和滚动位置。
    call cursor(line('.'), 1)
    while parent >= 1
      let pattern = '\m^\%(| \|│ \)\{' . parent . '}\%(| \|│ \)\@!'
      let lnum = search(pattern, 'bW', 1)
      if !lnum
        break
      endif
      call insert(parts, substitute(s:Name(getline(lnum)), '/$', '', ''))
      let parent -= 1
    endwhile
  finally
    call winrestview(view)
  endtry
  let parts += [substitute(name, '/$', '', '')]
  let path = s:Join(root, join(parts, '/'))
  return s:ResolveTreeMark(raw, {'name': name, 'path': path, 'dir': name =~# '/$'})
endfunction

" 新建/粘贴的目标目录：选中目录时用该目录，否则用当前浏览目录。
function! s:BaseDir() abort
  let entry = s:Entry()
  if entry.dir && entry.path !=# ''
    return entry.path
  endif
  if exists('w:netrw_treetop') && s:Depth(getline('.')) == 0
    return w:netrw_treetop
  endif
  return get(b:, 'netrw_curdir', '')
endfunction

function! s:RefreshDirectory(directory) abort
  if get(w:, 'netrw_liststyle', -1) == 3 && len(get(w:, 'netrw_treedict', {})) > 1
    " 旧版不更新子树；较新版只收集裸文件名，丢掉类型后缀及多层展开。
    " 每个已展开目录沿用完整的原生列举、排序、隐藏规则，最后重建树根。
    let root = w:netrw_treetop
    let cache = w:netrw_treedict
    let directories = filter(keys(cache), 'v:val !=# root && isdirectory(v:val)')
    let view = winsaveview()
    let register = getreg('"', 1, 1)
    let register_type = getregtype('"')
    try
      for directory in directories
        " 列举子目录时不反复渲染整棵树；所有缓存更新后只合成一次最终树。
        let w:netrw_treedict = {}
        let w:netrw_treetop = directory
        setlocal modifiable noreadonly
        silent keepjumps %delete _
        call netrw#LocalBrowseCheck(directory)
        let cache[directory] = w:netrw_treedict[directory]
      endfor
    finally
      let w:netrw_treedict = cache
      let w:netrw_treetop = root
      try
        setlocal modifiable noreadonly
        silent keepjumps %delete _
        call netrw#LocalBrowseCheck(root)
      finally
        call setreg('"', register, register_type)
        call winrestview(view)
      endtry
    endtry
    return ''
  endif
  call s:NetrwCall('NetrwRefresh', 1, a:directory)
  return ''
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
    return s:RefreshDirectory(fnamemodify(target, ':h'))
  endif
  let parent = fnamemodify(target, ':h')
  if !isdirectory(parent)
    call mkdir(parent, 'p')
  endif
  call writefile([], target)
  call s:RefreshDirectory(fnamemodify(target, ':h'))
  return 'call ' . s:sid . 'Open(' . string(target) . ')'
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
    if rename(entry.path, target) != 0
      throw 'rename failed: ' . entry.path
    endif
  catch
    call s:Warn(v:exception)
  endtry
  return s:RefreshDirectory(fnamemodify(entry.path, ':h'))
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
    if delete(entry.path, entry.dir ? 'rf' : '') != 0
      throw 'delete failed: ' . entry.path
    endif
  catch
    call s:Warn(v:exception)
  endtry
  return s:RefreshDirectory(fnamemodify(entry.path, ':h'))
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

" 树中的浏览目录会随展开/刷新改变；复制归属用树根，而非最后浏览的子目录。
function! s:CopyDirectory(window) abort
  let directory = getbufvar(winbufnr(a:window), 'netrw_curdir', '')
  return getwinvar(a:window, 'netrw_liststyle', -1) == 3
        \ ? getwinvar(a:window, 'netrw_treetop', directory) : directory
endfunction

function! s:RefreshCopies() abort
  let directory = get(w:, 'vimrc_lite_copy_refresh', '')
  if empty(directory)
    return
  endif
  unlet w:vimrc_lite_copy_refresh
  if &filetype ==# 'netrw' && s:CopyDirectory(win_getid()) ==# directory
    call s:RefreshDirectory(directory)
  endif
endfunction

function! s:CopyFinished(state, timer) abort
  if get(a:state, 'done', 0)
    return
  endif
  let a:state.done = 1
  if has_key(a:state, 'poll')
    call timer_stop(a:state.poll)
  endif
  if get(s:copies, a:state.target, {}) is a:state
    call remove(s:copies, a:state.target)
  endif
  if get(a:state, 'cancelled', 0)
    call s:Warn('copy cancelled; partial target retained: ' . a:state.target)
  elseif a:state.status != 0
    call s:Warn('copy failed (status ' . a:state.status
          \ . '); partial target retained if present: ' . a:state.target)
  else
    echom 'Vim tree: copy finished (existing files kept): ' . a:state.target
  endif
  " 完成时仅刷新原来的树；关闭窗口、切目录或在其它窗口编辑都不会被抢焦点。
  if !empty(getwininfo(a:state.window))
        \ && getwinvar(a:state.window, '&filetype') ==# 'netrw'
        \ && s:CopyDirectory(a:state.window) ==# a:state.directory
    call setwinvar(a:state.window, 'vimrc_lite_copy_refresh', a:state.directory)
    if win_getid() == a:state.window && mode(1) ==# 'n'
      call s:RefreshCopies()
    endif
  endif
endfunction

function! s:CopyExited(state, job, status) abort
  let a:state.status = a:status
  call timer_start(0, function('s:CopyFinished', [a:state]))
endfunction

function! s:CopyPoll(state, timer) abort
  if !get(a:state, 'done', 0)
    " 触发 exit_cb，避免小文件复制也等待默认的 100 ms 进程状态检查。
    call job_status(a:state.job)
  endif
endfunction

function! s:StartCopy(source, target) abort
  let state = {'source': a:source, 'target': a:target, 'window': win_getid(),
        \ 'directory': s:CopyDirectory(win_getid()), 'done': 0}
  " -n 防止异步复制期间新出现的目标文件被覆盖；-T 防止目标变成目录后多套一层。
  " 所有通道指向 /dev/null，退出 Vim 后复制继续，不留下管道或临时日志。
  let state.job = job_start(['cp', '-rnT', '--', a:source, a:target],
        \ {'in_io': 'null', 'out_io': 'null', 'err_io': 'null', 'stoponexit': '',
        \ 'exit_cb': function('s:CopyExited', [state])})
  if job_status(state.job) ==# 'fail'
    throw 'could not start cp; source remains unchanged'
  endif
  let s:copies[a:target] = state
  let state.poll = timer_start(10, function('s:CopyPoll', [state]), {'repeat': -1})
  echom 'Vim tree: copying to ' . a:target
endfunction

function! s:CopyStatus(cancel) abort
  if empty(s:copies)
    echom 'Vim tree: no copies running'
  endif
  for state in values(s:copies)
    if a:cancel
      let state.cancelled = 1
      call job_stop(state.job, 'term')
    else
      echom 'Vim tree: copying ' . state.source . ' -> ' . state.target
    endif
  endfor
endfunction

command! VimTreeCopyStatus call <SID>CopyStatus(0)
command! VimTreeCopyCancel call <SID>CopyStatus(1)

augroup vimrc_lite_tree
  autocmd!
  autocmd WinEnter,CursorHold * call <SID>RefreshCopies()
augroup END

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
  if has_key(s:copies, target)
    call s:Warn('copy already running: ' . target)
    return ''
  endif
  if !empty(getftype(target))
    call s:Warn('already exists: ' . target)
    return ''
  endif
  try
    if s:clip.op ==# 'copy'
      if has('job') && has('timers')
        call s:StartCopy(s:clip.path, target)
        return ''
      endif
      call system('cp -rnT -- ' . shellescape(s:clip.path) . ' ' . shellescape(target))
      if v:shell_error
        throw 'copy failed: ' . s:clip.path
      endif
    else
      if rename(s:clip.path, target) != 0
        throw 'move failed: ' . s:clip.path
      endif
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
  return a:islocal ? s:RefreshDirectory(get(w:, 'netrw_treetop', b:netrw_curdir)) : 'refresh'
endfunction

function! s:Hidden(islocal) abort
  if !a:islocal
    return ''
  endif
  if exists('w:netrw_treetop')
    let b:netrw_curdir = w:netrw_treetop
  endif
  if get(w:, 'netrw_liststyle', -1) == 3 && len(get(w:, 'netrw_treedict', {})) > 1
    " 沿用 NetrwHidden 的点文件规则，但刷新走完整子目录缓存，避免裸文件名回退。
    let pattern = '\(^\|,\)\\(^\\|\\s\\s\\)\\zs\\.\\S\\+'
    if g:netrw_list_hide =~ pattern
      let g:netrw_list_hide = substitute(g:netrw_list_hide, pattern, '', '')
    else
      let g:netrw_list_hide .= (empty(g:netrw_list_hide) ? '' : ',') . '\(^\|\s\s\)\zs\.\S\+'
    endif
    let g:netrw_list_hide = substitute(g:netrw_list_hide, '^,', '', '')
    return s:RefreshDirectory(b:netrw_curdir)
  endif
  call s:NetrwCall('NetrwHidden', 1)
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
      \ ['<C-l>', s:sid . 'Refresh'],
      \ ['H', s:sid . 'Hidden'],
      \ ]
