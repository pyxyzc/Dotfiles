" 固定版本客户端由本模块显式加载；配置只在本次 Vim 启动时读取一次。
if exists('s:initialized')
  " vimrc 重载会重建 runtimepath，但不能重新注册正在运行的服务器。
  if s:ready
    let &runtimepath .= ',' . escape(s:plugin, ',')
  endif
  finish
endif
let s:initialized = 1
let s:ready = 0
let s:reason = ''
let s:plugin = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/vendor/vim-lsp'
let s:servers = {
      \ 'pyright': {
      \   'cmd': deepcopy(get(g:, 'vimrc_lite_lsp_pyright_cmd',
      \         ['pyright-langserver', '--stdio'])),
      \   'filetypes': ['python'],
      \   'markers': ['pyrightconfig.json', 'pyproject.toml', 'setup.py',
      \         'setup.cfg', '.git'],
      \   'root': '', 'reason': '',
      \ },
      \ 'clangd': {
      \   'cmd': deepcopy(get(g:, 'vimrc_lite_lsp_clangd_cmd',
      \         ['clangd', '--background-index'])),
      \   'filetypes': ['c', 'cpp'],
      \   'markers': ['.clangd', 'compile_commands.json', 'CMakeLists.txt',
      \         'Makefile', '.git'],
      \   'root': '', 'reason': '',
      \ },
      \ }

function! s:Status() abort
  echom 'Vim LSP: ' . (s:ready ? 'enabled' : s:reason)
  for name in sort(keys(s:servers))
    let server = s:servers[name]
    let status = !empty(server.reason) ? server.reason
          \ : (s:ready ? lsp#get_server_status(name) : 'not loaded')
    echom name . ': ' . status
    echom '  command: ' . string(server.cmd)
    echom '  root: ' . (empty(server.root) ? '(not started)' : server.root)
  endfor
endfunction
command! VimLspStatus call <SID>Status()

if !get(g:, 'vimrc_lite_lsp', 1)
  let s:reason = 'disabled (g:vimrc_lite_lsp = 0)'
  finish
endif
let s:missing = []
for s:feature in ['job', 'channel', 'timers', 'lambda']
  if !has(s:feature)
    call add(s:missing, '+' . s:feature)
  endif
endfor
for s:func in ['json_encode', 'json_decode']
  if !exists('*' . s:func)
    call add(s:missing, s:func . '()')
  endif
endfor
if !empty(s:missing)
  let s:reason = 'missing Vim features: ' . join(s:missing, ', ')
  finish
endif
if !filereadable(s:plugin . '/plugin/lsp.vim') || !filereadable(s:plugin . '/autoload/lsp.vim')
  let s:reason = 'missing bundled vim-lsp: ' . s:plugin
  finish
endif

" 使用 Vimscript 客户端与原生手动补全，不依赖 Lua 或额外的界面插件。
let g:lsp_use_lua = 0
let g:lsp_use_native_client = 0
let g:lsp_auto_enable = 0
let g:lsp_async_completion = 0
let g:lsp_diagnostics_enabled = 0
let g:lsp_document_code_action_signs_enabled = 0
let g:lsp_document_highlight_enabled = 0
let g:lsp_signature_help_enabled = 0
let g:lsp_semantic_enabled = 0
let g:lsp_inlay_hints_enabled = 0
let g:lsp_fold_enabled = 0
let g:lsp_completion_documentation_enabled = 0
let g:lsp_untitled_buffer_enabled = 0
let g:lsp_preview_float = exists('*popup_create') && has('patch-8.1.1517')
      \ && get(g:, 'lsp_preview_float', 1)
let g:lsp_hover_ui = g:lsp_preview_float ? 'float' : 'preview'
let &runtimepath .= ',' . escape(s:plugin, ',')
execute 'source ' . fnameescape(s:plugin . '/plugin/lsp.vim')

function! s:ProjectRoot(name) abort
  let start = expand('%:p:h')
  let directory = start
  while 1
    for marker in s:servers[a:name].markers
      if isdirectory(directory . '/' . marker) || filereadable(directory . '/' . marker)
        return directory
      endif
    endfor
    let parent = fnamemodify(directory, ':h')
    if parent ==# directory
      return start
    endif
    let directory = parent
  endwhile
endfunction

function! s:ServerCommand(name, info) abort
  if &buftype !=# '' || empty(bufname('%'))
    return []
  endif
  if empty(s:servers[a:name].root)
    let s:servers[a:name].root = s:ProjectRoot(a:name)
  endif
  return copy(s:servers[a:name].cmd)
endfunction

function! s:RootUri(name, info) abort
  return lsp#utils#path_to_uri(s:servers[a:name].root)
endfunction

function! s:OnBufferEnabled() abort
  if &buftype !=# '' || empty(bufname('%'))
    return
  endif
  let servers = filter(lsp#get_allowed_servers(), 'lsp#is_server_running(v:val)')
  if empty(servers)
    return
  endif
  setlocal omnifunc=lsp#complete
  nmap <silent><buffer> gd <plug>(lsp-definition)
  nmap <silent><buffer> gr <plug>(lsp-references)
  nmap <silent><buffer> K <plug>(lsp-hover)
endfunction

for s:name in sort(keys(s:servers))
  let s:server = s:servers[s:name]
  if type(s:server.cmd) != type([]) || empty(s:server.cmd)
        \ || !empty(filter(copy(s:server.cmd), 'type(v:val) != type("")'))
    let s:server.reason = 'invalid command (expected a nonempty list of strings)'
  elseif !executable(s:server.cmd[0])
    let s:server.reason = 'missing executable: ' . s:server.cmd[0]
  else
    call lsp#register_server({'name': s:name, 'allowlist': s:server.filetypes,
          \ 'cmd': function('s:ServerCommand', [s:name]),
          \ 'root_uri': function('s:RootUri', [s:name])})
  endif
endfor
let s:ready = 1
augroup vimrc_lite_lsp
  autocmd!
  autocmd User lsp_buffer_enabled call s:OnBufferEnabled()
  autocmd VimEnter * call lsp#enable()
  " 上游预览用 :normal Ctrl-w p 返回原窗口；仅在该 buffer 避免触发 Ctrl-w 关闭。
  autocmd BufWinEnter LspHoverPreview nnoremap <silent><buffer> <C-w>p <C-w>p
augroup END
if v:vim_did_enter
  call lsp#enable()
endif
