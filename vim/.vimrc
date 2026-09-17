" 离线 Vim 8/9 配置；<leader> 为空格。说明见同目录 README.md。
set nocompatible
let mapleader = ' '
let maplocalleader = ' '
" 重新加载配置前，先归还首页临时修改的显示设置。
if exists('#vimrc_lite_dashboard#User#VimrcLiteReload')
  doautocmd <nomodeline> vimrc_lite_dashboard User VimrcLiteReload
endif
if exists('#vimrc_lite_search#User#VimrcLiteReload')
  doautocmd <nomodeline> vimrc_lite_search User VimrcLiteReload
endif
let s:vimrc_path = expand('<sfile>:p')
let s:config_dir = fnamemodify(resolve(expand('<sfile>:p')), ':h')

" 隔离已有 pack 插件并关闭 plugin 脚本自动加载；注册本地主题目录。
set noloadplugins
let &runtimepath = escape($VIMRUNTIME, ',')
set packpath=
let s:theme = s:config_dir . '/colors/tokyonight-night.vim'
if !filereadable(s:theme)
  let s:theme = s:config_dir . '/.vim/colors/tokyonight-night.vim'
endif
if !filereadable(s:theme)
  let s:theme = expand('~/.vim/colors/tokyonight-night.vim')
endif
if filereadable(s:theme)
  let &runtimepath .= ',' . escape(fnamemodify(s:theme, ':h:h'), ',')
endif
filetype plugin indent on
syntax enable
runtime plugin/netrwPlugin.vim
runtime plugin/matchparen.vim

set encoding=utf-8
set hidden autoread
set number relativenumber cursorline
set laststatus=2 showmode showcmd
set statusline=%n:%f\ %m%r%h%=%y\ %l:%c\ %p%%
set scrolloff=5 sidescrolloff=5 nowrap
set splitbelow splitright
set backspace=indent,eol,start
set expandtab tabstop=4 softtabstop=4 shiftwidth=4
set incsearch hlsearch ignorecase smartcase
set wildmenu wildmode=longest:full,full
set complete=.,w,b,t
set completeopt=menuone,noinsert,noselect
set path=.,**
set wildignore+=*/.git/*,*/.venv/*,*/venv/*,*/__pycache__/*,*/build/*,*/dist/*,*/node_modules/*,*.pyc,*.o,*.so
set background=dark
if exists('+termguicolors')
  let &termguicolors = get(g:, 'vimrc_lite_truecolor', 1)
endif

" 仓库内直接试用、符号链接安装、复制安装均可。
if filereadable(s:theme)
  colorscheme tokyonight-night
else
  echohl WarningMsg
  echom 'Vim lite: missing colors/tokyonight-night.vim'
  echohl None
endif

let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_winsize = 25
let g:netrw_keepdir = 1

augroup vimrc_lite
  autocmd!
  autocmd FileType python,c,cpp,cuda setlocal expandtab tabstop=4 softtabstop=4 shiftwidth=4
  autocmd FileType make setlocal noexpandtab tabstop=8 softtabstop=0 shiftwidth=8
  autocmd FileType python setlocal foldmethod=indent foldlevel=99
  autocmd FileType c,cpp,cuda setlocal foldmethod=syntax foldlevel=99
  autocmd FileType help,qf nnoremap <silent><buffer> q :close<CR>
  autocmd BufReadPost * if line("'\"") > 0 && line("'\"") <= line('$') | execute 'normal! g`"' | endif
augroup END

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim lite: ' . a:message
  echohl None
endfunction

" LSP 模块与其固定版本客户端一起部署，显式加载以保留插件隔离。
let s:lsp = s:config_dir . '/lsp.vim'
if !filereadable(s:lsp)
  let s:lsp = s:config_dir . '/.vim/lsp.vim'
endif
if !filereadable(s:lsp)
  let s:lsp = expand('~/.vim/lsp.vim')
endif
if filereadable(s:lsp)
  execute 'source ' . fnameescape(s:lsp)
else
  command! VimLspStatus call <SID>Warn('missing lsp.vim; copy the complete vim directory')
endif

" 顶部编号与数字快捷键共用同一列表，不等同于 :buffer 的实际编号。
function! s:ListedBuffers() abort
  return sort(getbufinfo({'buflisted': 1}), {left, right -> left.bufnr - right.bufnr})
endfunction

function! s:BufferNames(buffers) abort
  let paths = map(copy(a:buffers), 'split(v:val.name, "/")')
  let names = []
  for index in range(len(paths))
    let parts = paths[index]
    if empty(parts)
      call add(names, '[No Name]')
      continue
    endif
    let depth = 1
    let name = parts[-1]
    while depth < len(parts)
      let duplicate = 0
      for other in range(len(paths))
        if other != index && join(paths[other][-depth:], '/') ==# name
          let duplicate = 1
          break
        endif
      endfor
      if !duplicate | break | endif
      let depth += 1
      let name = join(parts[-depth:], '/')
    endwhile
    call add(names, strtrans(name))
  endfor
  return names
endfunction

" 按显示列截断，避免切断中文或把 tabline 控制符当作文件名执行。
function! s:BufferLabel(name, width) abort
  if strdisplaywidth(a:name) <= a:width | return a:name | endif
  let name = a:name
  while !empty(name) && strdisplaywidth(name) > a:width - 1
    let name = strcharpart(name, 0, strchars(name) - 1)
  endwhile
  return name . '~'
endfunction

function! s:BufferLine() abort
  let buffers = s:ListedBuffers()
  if empty(buffers) | return '%#TabLineFill#' | endif
  let names = s:BufferNames(buffers)
  let current = index(map(copy(buffers), 'v:val.bufnr'), bufnr('%'))
  let focus = current >= 0 ? current : max([0, index(map(copy(buffers), 'v:val.bufnr'), bufnr('#'))])
  let tabs = tabpagenr('$') > 1 ? printf(' Tab %d/%d ', tabpagenr(), tabpagenr('$')) : ''
  " 极窄窗口优先保留当前 buffer 编号和状态。
  if &columns < 40 | let tabs = '' | endif
  let budget = &columns - strdisplaywidth(tabs)
  let reserve = len(buffers) > 1 ? 4 : 0
  let labels = []
  let widths = []
  for index in range(len(buffers))
    let buffer = buffers[index]
    let prefix = printf(' %d:', index + 1)
    let flags = (buffer.changed ? ' +' : '')
          \ . (getbufvar(buffer.bufnr, '&readonly') ? ' [RO]' : '') . ' '
    if getbufvar(buffer.bufnr, '&buftype') ==# 'terminal'
      let flags = ' [term]' . flags
    endif
    let width = max([1, min([32, budget - reserve - strdisplaywidth(prefix . flags)])])
    let label = prefix . s:BufferLabel(names[index], width) . flags
    call add(labels, label)
    call add(widths, strdisplaywidth(label))
  endfor
  let first = focus
  let last = focus
  let used = widths[focus]
  " 从当前项向两侧扩展连续区间；隐藏项不参与重新编号。
  while 1
    let expanded = 0
    if last + 1 < len(buffers)
      let markers = (first > 0 ? 2 : 0) + (last + 2 < len(buffers) ? 2 : 0)
      if used + widths[last + 1] + markers <= budget
        let last += 1
        let used += widths[last]
        let expanded = 1
      endif
    endif
    if first > 0
      let markers = (first > 1 ? 2 : 0) + (last + 1 < len(buffers) ? 2 : 0)
      if used + widths[first - 1] + markers <= budget
        let first -= 1
        let used += widths[first]
        let expanded = 1
      endif
    endif
    if !expanded | break | endif
  endwhile
  let line = '%#TabLineFill#' . (first > 0 ? '< ' : '')
  for index in range(first, last)
    let line .= index == current ? '%#TabLineSel#' : '%#VimrcBufferLine#'
    let line .= substitute(labels[index], '%', '%%', 'g')
  endfor
  return line . '%#TabLineFill#' . (last + 1 < len(buffers) ? ' >' : '') . '%=' . tabs
endfunction

function! s:BufferLineColors() abort
  highlight! link VimrcBufferLine StatusLine
endfunction
call s:BufferLineColors()
set showtabline=2
if has('gui_running') | set guioptions-=e | endif
let &tabline = '%!' . expand('<SID>') . 'BufferLine()'
augroup vimrc_lite_buffers
  autocmd!
  autocmd ColorScheme * call <SID>BufferLineColors()
  autocmd BufAdd,BufDelete,BufEnter,BufFilePost,BufWritePost,TextChanged,TextChangedI,VimResized * redrawtabline
  if exists('##OptionSet')
    autocmd OptionSet readonly,buflisted redrawtabline
  endif
augroup END

function! s:GoBuffer(index) abort
  let buffers = s:ListedBuffers()
  if a:index <= len(buffers)
    execute 'buffer ' . buffers[a:index - 1].bufnr
  else
    call s:Warn('no buffer at position ' . a:index)
  endif
endfunction

" 删除 buffer 前替换显示它的窗口，保留分屏布局；取消不改变布局。
function! s:CloseBuffer() abort
  if &buftype ==# 'terminal' && exists('*term_getstatus')
        \ && term_getstatus(bufnr('%')) =~# 'running'
    call s:Warn('shell is running; exit the shell before deleting its buffer')
    return
  endif
  if &buftype !=# '' && &buftype !=# 'terminal'
    confirm quit
    return
  endif
  let buffers = getbufinfo({'buflisted': 1})
  if len(buffers) <= 1
    confirm qall
    return
  endif
  let discard = 0
  if &modified
    let choice = confirm('Save changes before closing?', "&Save\n&Discard\n&Cancel", 3)
    if choice == 1
      try
        if empty(bufname('%'))
          let name = input('Save as: ', '', 'file')
          if empty(name) | return | endif
          execute 'write ' . fnameescape(name)
        else
          update
        endif
      catch
        call s:Warn(v:exception)
        return
      endtry
    elseif choice == 2
      let discard = 1
    else
      return
    endif
  endif
  let target = bufnr('%')
  let replacement = bufnr('#')
  if replacement == target || !buflisted(replacement)
    let candidates = filter(map(buffers, 'v:val.bufnr'), 'v:val != target')
    let replacement = candidates[0]
  endif
  let origin = win_getid()
  let windows = copy(getbufinfo(target)[0].windows)
  try
    for window in windows
      if win_gotoid(window)
        execute 'keepalt buffer ' . replacement
      endif
    endfor
    execute 'bdelete' . (discard ? '!' : '') . ' ' . target
  catch
    for window in windows
      if win_gotoid(window) && bufexists(target)
        execute 'keepalt buffer ' . target
      endif
    endfor
    call s:Warn(v:exception)
  finally
    call win_gotoid(origin)
  endtry
endfunction

function! s:Editable() abort
  if &buftype !=# '' || !&modifiable || &readonly
    call s:Warn('current buffer is not an editable file')
    return 0
  endif
  return 1
endfunction

function! s:ClearBuffer() abort
  if s:Editable()
    %delete _
  endif
endfunction

function! s:TrimWhitespace() abort
  if !s:Editable() | return | endif
  let view = winsaveview()
  let search = @/
  try
    keeppatterns %s/\s\+$//e
  finally
    let @/ = search
    call winrestview(view)
  endtry
endfunction

" 编码内容经 stdin 传入，不拼进 shell 命令。OSC 52 只写剪贴板。
function! s:Osc52(text) abort
  if !executable('base64')
    throw 'base64 is unavailable; content remains in the Vim register'
  endif
  let encoded = system('base64', a:text)
  if v:shell_error
    throw 'base64 failed; content remains in the Vim register'
  endif
  return "\e]52;c;" . substitute(encoded, '[\r\n]', '', 'g') . "\x07"
endfunction

function! s:Copy(text, regtype) abort
  call setreg('"', a:text, a:regtype)
  let remote = !empty($SSH_TTY) || !empty($SSH_CONNECTION)
  if get(g:, 'vimrc_lite_osc52', remote)
    try
      call writefile([s:Osc52(a:text)], '/dev/tty', 'b')
      echom 'Copied to Vim; OSC 52 sent (requires terminal clipboard support)'
    catch
      call s:Warn('OSC 52 unavailable; copied to Vim only. ' . v:exception)
    endtry
  elseif has('clipboard')
    try
      call setreg('+', a:text, a:regtype)
      echom 'Copied to Vim and system clipboard'
    catch
      call s:Warn('system clipboard unavailable; copied to Vim only')
    endtry
  else
    echom 'Copied to Vim register'
  endif
endfunction

function! s:CopyPath() abort
  if &buftype !=# '' || empty(bufname('%'))
    call s:Warn('current buffer has no file path')
    return
  endif
  call s:Copy(expand('%:p'), 'v')
endfunction

function! s:CopyContent() abort
  if &buftype !=# ''
    call s:Warn('current buffer is not a file')
    return
  endif
  let ending = &fileformat ==# 'dos' ? "\r\n" : (&fileformat ==# 'mac' ? "\r" : "\n")
  let text = join(getline(1, '$'), ending) . (&endofline ? ending : '')
  call s:Copy(text, &endofline && &fileformat !=# 'mac' ? 'V' : 'v')
endfunction

function! s:ToggleList(location) abort
  let info = a:location ? getloclist(0, {'winid': 0}) : getqflist({'winid': 0})
  execute a:location ? (info.winid ? 'lclose' : 'lopen') : (info.winid ? 'cclose' : 'copen')
endfunction

" 搜索模块与首页都支持仓库试用、符号链接和复制安装。
let s:search = s:config_dir . '/search.vim'
if !filereadable(s:search)
  let s:search = s:config_dir . '/.vim/search.vim'
endif
if !filereadable(s:search)
  let s:search = expand('~/.vim/search.vim')
endif
if filereadable(s:search)
  execute 'source ' . fnameescape(s:search)
else
  command! VimFind call <SID>Warn('missing search.vim; copy the complete vim directory')
  command! VimSearch call <SID>Warn('missing search.vim; copy the complete vim directory')
endif

" 配置编辑入口与独立首页。
command! VimConfig execute 'edit ' . fnameescape(s:vimrc_path)
let s:dashboard = s:config_dir . '/dashboard.vim'
if !filereadable(s:dashboard)
  let s:dashboard = s:config_dir . '/.vim/dashboard.vim'
endif
if !filereadable(s:dashboard)
  let s:dashboard = expand('~/.vim/dashboard.vim')
endif
if filereadable(s:dashboard)
  execute 'source ' . fnameescape(s:dashboard)
else
  call s:Warn('missing dashboard.vim; copy the complete vim directory')
endif

" 文件、buffer、标签页。
nnoremap <silent> <C-s> :wall<CR>
inoremap <silent> <C-s> <C-o>:wall<CR>
xnoremap <silent> <C-s> <Esc>:wall<CR>gv
nnoremap <silent> <C-w> :call <SID>CloseBuffer()<CR>
nnoremap <silent> H :bprevious<CR>
nnoremap <silent> L :bnext<CR>
nnoremap <silent> <A-o> :bprevious<CR>
nnoremap <silent> <A-i> :bnext<CR>
nnoremap <silent> <leader>bn :enew<CR>
nnoremap <leader>bp :ls<CR>:buffer<Space>
for s:index in range(1, 9)
  execute 'nnoremap <silent> <leader>' . s:index . ' :call <SID>GoBuffer(' . s:index . ')<CR>'
endfor
nnoremap <silent> <leader>bP :call <SID>CopyPath()<CR>
nnoremap <silent> <leader>bC :call <SID>CopyContent()<CR>
nnoremap <silent> <leader>bD :call <SID>ClearBuffer()<CR>
xnoremap <silent> <leader>bD "_d
nnoremap <silent> <leader>bw :call <SID>TrimWhitespace()<CR>
nnoremap <silent> tn :tabnew<CR>
nnoremap <silent> tj :tabprevious<CR>
nnoremap <silent> tk :tabnext<CR>
nnoremap <silent> to :confirm tabonly<CR>
nnoremap <silent> <leader>aN :tab split<CR>
nnoremap <silent> <leader>an :$tabnew<CR>
nnoremap <silent> <leader>ah :-tabmove<CR>
nnoremap <silent> <leader>al :+tabmove<CR>
nnoremap <silent> <leader>ao :confirm tabonly<CR>

" 窗口映射不递归展开，因此不会触发上面的 Ctrl-w 关闭操作。
for s:direction in ['h', 'j', 'k', 'l']
  execute 'nnoremap <silent> <C-' . s:direction . '> <C-w>' . s:direction
  execute 'nnoremap <silent> <A-' . s:direction . '> <C-w>' . s:direction
endfor
nnoremap <silent> <C-Up> :resize -2<CR>
nnoremap <silent> <C-Down> :resize +2<CR>
nnoremap <silent> <C-Left> :vertical resize -2<CR>
nnoremap <silent> <C-Right> :vertical resize +2<CR>
nnoremap <silent> <leader>v :vsplit<CR>
nnoremap <silent> <leader>e :Lexplore<CR>
nnoremap <silent> <leader>q :confirm quit<CR>
xnoremap < <gv
xnoremap > >gv

" 搜索、结果列表、消息。
nnoremap <silent> <leader>ff :VimFind<CR>
nnoremap <silent> <leader>fp :VimSearch<CR>
nnoremap <leader>fo :browse oldfiles<CR>
nnoremap <silent> <leader>fh :nohlsearch<CR>
nnoremap <silent> [q :cprevious<CR>
nnoremap <silent> ]q :cnext<CR>
nnoremap <silent> <leader>xQ :call <SID>ToggleList(0)<CR>
nnoremap <silent> <leader>xL :call <SID>ToggleList(1)<CR>
nnoremap <leader>nh :messages<CR>

" 直接运行本机 LazyGit，不需要 Vim 插件。
function! s:LazyGit() abort
  if !has('terminal') || !executable('lazygit')
    call s:Warn('LazyGit requires Vim +terminal and lazygit in PATH')
    return
  endif
  tabnew
  terminal ++curwin ++close lazygit
endfunction
nnoremap <silent> <leader>gg :call <SID>LazyGit()<CR>

if has('terminal')
  nnoremap <silent> <leader>; :tabnew<Bar>terminal ++curwin<CR>
  tnoremap <Esc><Esc> <C-w>N
endif
