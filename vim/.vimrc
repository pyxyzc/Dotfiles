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
let s:config_dir = fnamemodify(resolve(s:vimrc_path), ':h')

" 仓库内直接试用、符号链接安装、复制安装共用同一查找顺序。
" 与内部函数绑定的按键（buffer 栏、注释切换、文件树）由各模块自带；
" 基于命令的模块（搜索、终端、Git、剪贴板）由本文件的按键统一接线。
function! s:FindModule(name) abort
  for candidate in [s:config_dir . '/' . a:name,
        \ s:config_dir . '/.vim/' . a:name, expand('~/.vim/' . a:name)]
    if filereadable(candidate)
      return candidate
    endif
  endfor
  return ''
endfunction

function! s:SourceModule(name) abort
  let module = s:FindModule(a:name)
  if empty(module)
    return 0
  endif
  execute 'source ' . fnameescape(module)
  return 1
endfunction

" 隔离已有 pack 插件并关闭 plugin 脚本自动加载；注册本地主题目录。
set noloadplugins
let &runtimepath = escape($VIMRUNTIME, ',')
set packpath=
let s:theme = s:FindModule('colors/tokyonight-night.vim')
if !empty(s:theme)
  let &runtimepath .= ',' . escape(fnamemodify(s:theme, ':h:h'), ',')
endif
" 必须先于内置 filetypedetect/LSP 注册；重载时保留原来的事件执行顺序。
function! s:LargeFile() abort
  let limit = get(g:, 'vimrc_lite_large_file_bytes', 1024 * 1024)
  if limit > 0 && getfsize(expand('<afile>:p')) >= limit
    let b:vimrc_lite_large_file = 1
    setfiletype text
    setlocal syntax=OFF foldmethod=manual
  endif
endfunction
if !exists('#vimrc_lite_large_file#BufReadPost')
  augroup vimrc_lite_large_file
    autocmd BufReadPost * call s:LargeFile()
  augroup END
endif
filetype plugin indent on
syntax enable
if !s:SourceModule('matchparen.vim')
  runtime plugin/matchparen.vim
endif

set encoding=utf-8
set hidden autoread
" 不创建或使用交换文件，打开文件时也不提示已有交换文件冲突。
set noswapfile
set number relativenumber cursorline
set laststatus=2 showmode showcmd
let &statusline = '%n:%<%f%{exists("*VimContextLabel") ? VimContextLabel() : ""} %m%r%h%='
      \ . '%{exists("*VimLspStatusLabel") ? VimLspStatusLabel() : '
      \ . 'empty(&filetype) ? "" : "[lang: " . &filetype . "]"} %l:%c %p%%'
set scrolloff=5 sidescrolloff=5 nowrap
set splitbelow splitright
set backspace=indent,eol,start
" 终端转义序列独立计时；Esc 不再等待默认的一秒，组合映射仍保留完整输入时间。
set ttimeout ttimeoutlen=30
set expandtab tabstop=4 softtabstop=4 shiftwidth=4
set incsearch hlsearch ignorecase smartcase
set wildmenu wildmode=longest:full,full
set complete=.,w,b
set completeopt=menuone,noinsert,noselect
inoremap <expr> <CR> !pumvisible() ? "\<CR>"
      \ : exists('*complete_info') && complete_info(['selected']).selected < 0
      \ ? "\<C-e>\<CR>" : "\<C-y>"
set path=.,**
set wildignore+=*/.git/*,*/.venv/*,*/venv/*,*/__pycache__/*
set wildignore+=*/build/*,*/dist/*,*/node_modules/*
set wildignore+=*.pyc,*.o,*.so
set background=dark
if exists('+termguicolors')
  let &termguicolors = get(g:, 'vimrc_lite_truecolor', 1)
endif

" 仓库内直接试用、符号链接安装、复制安装均可。
if !empty(s:theme)
  colorscheme tokyonight-night
else
  echohl WarningMsg
  echom 'Vim lite: missing colors/tokyonight-night.vim'
  echohl None
endif

" 当前行使用下划线提示，不铺整行背景色。
if exists('+cursorlineopt')
  set cursorlineopt=both
endif

" 在当前行文字下方绘制横线，并保持背景透明。
highlight CursorLine gui=underline guibg=NONE
highlight CursorLine cterm=underline ctermbg=NONE

" 使用亮粉色强调当前行号，与亮青蓝的普通行号区分。
highlight CursorLineNr gui=bold guifg=#ff6bcb guibg=NONE
highlight CursorLineNr cterm=bold ctermfg=206 ctermbg=NONE

augroup vimrc_lite
  autocmd!
  autocmd FileType vim,vimrc setlocal expandtab tabstop=2 softtabstop=2 shiftwidth=2
  autocmd FileType vim,vimrc setlocal textwidth=100 formatoptions-=t
  autocmd FileType python,c,cpp,cuda setlocal expandtab tabstop=4 softtabstop=4 shiftwidth=4
  autocmd FileType make setlocal noexpandtab tabstop=8 softtabstop=0 shiftwidth=8
  autocmd FileType python,c,cpp,cuda setlocal foldmethod=manual
  autocmd FileType help,qf nnoremap <silent><buffer> q :close<CR>
  autocmd BufReadPost * call s:RestoreCursor()
augroup END

function! s:RestoreCursor() abort
  if line("'\"") > 0 && line("'\"") <= line('$')
    execute 'normal! g`"'
  endif
endfunction

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim lite: ' . a:message
  echohl None
endfunction

function! s:Quit() abort
  if !&modified
    quit
    return
  endif
  echohl WarningMsg
  echo 'Save changes before closing? [s]ave [q]uit [c]ancel'
  echohl None
  while 1
    let key = getchar()
    if type(key) == v:t_number
      let key = nr2char(key)
    endif
    if key =~# '^[sS]$'
      try
        update
      catch
        call s:Warn(v:exception)
        return
      endtry
      quit
      return
    endif
    if key =~# '^[qQ]$'
      quit!
      return
    endif
    if key =~# '^[cC]$' || key ==# "\<Esc>" || key ==# "\<CR>"
      return
    endif
  endwhile
endfunction

" 剪贴板模块先于文件树加载，提供 OSC 52 复制与粘贴回退。
if !s:SourceModule('project.vim')
  call s:Warn('missing project.vim; copy the complete vim directory')
endif

if !s:SourceModule('clipboard.vim')
  command! VimCopyPath call <SID>Warn(
        \ 'missing clipboard.vim; copy the complete vim directory')
  command! VimCopyContent call <SID>Warn(
        \ 'missing clipboard.vim; copy the complete vim directory')
endif

" 文件树模块。
if !s:SourceModule('tree.vim')
  call s:Warn('missing tree.vim; copy the complete vim directory')
endif

" LSP 模块与其固定版本客户端一起部署，显式加载以保留插件隔离。
if !s:SourceModule('lsp.vim')
  command! VimLspStatus call <SID>Warn(
        \ 'missing lsp.vim; copy the complete vim directory')
  command! VimLspInfo VimLspStatus
endif

" 在各代码窗口的状态栏文件名后显示当前函数／类上下文。
if !s:SourceModule('context.vim')
  call s:Warn('missing context.vim; copy the complete vim directory')
endif

" buffer 栏与 buffer 管理模块。
if !exists('g:vimrc_lite_buffer_slogans')
  let g:vimrc_lite_buffer_slogans = [
        \ 'Per aspera ad astra.',
        \ 'Les années heureuses sont les années perdues, on attend une souffrance pour travailler.',
        \ 'Seize the day.',
        \ ]
endif
if !s:SourceModule('buffers.vim')
  call s:Warn('missing buffers.vim; copy the complete vim directory')
endif

" 编辑辅助模块：清空、去空白、注释切换。
if !s:SourceModule('edit.vim')
  call s:Warn('missing edit.vim; copy the complete vim directory')
endif

" 持久化行级 pin，复用项目状态目录。
if !s:SourceModule('pins.vim')
  call s:Warn('missing pins.vim; copy the complete vim directory')
endif

if !s:SourceModule('completion.vim')
  call s:Warn('missing completion.vim; copy the complete vim directory')
endif

" Lightweight structural text objects for supported programming languages.
if !s:SourceModule('textobjects.vim')
  call s:Warn('missing textobjects.vim; copy the complete vim directory')
endif

function! s:ToggleList(location) abort
  let info = a:location ? getloclist(0, {'winid': 0}) : getqflist({'winid': 0})
  execute a:location ? (info.winid ? 'lclose' : 'lopen') : (info.winid ? 'cclose' : 'copen')
endfunction

" 搜索模块与首页。
if !s:SourceModule('search.vim')
  command! VimFind call <SID>Warn(
        \ 'missing search.vim; copy the complete vim directory')
  command! VimSearch call <SID>Warn(
        \ 'missing search.vim; copy the complete vim directory')
endif

" 终端模块先于 Git 加载。
if !s:SourceModule('terminal.vim')
  command! -nargs=* VimTerminal call <SID>Warn(
        \ 'missing terminal.vim; copy the complete vim directory')
endif

if !s:SourceModule('git.vim')
  command! VimGit call <SID>Warn(
        \ 'missing git.vim; copy the complete vim directory')
endif

for s:module in ['tasks.vim', 'session.vim', 'tools.vim']
  if !s:SourceModule(s:module)
    call s:Warn('missing ' . s:module . '; copy the complete vim directory')
  endif
endfor

" 配置编辑入口与独立首页。
command! VimConfig execute 'edit ' . fnameescape(s:vimrc_path)
if !s:SourceModule('dashboard.vim')
  call s:Warn('missing dashboard.vim; copy the complete vim directory')
endif

" 文件保存、buffer 复制与标签页；buffer 栏及切换按键由 buffers.vim 提供。
" 禁用普通模式下的 q 宏录制按键。
nnoremap q <Nop>
nnoremap <silent> <C-s> :wall<CR>
inoremap <silent> <C-s> <C-o>:wall<CR>
xnoremap <silent> <C-s> <Esc>:wall<CR>gv
nnoremap <silent> <leader>w :wall<CR>
xnoremap <silent> <leader>w <Esc>:wall<CR>gv
nnoremap <silent> <leader>bP :VimCopyPath<CR>
nnoremap <silent> <leader>bC :VimCopyContent<CR>
nnoremap <silent> tn :tabnew<CR>
nnoremap <silent> tj :tabprevious<CR>
nnoremap <silent> tk :tabnext<CR>
nnoremap <silent> to :confirm tabonly<CR>
nnoremap <silent> <leader>aN :tab split<CR>
nnoremap <silent> <leader>an :$tabnew<CR>
nnoremap <silent> <leader>ah :-tabmove<CR>
nnoremap <silent> <leader>al :+tabmove<CR>
nnoremap <silent> <leader>ao :confirm tabonly<CR>

" 窗口跳转映射不递归展开，不会触发 buffers.vim 的 Ctrl-w 关闭操作。
for s:direction in ['h', 'j', 'k', 'l']
  execute 'nnoremap <silent> <C-' . s:direction . '> <C-w>' . s:direction
  execute 'nnoremap <silent> <A-' . s:direction . '> <C-w>' . s:direction
endfor
nnoremap <silent> <C-Up> :resize -2<CR>
nnoremap <silent> <C-Down> :resize +2<CR>
nnoremap <silent> <C-Left> :vertical resize -2<CR>
nnoremap <silent> <C-Right> :vertical resize +2<CR>
nnoremap <silent> <leader>v :vsplit<CR>
nnoremap <silent> <leader>q :call <SID>Quit()<CR>
xnoremap < <gv
xnoremap > >gv

" 搜索、结果列表、消息。
nnoremap <silent> <leader>ff :VimFind<CR>
nnoremap <silent> <leader>fp :VimSearch<CR>
nnoremap <silent> <leader>fr :VimRecent<CR>
nnoremap <silent> <leader>fw :VimSearchWord<CR>
xnoremap <silent> <leader>fw :<C-u>VimSearchSelection<CR>
nnoremap <silent> <leader>fh :nohlsearch<CR>
nnoremap <silent> <leader>pp :VimPinToggle<CR>
xnoremap <silent> <leader>pp :VimPinToggle<CR>
nnoremap <silent> <leader>pc :VimPinClear<CR>
nnoremap <silent> <leader>pf :VimPinClearFile<CR>
nnoremap <silent> <leader>pa :VimPinClearProject<CR>
" 重载时移除旧 pin 按键，保留用户为 ]j/[j 设置的其他映射。
for s:key in [']j', '[j']
  if maparg(s:key, 'n') =~# '\<VimPin\%(Next\|Prev\)\>'
    execute 'nunmap ' . s:key
  endif
endfor
nnoremap <silent> ]p :<C-u>execute v:count1 . 'VimPinNext'<CR>
nnoremap <silent> [p :<C-u>execute v:count1 . 'VimPinPrev'<CR>
nnoremap <silent> [q :cprevious<CR>
nnoremap <silent> ]q :cnext<CR>
nnoremap <silent> <leader>xQ :call <SID>ToggleList(0)<CR>
nnoremap <silent> <leader>xL :call <SID>ToggleList(1)<CR>
nnoremap <leader>nh :messages<CR>

nnoremap <silent> <leader>gg :VimGit<CR>
nnoremap <silent> <leader>; :VimTerminal<CR>
nnoremap <silent> <leader>tt :VimTerminalToggle<CR>
nnoremap <silent> <leader>rn :VimLspRename<CR>
nnoremap <silent> <leader>ca :VimLspCodeAction<CR>
xnoremap <silent> <leader>ca :<C-u>call VimLspSelection('action', visualmode())<CR>
nnoremap <silent> <leader>cf :VimLspFormat<CR>
xnoremap <silent> <leader>cf :<C-u>call VimLspSelection('format', visualmode())<CR>
nnoremap <silent> <leader>cs :VimLspSymbols<CR>
nnoremap <silent> <leader>cd :VimLspDiagnostics<CR>
nnoremap <silent> <leader>ce :VimLspDiagnosticDetails<CR>
nnoremap <silent> <leader>cl :VimLspDiagnosticList<CR>
nnoremap <silent> <leader>ci :VimLspInfo<CR>
nnoremap <silent> <leader>cD :VimLspDeclaration<CR>
nnoremap <silent> <leader>ct :VimLspTypeDefinition<CR>
nnoremap <silent> <leader>cm :VimLspImplementation<CR>
nnoremap <silent> <leader>cS :VimLspWorkspaceSymbols<CR>
nnoremap <silent> <leader>ck :VimLspSignature<CR>
nnoremap <silent> <leader>rt :VimTask<CR>
nnoremap <silent> <leader>rx :VimTaskStop<CR>
nnoremap <silent> <leader>rs :VimTaskStatus<CR>
nnoremap <silent> <leader>ro :VimTaskOutput<CR>
nnoremap <silent> <leader>ss :VimSessionSave<CR>
nnoremap <silent> <leader>sl :VimSessionLoad<CR>
nnoremap <silent> <leader>? :VimKeys<CR>
nnoremap <silent> <leader>ch :VimHealth<CR>

if has('terminal')
  tnoremap <Esc><Esc> <C-w>N
endif
