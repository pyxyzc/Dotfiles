" 重载函数与界面设置，保留实例、文档及正在运行的进程。
let s:reloading = exists('s:initialized')
if !s:reloading
  let s:initialized = 1
  let s:ready = 0
  let s:reason = ''
  let s:progress = {}
  let s:file_status = {}
  let s:indicator_refresh = -1
  let s:instances = {}
  let s:roots = {}
  let s:instance_serial = 0
  let s:requests = {}
  let s:request_serial = 0
  let s:request_epochs = {}
  let s:document = {}
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
endif

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

" 状态面板始终查询打开它的文件；刷新时不能把面板自身当成目标 buffer。
function! s:BufferReason(buffer) abort
  if !bufexists(a:buffer)
    return '源文件已关闭'
  elseif !s:ready
    return s:reason
  elseif getbufvar(a:buffer, 'vimrc_lite_large_file', 0)
    return '大文件模式，已跳过 LSP'
  elseif getbufvar(a:buffer, '&buftype') !=# ''
    return '辅助窗口，不启用 LSP'
  elseif empty(bufname(a:buffer))
    return '未命名文件，不启用 LSP'
  endif
  return ''
endfunction

function! s:InfoLines(buffer) abort
  let reason = s:BufferReason(a:buffer)
  let allowed = empty(reason) ? lsp#get_allowed_servers(a:buffer) : []
  let active = filter(copy(allowed), 'lsp#is_server_running(v:val)')
  let registered = s:ready ? lsp#get_server_names() : []
  let names = sort(keys(s:servers))
  for name in sort(registered)
    if index(names, name) < 0
      call add(names, name)
    endif
  endfor
  " 当前文件生效的服务器优先显示，其余已配置或额外注册的服务器随后列出。
  let names = sort(copy(active)) + filter(names, 'index(active, v:val) < 0')
  let file = bufname(a:buffer)
  let lines = ['LSP 状态 / r 刷新 / q 或 Esc 关闭', '',
        \ '文件: ' . (empty(file) ? '[No Name]' : fnamemodify(file, ':p')),
        \ '文件类型: ' . getbufvar(a:buffer, '&filetype'),
        \ '客户端: ' . (s:ready ? '已加载 vim-lsp' : s:reason),
        \ '当前生效: ' . (!empty(reason) ? '无 — ' . reason
        \   : empty(active) ? '无（查看下方服务器原因）' : join(sort(active), ', ')),
        \ '诊断显示: ' . (s:ready && getbufvar(a:buffer, 'lsp_diagnostics_enabled',
        \   get(g:, 'vimrc_lite_lsp_diagnostics', 1)) ? '开启' : '关闭'),
        \ '待处理请求: ' . len(filter(values(copy(s:requests)),
        \   'v:val.buffer == a:buffer')),
        \ '']
  let providers = [['definition', '定义 gd'], ['references', '引用 gr'],
        \ ['hover', '文档 K'], ['completion', '补全 Ctrl-x Ctrl-o'],
        \ ['rename', '重命名'], ['code_action', '代码操作'],
        \ ['document_formatting', '全文格式化'],
        \ ['document_range_formatting', '选区格式化'], ['document_symbol', '符号列表'],
        \ ['declaration', '声明'], ['type_definition', '类型定义'],
        \ ['implementation', '实现'], ['workspace_symbol', '工作区符号'],
        \ ['signature_help', '签名帮助']]
  for name in names
    let info = index(registered, name) >= 0 ? lsp#get_server_info(name) : {}
    let server = get(s:servers, name, {})
    let running = s:ready && index(registered, name) >= 0 && lsp#is_server_running(name)
    let status = get(get(s:instances, name, {}), 'failed', 0) ? 'exited; use :VimLspStart'
          \ : get(get(s:instances, name, {}), 'stopped', 0) ? 'manually stopped'
          \ : !s:ready ? 'not loaded'
          \ : running ? lsp#get_server_status(name)
          \ : !empty(get(server, 'reason', '')) ? server.reason : lsp#get_server_status(name)
    let applies = index(active, name) >= 0
    let buffer_status = applies ? '生效'
          \ : !empty(reason) ? '未生效 — ' . reason
          \ : has_key(s:instances, name) && !empty(s:instances[name].root)
          \ && index(s:servers[name].filetypes, getbufvar(a:buffer, '&filetype')) >= 0
          \ && get(getbufvar(a:buffer, 'vimrc_lite_lsp_binding', {}), s:Kind(name), '') !=# name
          \ ? '未生效 — 其他项目'
          \ : index(allowed, name) < 0 && index(registered, name) >= 0
          \ ? '未生效 — 不匹配当前文件类型'
          \ : '未生效 — ' . status
    let Desired = get(server, 'cmd', get(info, 'cmd', get(info, 'tcp', '(unknown)')))
    let Command = running ? get(info, 'cmd', Desired) : Desired
    let executable = type(Command) == type([]) && !empty(Command)
          \ && type(Command[0]) == type('') ? exepath(Command[0]) : ''
    let root = get(server, 'root', '')
    if empty(root) && index(registered, name) >= 0
      let uri = lsp#get_server_root_uri(name)
      let root = empty(uri) ? '' : lsp#utils#uri_to_path(uri)
    endif
    let filetypes = get(server, 'filetypes', get(info, 'allowlist', get(info, 'whitelist', [])))
    let supported = []
    if running
      for provider in providers
        let Check = function('lsp#capabilities#has_' . provider[0] . '_provider')
        if Check(name)
          call add(supported, provider[1])
        endif
      endfor
    endif
    let lines += [name . ' [' . (applies ? 'ACTIVE' : running ? 'RUNNING' : 'INACTIVE') . ']',
          \ '  状态: ' . status,
          \ '  当前文件: ' . buffer_status,
          \ '  文件类型: ' . join(filetypes, ', '),
          \ '  命令: ' . string(Command),
          \ '  可执行文件: ' . (empty(executable) ? '(未找到或未解析)' : executable),
          \ '  项目根目录: ' . (empty(root) ? '(尚未启动)' : root),
          \ '  支持功能: ' . (!running ? '(服务器就绪后显示)' : empty(supported)
          \   ? '(无上述功能)' : join(supported, ' / '))]
    if running && string(Command) !=# string(Desired)
      let lines += ['  重启后命令: ' . string(Desired),
            \ '  配置检查: ' . (empty(get(server, 'reason', '')) ? '通过' : server.reason)]
    endif
    call add(lines, '')
  endfor
  return lines
endfunction

function! s:RefreshInfo() abort
  let view = winsaveview()
  let lines = s:InfoLines(b:vimrc_lite_lsp_info_source)
  setlocal modifiable
  silent %delete _
  call setline(1, lines)
  setlocal nomodifiable nomodified
  call winrestview(view)
endfunction

function! s:CloseInfo() abort
  let origin = b:vimrc_lite_lsp_info_origin
  if winnr('$') == 1
    enew
  else
    close
  endif
  call win_gotoid(origin)
endfunction

function! s:Info() abort
  if get(b:, 'vimrc_lite_lsp_info', 0)
    call s:RefreshInfo()
    return
  endif
  let source = bufnr('%')
  let origin = win_getid()
  let windows = filter(getwininfo(), 'v:val.tabnr == tabpagenr()
        \ && getbufvar(v:val.bufnr, "vimrc_lite_lsp_info", 0)')
  if !empty(windows)
    call win_gotoid(windows[0].winid)
  else
    if &columns >= 120
      botright vnew
      execute 'vertical resize ' . min([72, &columns / 2])
    else
      botright new
      execute 'resize ' . min([20, max([8, &lines / 2])])
    endif
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
    setlocal undolevels=-1 nonumber norelativenumber wrap linebreak nospell
    setlocal foldmethod=manual nofoldenable
    setlocal filetype=vimlspinfo
    let &l:statusline = ' LSP 状态 %= r 刷新 / q 关闭 '
    let b:vimrc_lite_lsp_info = 1
    nnoremap <silent><buffer> r :call <SID>RefreshInfo()<CR>
    nnoremap <silent><buffer> q :call <SID>CloseInfo()<CR>
    nnoremap <silent><buffer> <Esc> :call <SID>CloseInfo()<CR>
    syntax match VimLspInfoTitle /^LSP 状态.*/
    syntax match VimLspInfoField /^\s*[^:]*:/
    syntax match VimLspInfoActive /\[ACTIVE\]/
    syntax match VimLspInfoRunning /\[RUNNING\]/
    syntax match VimLspInfoInactive /\[INACTIVE\]/
    highlight default link VimLspInfoTitle Title
    highlight default link VimLspInfoField Comment
    highlight default link VimLspInfoActive String
    highlight default link VimLspInfoRunning Type
    highlight default link VimLspInfoInactive WarningMsg
  endif
  let b:vimrc_lite_lsp_info_source = source
  let b:vimrc_lite_lsp_info_origin = origin
  call s:RefreshInfo()
  call winrestview({'lnum': 1, 'col': 0, 'topline': 1, 'leftcol': 0})
endfunction
command! VimLspInfo call <SID>Info()

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim LSP: ' . a:message
  echohl None
endfunction

function! s:Action(action, range, first, last) abort
  if !s:ready
    call s:Warn('language service unavailable; see :VimLspInfo')
    return
  endif
  if a:action ==# 'symbols'
    call s:Symbols(0, '')
  elseif a:action ==# 'rename'
    call s:Rename()
  elseif index(['definition', 'references', 'declaration', 'typeDefinition',
        \ 'implementation'], a:action) >= 0
    call s:Navigate(a:action)
  elseif a:action ==# 'hover'
    call s:Hover()
  elseif a:action ==# 'signature'
    call s:Signature()
  elseif a:action ==# 'diagnostic_details'
    call s:DiagnosticDetails()
  elseif a:action ==# 'diagnostic_list'
    call s:DiagnosticList(a:range)
  else
    let selection = a:range ? s:LineRange(a:first, a:last) : {}
    call s:EditOperation(a:action, selection)
  endif
endfunction

function! s:Diagnostics() abort
  if !s:ready
    call s:Warn('language service unavailable; see :VimLspStatus')
    return
  endif
  if lsp#internal#diagnostics#state#_is_enabled_for_buffer(bufnr('%'))
    call lsp#internal#diagnostics#state#_disable_for_buffer(bufnr('%'))
  else
    call lsp#internal#diagnostics#state#_enable_for_buffer(bufnr('%'))
  endif
  echom 'Vim LSP: buffer diagnostics '
        \ . (lsp#internal#diagnostics#state#_is_enabled_for_buffer(bufnr('%')) ? 'on' : 'off')
endfunction

command! VimLspRename call <SID>Action('rename', 0, 0, 0)
command! -range VimLspCodeAction call <SID>Action('action', <range>, <line1>, <line2>)
command! -range VimLspFormat call <SID>Action('format', <range>, <line1>, <line2>)
command! VimLspSymbols call <SID>Action('symbols', 0, 0, 0)
command! VimLspDiagnostics call <SID>Diagnostics()
command! VimLspDefinition call <SID>Action('definition', 0, 0, 0)
command! VimLspReferences call <SID>Action('references', 0, 0, 0)
command! VimLspDeclaration call <SID>Action('declaration', 0, 0, 0)
command! VimLspTypeDefinition call <SID>Action('typeDefinition', 0, 0, 0)
command! VimLspImplementation call <SID>Action('implementation', 0, 0, 0)
command! VimLspHover call <SID>Action('hover', 0, 0, 0)
command! VimLspSignature call <SID>Action('signature', 0, 0, 0)
command! VimLspDiagnosticDetails call <SID>Action('diagnostic_details', 0, 0, 0)
command! -bang VimLspDiagnosticList call <SID>Action('diagnostic_list', <bang>0, 0, 0)

function! s:WorkspaceAction(query) abort
  if !s:ready
    call s:Warn('language service unavailable; see :VimLspInfo')
    return
  endif
  call s:Symbols(1, a:query)
endfunction
command! -nargs=* VimLspWorkspaceSymbols call <SID>WorkspaceAction(<q-args>)

function! s:ProjectAction(action) abort
  if !s:ready
    call s:Warn('language service unavailable; see :VimLspInfo')
    return
  endif
  call s:Control(a:action)
endfunction
command! VimLspStart call <SID>ProjectAction('start')
command! VimLspStop call <SID>ProjectAction('stop')
command! VimLspRestart call <SID>ProjectAction('restart')

function! VimLspSelection(action, mode) abort
  if !s:ready
    call s:Warn('language service unavailable; see :VimLspInfo')
    return
  endif
  call s:Selection(a:action, a:mode)
endfunction

function! s:ServerReady(name, buffer) abort
  if !lsp#is_server_running(a:name) || !empty(get(s:progress, a:name, {}))
    return 0
  endif
  let uri = lsp#utils#get_buffer_uri(a:buffer)
  let activity = get(get(s:file_status, a:name, {}), uri, '')
  return empty(activity) || activity ==# 'idle'
endfunction

function! s:BufferIndicators(buffer) abort
  if !s:ready || getbufvar(a:buffer, '&buftype') !=# ''
        \ || getbufvar(a:buffer, 'vimrc_lite_large_file', 0) || empty(bufname(a:buffer))
    return []
  endif
  let names = filter(lsp#get_allowed_servers(a:buffer), 's:ServerReady(v:val, a:buffer)')
  return uniq(sort(map(names, 's:Kind(v:val)')))
endfunction

" 状态栏只读取缓存；不在绘制时启动服务器、扫描文件或发出 LSP 请求。
function! VimLspIndicator() abort
  return join(get(b:, 'vimrc_lite_lsp_indicator', []), ', ')
endfunction

function! VimLspStatusLabel() abort
  let parts = empty(&filetype) ? [] : ['[lang: ' . &filetype . ']']
  let servers = VimLspIndicator()
  if !empty(servers)
    call add(parts, '[lsp: ' . servers . ']')
  endif
  return join(parts, ' ')
endfunction

function! s:StopIndicatorRefresh() abort
  if s:indicator_refresh != -1
    call timer_stop(s:indicator_refresh)
  endif
  let s:indicator_refresh = -1
endfunction

function! s:RefreshIndicators(...) abort
  if a:0
    let s:indicator_refresh = -1
  endif
  if s:ready
    for name in uniq(sort(keys(s:progress) + keys(s:file_status)))
      if index(['running', 'starting'], lsp#get_server_status(name)) < 0
        if has_key(s:progress, name)
          call remove(s:progress, name)
        endif
        if has_key(s:file_status, name)
          call remove(s:file_status, name)
        endif
      endif
    endfor
  endif
  let seen = {}
  for window in getwininfo()
    if window.tabnr != tabpagenr() || has_key(seen, window.bufnr)
      continue
    endif
    let seen[window.bufnr] = 1
    let indicators = s:BufferIndicators(window.bufnr)
    call setbufvar(window.bufnr, 'vimrc_lite_lsp_indicator', indicators)
  endfor
  redrawstatus
endfunction

function! s:QueueIndicators() abort
  if !has('timers')
    call s:RefreshIndicators()
    return
  endif
  if s:indicator_refresh != -1
    call timer_stop(s:indicator_refresh)
  endif
  let s:indicator_refresh = timer_start(0, function('s:RefreshIndicators'))
endfunction

function! s:IndicatorNotification(name, data) abort
  let response = get(a:data, 'response', {})
  let method = get(response, 'method', '')
  let params = get(response, 'params', {})
  if method ==# '$/progress' && type(params) == type({}) && has_key(params, 'token')
    let value = get(params, 'value', {})
    if type(value) != type({}) || index(['begin', 'report', 'end'], get(value, 'kind', '')) < 0
      return
    endif
    if !has_key(s:progress, a:name)
      let s:progress[a:name] = {}
    endif
    let token = string(params.token)
    if value.kind ==# 'end'
      if has_key(s:progress[a:name], token)
        call remove(s:progress[a:name], token)
      endif
    else
      let s:progress[a:name][token] = 1
    endif
  elseif s:Kind(a:name) ==# 'pyright' && method =~# '^pyright/\%(begin\|report\|end\)Progress$'
    if !has_key(s:progress, a:name)
      let s:progress[a:name] = {}
    endif
    if method ==# 'pyright/endProgress'
      if has_key(s:progress[a:name], 'legacy')
        call remove(s:progress[a:name], 'legacy')
      endif
    else
      let s:progress[a:name].legacy = 1
    endif
  elseif s:Kind(a:name) ==# 'clangd' && method ==# 'textDocument/clangd.fileStatus'
        \ && type(params) == type({}) && has_key(params, 'uri') && has_key(params, 'state')
    if !has_key(s:file_status, a:name)
      let s:file_status[a:name] = {}
    endif
    let s:file_status[a:name][params.uri] = params.state
  elseif get(get(a:data, 'request', {}), 'method', '') !=# 'initialize'
    return
  endif
  call s:QueueIndicators()
endfunction

augroup vimrc_lite_lsp_indicator
  autocmd!
  autocmd BufEnter,BufWinEnter,FileType,TabEnter,VimEnter * call s:QueueIndicators()
  autocmd User lsp_server_init,lsp_server_exit,lsp_buffer_enabled call s:QueueIndicators()
  autocmd VimLeavePre * call s:StopIndicatorRefresh()
augroup END
call s:QueueIndicators()

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
let g:lsp_diagnostics_enabled = 1
let g:lsp_diagnostics_signs_enabled = 1
let g:lsp_diagnostics_highlights_enabled = 1
let g:lsp_diagnostics_virtual_text_enabled = 0
let g:lsp_diagnostics_float_cursor = 0
let g:lsp_diagnostics_echo_cursor = 0
let g:lsp_diagnostics_signs_insert_mode_enabled = 0
let g:lsp_diagnostics_highlights_insert_mode_enabled = 0
let g:lsp_diagnostics_signs_delay = 80
let g:lsp_diagnostics_highlights_delay = 80
highlight default LspErrorHighlight term=underline cterm=underline gui=undercurl
highlight default LspWarningHighlight term=underline cterm=underline gui=undercurl
highlight default LspInformationHighlight term=underline cterm=underline gui=underline
highlight default LspHintHighlight term=underline cterm=underline gui=underline
let g:lsp_document_code_action_signs_enabled = 0
let g:lsp_document_highlight_enabled = 0
let g:lsp_signature_help_enabled = 0
let g:lsp_semantic_enabled = 0
let g:lsp_inlay_hints_enabled = 0
let g:lsp_fold_enabled = 0
let g:lsp_completion_documentation_enabled = 1
let g:lsp_completion_documentation_delay = 80
" 随附客户端为无 user_data 的旧 Vim 提供候选标记；仍尊重用户显式关闭。
let g:lsp_text_edit_enabled = get(g:, 'lsp_text_edit_enabled', 1)
let g:lsp_untitled_buffer_enabled = 0
let g:lsp_preview_float = exists('*popup_create') && has('patch-8.1.1517')
      \ && get(g:, 'lsp_preview_float', 1)
let g:lsp_hover_ui = g:lsp_preview_float ? 'float' : 'preview'
let &runtimepath .= ',' . escape(s:plugin, ',')
execute 'source ' . fnameescape(s:plugin . '/plugin/lsp.vim')

function! s:CancelRequest(context, ...) abort
  if !a:0 || !a:1
    let a:context.cancelled = 1
  endif
  if has_key(a:context, 'timer')
    call timer_stop(a:context.timer)
  endif
  for request in get(a:context, 'handles', [])
    call lsp#cancel_request(request.ctx)
    if has_key(request, 'dispose')
      call request.dispose()
    endif
  endfor
  let a:context.handles = []
  if get(get(s:requests, a:context.key, {}), 'token', -1) == a:context.token
    call remove(s:requests, a:context.key)
  endif
endfunction

function! s:Context(operation, interactive) abort
  let key = bufnr('%') . ':' . a:operation
  if has_key(s:requests, key)
    call s:CancelRequest(s:requests[key])
  endif
  let s:request_serial += 1
  let s:request_epochs[key] = s:request_serial
  return {'key': key, 'token': s:request_serial, 'buffer': bufnr('%'),
        \ 'uri': lsp#utils#get_buffer_uri(), 'window': win_getid(), 'tab': tabpagenr(),
        \ 'tick': b:changedtick, 'position': lsp#get_position(), 'view': winsaveview(),
        \ 'bytepos': getpos('.'), 'word': expand('<cword>'), 'interactive': a:interactive,
        \ 'handles': []}
endfunction

function! s:ValidContext(context) abort
  if get(a:context, 'cancelled', 0)
        \ || get(s:request_epochs, a:context.key, -1) != a:context.token
        \ || !bufexists(a:context.buffer) || !bufloaded(a:context.buffer)
        \ || getbufvar(a:context.buffer, 'changedtick') != a:context.tick
        \ || lsp#utils#get_buffer_uri(a:context.buffer) !=# a:context.uri
        \ || tabpagenr() != a:context.tab
    return 0
  endif
  let windows = getwininfo(a:context.window)
  if empty(windows) || windows[0].bufnr != a:context.buffer
    return 0
  endif
  if has_key(a:context, 'server')
    if !lsp#is_server_running(a:context.server)
          \ || index(lsp#get_allowed_servers(a:context.buffer), a:context.server) < 0
          \ || get(get(s:instances, a:context.server, {}), 'generation', 0)
          \ != a:context.generation
      return 0
    endif
  endif
  return !a:context.interactive || (win_getid() == a:context.window
        \ && getpos('.') ==# a:context.bytepos)
endfunction

function! s:RequestTimeout(context, timer) abort
  if s:ValidContext(a:context)
    call s:Warn('request timed out: ' . a:context.method)
  endif
  call s:CancelRequest(a:context)
endfunction

function! s:RequestResult(context, Handler, data) abort
  let valid = s:ValidContext(a:context)
  " 完成的响应无需再发送 $/cancelRequest。
  let a:context.handles = []
  call s:CancelRequest(a:context, 1)
  if !valid
    return
  endif
  let response = get(a:data, 'response', {})
  if has_key(response, 'error')
    call s:Warn(get(response.error, 'message', 'language server request failed'))
    return
  endif
  try
    call a:Handler(a:context, get(response, 'result', v:null))
  catch
    call s:Warn(v:exception)
  endtry
endfunction

function! s:Request(context, method, params, Handler, ...) abort
  if !s:ValidContext(a:context)
    return
  endif
  let server = a:0 ? a:1 : a:context.server
  let a:context.server = server
  let a:context.generation = get(get(s:instances, server, {}), 'generation', 0)
  let a:context.method = a:method
  let a:context.handles = []
  let s:requests[a:context.key] = a:context
  let a:context.timer = timer_start(max([1,
        \ get(g:, 'vimrc_lite_lsp_request_timeout_ms', 10000)]),
        \ function('s:RequestTimeout', [a:context]))
  let request = lsp#request_with_context(server,
        \ {'method': a:method, 'params': a:params, 'bufnr': a:context.buffer})
  call add(a:context.handles, request)
  let request.dispose = lsp#callbag#pipe(request.callbag,
        \ lsp#callbag#subscribe({'next': function('s:RequestResult', [a:context, a:Handler]),
        \ 'error': function('s:RequestResult', [a:context, a:Handler])}))
endfunction

function! s:OperationServer(provider) abort
  if !s:ready || !empty(s:BufferReason(bufnr('%')))
    call s:Warn('language service unavailable for this buffer; see :VimLspInfo')
    return ''
  endif
  let servers = sort(filter(lsp#get_allowed_servers(), 'lsp#is_server_running(v:val)'))
  let Check = function('lsp#capabilities#has_' . a:provider . '_provider')
  let servers = filter(servers, 'Check(v:val)')
  if empty(servers)
    call s:Warn('server is not ready or does not support ' . a:provider)
    return ''
  endif
  " 优先使用本配置绑定的实例，再考虑用户额外注册的服务器。
  let owned = filter(copy(servers), 'has_key(s:instances, v:val)')
  return empty(owned) ? servers[0] : owned[0]
endfunction

function! s:CancelObsoleteRequests() abort
  for context in values(copy(s:requests))
    if !s:ValidContext(context)
      call s:CancelRequest(context)
    endif
  endfor
endfunction

function! s:EditContext(operation) abort
  let context = s:Context(a:operation, 0)
  let context.document_ticks = {}
  for buffer in getbufinfo({'bufloaded': 1})
    if getbufvar(buffer.bufnr, '&buftype') ==# '' && !empty(buffer.name)
      let context.document_ticks[lsp#utils#get_buffer_uri(buffer.bufnr)] = buffer.changedtick
    endif
  endfor
  return context
endfunction

function! s:ApplyEdit(context, edit) abort
  if !s:ValidContext(a:context) || type(a:edit) != type({})
    return 0
  endif
  let uris = has_key(a:edit, 'documentChanges')
        \ ? map(copy(a:edit.documentChanges), 'get(get(v:val, "textDocument", {}), "uri", "")')
        \ : keys(get(a:edit, 'changes', {}))
  for uri in uris
    if has_key(a:context.document_ticks, uri)
      let buffer = bufnr(lsp#utils#uri_to_path(uri))
      if !bufloaded(buffer) || getbufvar(buffer, 'changedtick') != a:context.document_ticks[uri]
        call s:Warn('edit target changed while the request was pending')
        return 0
      endif
    endif
  endfor
  let summary = lsp#utils#workspace_edit#apply_workspace_edit(a:edit, a:context.server)
  " 后续 executeCommand 使用修改后的上下文；仍限定原窗口和实例。
  let a:context.tick = getbufvar(a:context.buffer, 'changedtick')
  echom printf('Vim LSP: %d edits in %d files', summary.edits, summary.files)
  return 1
endfunction

function! s:EditResult(context, result) abort
  if type(a:result) == type({})
    call s:ApplyEdit(a:context, a:result)
  elseif type(a:result) == type([])
    call s:ApplyEdit(a:context, {'changes': {a:context.uri: a:result}})
  else
    echom 'Vim LSP: no edits'
  endif
endfunction

function! s:RenamePrompt(context, placeholder, ...) abort
  if !s:ValidContext(a:context)
    return
  endif
  try
    let name = input('new name: ', a:placeholder)
  catch /^Vim:Interrupt$/
    return
  endtry
  if empty(name) || name ==# a:placeholder || !s:ValidContext(a:context)
    return
  endif
  call s:Request(a:context, 'textDocument/rename',
        \ {'textDocument': {'uri': a:context.uri},
        \ 'position': a:context.position, 'newName': name}, function('s:EditResult'))
endfunction

function! s:PrepareRenameResult(context, result) abort
  if type(a:result) != type({}) || empty(a:result)
    call s:Warn('this symbol cannot be renamed')
    return
  endif
  let placeholder = get(a:result, 'placeholder', a:context.word)
  let range = has_key(a:result, 'range') ? a:result.range : a:result
  if has_key(range, 'start') && !has_key(a:result, 'placeholder')
    let lines = getbufline(a:context.buffer, range.start.line + 1, range.end.line + 1)
    if len(lines) == 1
      let placeholder = lsp#utils#utf16#strpart(lines[0], range.start.character,
            \ range.end.character - range.start.character)
    endif
  endif
  call timer_start(1, function('s:RenamePrompt', [a:context, placeholder]))
endfunction

function! s:Rename() abort
  let server = s:OperationServer('rename')
  if empty(server)
    return
  endif
  let context = s:EditContext('rename')
  let context.server = server
  let context.generation = get(get(s:instances, server, {}), 'generation', 0)
  if lsp#capabilities#has_rename_prepare_provider(server)
    call s:Request(context, 'textDocument/prepareRename',
          \ {'textDocument': {'uri': context.uri}, 'position': context.position},
          \ function('s:PrepareRenameResult'))
  else
    call s:RenamePrompt(context, context.word)
  endif
endfunction

function! s:LineRange(first, last) abort
  return {'start': {'line': a:first - 1, 'character': 0},
        \ 'end': a:last < line('$') ? {'line': a:last, 'character': 0}
        \ : {'line': a:last - 1, 'character': lsp#utils#utf16#length(getline(a:last))}}
endfunction

function! s:Selection(action, mode) abort
  if a:mode ==# "\<C-v>"
    call s:Warn('block selections are not supported; use a character or line selection')
    return
  endif
  let first = getpos("'<")[1:2]
  let last = getpos("'>")[1:2]
  if a:mode ==# 'V'
    let range = s:LineRange(first[0], last[0])
  else
    let endcol = last[1]
    if &selection !=# 'exclusive'
      let endcol += strlen(matchstr(strpart(getline(last[0]), endcol - 1), '^.'))
    endif
    let range = {'start': lsp#utils#position#vim_to_lsp('%', first),
          \ 'end': lsp#utils#position#vim_to_lsp('%', [last[0], endcol])}
  endif
  call s:EditOperation(a:action, range)
endfunction

function! s:ExecuteResult(context, result) abort
  echom 'Vim LSP: command completed'
endfunction

function! s:ApplyCodeAction(context, action) abort
  if !s:ValidContext(a:context)
    return
  endif
  if has_key(a:action, 'disabled')
    call s:Warn(get(a:action.disabled, 'reason', 'this action is disabled'))
    return
  endif
  if has_key(a:action, 'edit') && !s:ApplyEdit(a:context, a:action.edit)
    return
  endif
  let command = get(a:action, 'command', {})
  if type(command) == type('')
    let command = {'command': command, 'arguments': get(a:action, 'arguments', [])}
  endif
  if !empty(command)
    call s:Request(a:context, 'workspace/executeCommand', command, function('s:ExecuteResult'))
  endif
endfunction

function! s:CodeActionResolved(context, result) abort
  if type(a:result) == type({})
    call s:ApplyCodeAction(a:context, a:result)
  endif
endfunction

function! s:ChooseCodeAction(context, actions, popup, choice) abort
  if a:choice <= 0 || a:choice > len(a:actions) || !s:ValidContext(a:context)
    return
  endif
  let action = a:actions[a:choice - 1]
  let capability = get(lsp#get_server_capabilities(a:context.server), 'codeActionProvider', {})
  if !has_key(action, 'disabled') && !has_key(action, 'edit')
        \ && type(get(action, 'command', {})) != type('')
        \ && type(capability) == type({}) && get(capability, 'resolveProvider', 0)
    call s:Request(a:context, 'codeAction/resolve', action, function('s:CodeActionResolved'))
  else
    try
      call s:ApplyCodeAction(a:context, action)
    catch
      call s:Warn(v:exception)
    endtry
  endif
endfunction

function! s:QuickpickCodeAction(context, data, event) abort
  call lsp#internal#ui#quickpick#close()
  if !empty(a:data.items)
    call s:ChooseCodeAction(a:context, [a:data.items[0].item], 0, 1)
  endif
endfunction

function! s:CodeActionResult(context, result) abort
  if type(a:result) != type([]) || empty(a:result)
    echom 'Vim LSP: no code actions'
    return
  endif
  let actions = copy(a:result)
  call sort(actions, {first, second -> get(second, 'isPreferred', 0)
        \ - get(first, 'isPreferred', 0)})
  let labels = map(copy(actions), 'get(v:val, "isPreferred", 0) ? "★ " . v:val.title
        \ : v:val.title')
  for index in range(len(actions))
    if has_key(actions[index], 'disabled')
      let labels[index] .= ' [disabled: ' . get(actions[index].disabled, 'reason', '') . ']'
    endif
  endfor
  if exists('*popup_menu') && g:lsp_preview_float
    call popup_menu(labels, {'callback': function('s:ChooseCodeAction', [a:context, actions])})
  else
    let items = []
    for index in range(len(actions))
      call add(items, {'title': labels[index], 'item': actions[index]})
    endfor
    call lsp#internal#ui#quickpick#open({'items': items, 'key': 'title',
          \ 'on_accept': function('s:QuickpickCodeAction', [a:context])})
  endif
endfunction

function! s:EditOperation(action, selection) abort
  let ranged = !empty(a:selection)
  let provider = a:action ==# 'action' ? 'code_action'
        \ : ranged ? 'document_range_formatting' : 'document_formatting'
  let server = s:OperationServer(provider)
  if empty(server)
    return
  endif
  let context = s:EditContext(a:action)
  let params = {'textDocument': {'uri': context.uri}}
  if a:action ==# 'action'
    let params.range = ranged ? a:selection
          \ : {'start': context.position, 'end': context.position}
    let diagnostics = []
    for item in s:DiagnosticItems(0)
      let range = item.user_data.range
      if range.start.line <= params.range.end.line && range.end.line >= params.range.start.line
        call add(diagnostics, item.user_data)
      endif
    endfor
    let params.context = {'diagnostics': diagnostics, 'triggerKind': 1}
    call s:Request(context, 'textDocument/codeAction', params,
          \ function('s:CodeActionResult'), server)
  else
    let params.options = {'tabSize': &l:shiftwidth > 0 ? &l:shiftwidth : &l:tabstop,
          \ 'insertSpaces': &l:expandtab ? v:true : v:false}
    if ranged
      let params.range = a:selection
    endif
    call s:Request(context, ranged ? 'textDocument/rangeFormatting' : 'textDocument/formatting',
          \ params, function('s:EditResult'), server)
  endif
endfunction

function! s:LocationOrder(first, second) abort
  let first = resolve(fnamemodify(
        \ get(a:first, 'filename', bufname(get(a:first, 'bufnr', 0))), ':p'))
  let second = resolve(fnamemodify(
        \ get(a:second, 'filename', bufname(get(a:second, 'bufnr', 0))), ':p'))
  return first !=# second ? (first ># second ? 1 : -1)
        \ : a:first.lnum != a:second.lnum ? a:first.lnum - a:second.lnum
        \ : get(a:first, 'col', 1) - get(a:second, 'col', 1)
endfunction

function! s:LocationsResult(context, result) abort
  let items = []
  let seen = {}
  for item in lsp#utils#location#_lsp_to_vim_list(a:result)
    let key = string([resolve(item.filename), item.lnum, item.col,
          \ get(item, 'end_lnum', 0), get(item, 'end_col', 0)])
    if !has_key(seen, key)
      let seen[key] = 1
      call add(items, item)
    endif
  endfor
  call sort(items, function('s:LocationOrder'))
  if empty(items)
    echom 'Vim LSP: no ' . a:context.operation . ' found'
    return
  endif
  if len(items) == 1 && index(['references', 'implementation'], a:context.operation) < 0
    call lsp#utils#tagstack#_update()
    normal! m'
    let item = items[0]
    let item.bufnr = bufnr(item.filename)
    if item.bufnr < 0
      execute 'silent badd ' . fnameescape(item.filename)
      let item.bufnr = bufnr(item.filename)
    endif
    let item.valid = 1
    call s:ShowReference(item)
  else
    call s:OpenReferences(a:context, items, a:context.operation)
  endif
endfunction

function! s:Navigate(operation) abort
  let providers = {'definition': 'definition', 'declaration': 'declaration',
        \ 'typeDefinition': 'type_definition', 'implementation': 'implementation',
        \ 'references': 'references'}
  let server = s:OperationServer(providers[a:operation])
  if empty(server)
    return
  endif
  let context = s:Context('navigate', 1)
  let context.operation = a:operation
  let params = {'textDocument': {'uri': context.uri}, 'position': context.position}
  if a:operation ==# 'references'
    let params.context = {'includeDeclaration': v:true}
  endif
  call s:Request(context, 'textDocument/' . a:operation, params,
        \ function('s:LocationsResult'), server)
endfunction

function! s:MarkupLines(contents) abort
  if type(a:contents) == type([])
    let lines = []
    for item in a:contents
      let lines += s:MarkupLines(item) + ['']
    endfor
    return lines
  endif
  let value = type(a:contents) == type({}) ? get(a:contents, 'value', '') : a:contents
  if type(value) != type('')
    return []
  endif
  let lines = split(value, "\n", 1)
  if type(a:contents) == type({}) && has_key(a:contents, 'language')
    return ['```' . a:contents.language] + lines + ['```']
  endif
  return lines
endfunction

function! s:DocumentWindow() abort
  let popup = get(s:document, 'popup', 0)
  if popup > 0 && !empty(popup_getpos(popup))
    return popup
  endif
  let window = get(s:document, 'window', 0)
  return window > 0 && !empty(getwininfo(window)) ? window : 0
endfunction

function! s:CloseDocument(return_to_source) abort
  let document = s:document
  let origin = get(document, 'origin', {})
  " 先清理状态，避免关闭窗口触发的 autocmd 再次关闭同一个文档。
  let s:document = {}
  if get(document, 'popup', 0) > 0
    call popup_close(document.popup)
  endif
  call s:RestoreDiagnosticMouse(document)
  let window = get(document, 'window', 0)
  if window > 0 && !empty(getwininfo(window))
    let current = win_getid()
    call win_gotoid(window)
    close
    call win_gotoid(current)
  endif
  if a:return_to_source && !empty(origin) && win_gotoid(origin.window)
    call winrestview(origin.view)
  endif
endfunction

function! s:ShowDocument(context, lines, focus, ...) abort
  if empty(a:lines)
    echom 'Vim LSP: no documentation found'
    return
  endif
  call s:CloseDocument(0)
  let s:document = {'origin': a:context, 'lines': a:lines, 'window': 0, 'popup': 0}
  if g:lsp_preview_float && !a:focus && (!a:0 || a:1)
    let s:document.popup = popup_create(a:lines, {'pos': 'botleft', 'line': 'cursor+1',
          \ 'col': 'cursor', 'maxwidth': min([80, max([20, &columns - 4])]),
          \ 'maxheight': max([1, &lines / 3]), 'padding': [0, 1, 0, 1],
          \ 'border': [1, 1, 1, 1], 'moved': 'any', 'mapping': 0})
    return
  endif
  noautocmd keepalt botright new
  execute 'resize ' . min([max([3, len(a:lines)]), max([3, &lines / 3])])
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
  setlocal nonumber norelativenumber wrap linebreak nospell foldmethod=manual nofoldenable
  setlocal filetype=markdown
  if !a:focus
    setlocal previewwindow
  endif
  silent file LspHoverPreview
  call setline(1, a:lines)
  setlocal nomodifiable nomodified
  nnoremap <silent><buffer> q :call <SID>CloseDocument(1)<CR>
  nnoremap <silent><buffer> <Esc> :call <SID>CloseDocument(1)<CR>
  nnoremap <silent><buffer> <C-w>p <C-w>p
  let s:document.window = win_getid()
  if !a:focus
    call win_gotoid(a:context.window)
  endif
endfunction

function! s:HoverResult(context, result) abort
  if type(a:result) != type({})
    echom 'Vim LSP: no documentation found'
    return
  endif
  call s:ShowDocument(a:context, s:MarkupLines(get(a:result, 'contents', '')), 0)
endfunction

function! s:Hover() abort
  if s:DocumentWindow() > 0
        \ && s:ValidContext(s:document.origin)
        \ && get(s:document.origin, 'buffer', -1) == bufnr('%')
        \ && get(s:document.origin, 'window', -1) == win_getid()
        \ && get(s:document.origin, 'tick', -1) == b:changedtick
        \ && get(s:document.origin, 'key', '') ==# bufnr('%') . ':hover'
        \ && get(s:document.origin, 'bytepos', []) ==# getpos('.')
    let origin = s:document.origin
    let lines = s:document.lines
    call s:ShowDocument(origin, lines, 1)
    return
  endif
  let server = s:OperationServer('hover')
  if !empty(server)
    let context = s:Context('hover', 1)
    call s:Request(context, 'textDocument/hover',
          \ {'textDocument': {'uri': context.uri}, 'position': context.position},
          \ function('s:HoverResult'), server)
  endif
endfunction

function! s:CloseMovedDocument() abort
  if empty(s:document) || get(s:document, 'window', 0) == win_getid()
    return
  endif
  let origin = s:document.origin
  if win_getid() != origin.window || getpos('.') !=# origin.bytepos
        \ || bufnr('%') != origin.buffer || b:changedtick != origin.tick
    call s:CloseDocument(0)
  elseif get(s:document, 'kind', '') ==# 'diagnostic'
    let view = winsaveview()
    for key in ['topline', 'leftcol', 'skipcol']
      if get(view, key, 0) != get(origin.view, key, 0)
        call s:CloseDocument(0)
        return
      endif
    endfor
  endif
endfunction

function! s:SignatureResult(context, result) abort
  let signatures = type(a:result) == type({}) ? get(a:result, 'signatures', []) : []
  if empty(signatures)
    echom 'Vim LSP: no signature found'
    return
  endif
  let lines = []
  for index in range(len(signatures))
    let signature = signatures[index]
    call add(lines, (index == get(a:result, 'activeSignature', 0) ? '> ' : '  ')
          \ . signature.label)
    let parameter = get(signature, 'activeParameter', get(a:result, 'activeParameter', 0))
    let parameters = get(signature, 'parameters', [])
    if parameter < len(parameters)
      let label = parameters[parameter].label
      if type(label) == type([])
        let label = lsp#utils#utf16#strpart(signature.label, label[0], label[1] - label[0])
      endif
      call add(lines, '参数: ' . label)
    endif
    let lines += s:MarkupLines(get(signature, 'documentation', '')) + ['']
  endfor
  call s:ShowDocument(a:context, lines, 0)
endfunction

function! s:Signature() abort
  let server = s:OperationServer('signature_help')
  if !empty(server)
    let context = s:Context('signature', 1)
    call s:Request(context, 'textDocument/signatureHelp',
          \ {'textDocument': {'uri': context.uri}, 'position': context.position},
          \ function('s:SignatureResult'), server)
  endif
endfunction

function! s:SymbolItems(context, symbols, depth) abort
  let items = []
  for symbol in a:symbols
    let location = get(symbol, 'location', {'uri': a:context.uri,
          \ 'range': get(symbol, 'selectionRange', get(symbol, 'range', {}))})
    if !has_key(location, 'range')
      continue
    endif
    let converted = lsp#utils#location#_lsp_to_vim_list(location)
    for item in converted
      let item.text = repeat('  ', a:depth) . symbol.name . ' ['
            \ . lsp#ui#vim#utils#_get_symbol_text_from_kind(a:context.server, symbol.kind) . ']'
      call add(items, item)
    endfor
    let items += s:SymbolItems(a:context, get(symbol, 'children', []), a:depth + 1)
  endfor
  return items
endfunction

function! s:SymbolsResult(context, result) abort
  let items = s:SymbolItems(a:context, empty(a:result) ? [] : a:result, 0)
  if empty(items)
    echom 'Vim LSP: no symbols found'
    return
  endif
  call sort(items, function('s:LocationOrder'))
  call s:OpenReferences(a:context, items, 'symbols')
endfunction

function! s:Symbols(workspace, query) abort
  let server = s:OperationServer(a:workspace ? 'workspace_symbol' : 'document_symbol')
  if empty(server)
    return
  endif
  let query = a:workspace && empty(a:query) ? input('symbol: ') : a:query
  if a:workspace && empty(query)
    return
  endif
  let context = s:Context('symbols', 1)
  call s:Request(context, a:workspace ? 'workspace/symbol' : 'textDocument/documentSymbol',
        \ a:workspace ? {'query': query} : {'textDocument': {'uri': context.uri}},
        \ function('s:SymbolsResult'), server)
endfunction

" 引用选择期间只预览；确认时才把调用位置加入原窗口的跳转记录。
function! s:References() abort
  call s:Navigate('references')
endfunction

function! s:OpenReferences(origin, items, title) abort
  if !bufexists(a:origin.buffer) || !win_gotoid(a:origin.window)
    return
  endif
  call setqflist([], ' ', {'items': a:items, 'title': a:title,
        \ 'context': {'vimrc_lite_lsp_references': a:origin}})
  botright copen
  call s:PreviewReference()
endfunction

function! s:DiagnosticItems(project) abort
  let buffer = bufnr('%')
  let names = lsp#get_allowed_servers(buffer)
  if a:project
    let roots = map(filter(copy(names), 'has_key(s:instances, v:val)'),
          \ 's:instances[v:val].root')
    for [name, instance] in items(s:instances)
      if index(roots, instance.root) >= 0 && !instance.stopped
            \ && lsp#is_server_running(name) && index(names, name) < 0
        call add(names, name)
      endif
    endfor
  endif
  let current_uri = lsp#utils#normalize_uri(lsp#utils#get_buffer_uri(buffer))
  let items = []
  for [uri, servers] in items(
        \ lsp#internal#diagnostics#state#_get_all_diagnostics_grouped_by_uri_and_server())
    if !a:project && uri !=# current_uri
      continue
    endif
    for [server, response] in items(servers)
      if index(names, server) < 0
        continue
      endif
      for diagnostic in get(get(response, 'params', {}), 'diagnostics', [])
        let locations = lsp#utils#location#_lsp_to_vim_list(
              \ {'uri': uri, 'range': diagnostic.range})
        if !empty(locations)
          let item = locations[0]
          let item.text = get(diagnostic, 'message', '')
          let item.type = get({1: 'E', 2: 'W', 3: 'I', 4: 'N'},
                \ get(diagnostic, 'severity', 3), 'I')
          let item.user_data = diagnostic
          call add(items, item)
        endif
      endfor
    endfor
  endfor
  return sort(items, function('s:LocationOrder'))
endfunction

function! s:DiagnosticHighlights() abort
  let groups = {'Normal': ['NormalFloat', 'Pmenu'], 'Border': ['FloatBorder', 'Comment'],
        \ 'Detail': ['Comment', 'Comment'], 'Error': ['DiagnosticError', 'ErrorMsg'],
        \ 'Warn': ['DiagnosticWarn', 'WarningMsg'], 'Info': ['DiagnosticInfo', 'Identifier'],
        \ 'Hint': ['DiagnosticHint', 'Comment']}
  for [name, targets] in items(groups)
    let target = synIDtrans(hlID(targets[0]))
    let defined = !empty(synIDattr(target, 'fg')) || !empty(synIDattr(target, 'bg'))
    execute 'highlight default link VimLspDiagnostic' . name . ' '
          \ . (defined ? targets[0] : targets[1])
  endfor
endfunction

function! s:DiagnosticOrder(column, left, right) abort
  let selected = (a:right.col == a:column) - (a:left.col == a:column)
  if selected != 0
    return selected
  endif
  let severity = get(a:left.user_data, 'severity', 3)
        \ - get(a:right.user_data, 'severity', 3)
  return severity != 0 ? severity : s:LocationOrder(a:left, a:right)
endfunction

function! s:DiagnosticContent(items) abort
  let content = {'lines': [], 'highlights': [], 'title': '', 'severity': ''}
  for item in a:items
    let diagnostic = item.user_data
    let severity = get({'E': 'Error', 'W': 'Warn', 'I': 'Info', 'N': 'Hint'}, item.type, 'Info')
    let label = severity ==# 'Warn' ? 'Warning' : severity
    let source = get(diagnostic, 'source', '')
    if !empty(source)
      let label .= (&encoding ==# 'utf-8' ? ' · ' : ' / ') . source
    endif
    let first = empty(content.title)
    if first
      let content.title = ' ' . label
            \ . (len(a:items) > 1 ? ' (' . len(a:items) . ')' : '') . ' '
      let content.severity = 'VimLspDiagnostic' . severity
    endif
    if !empty(content.lines)
      call add(content.lines, '')
    endif
    call add(content.lines, first ? trim(content.title) : label)
    call add(content.highlights,
          \ [len(content.lines), 'VimLspDiagnostic' . severity, strlen(label)])
    let message = split(substitute(item.text, '\r\n\?', "\n", 'g'), "\n", 1)
    while len(message) > 1 && empty(message[-1])
      call remove(message, -1)
    endwhile
    let content.lines += empty(message) ? [''] : message
    if has_key(diagnostic, 'code')
      let code = type(diagnostic.code) == type('') ? diagnostic.code : string(diagnostic.code)
      call extend(content.lines, ['', code])
      call add(content.highlights, [len(content.lines), 'VimLspDiagnosticDetail', strlen(code)])
    endif
  endfor
  return content
endfunction

function! s:DiagnosticPopupOptions(content) abort
  " 重绘后 winline()/wincol() 包含折叠、软换行、横向滚动及跳转后的视图变化。
  redraw
  let window = getwininfo(win_getid())[0]
  let row = window.winrow + winline() - 1
  let column = window.wincol + wincol() - 1
  let above = row - window.winrow
  let below = window.winrow + window.height - 1 - row
  if window.width < 6 || max([above, below]) < 3
    return {}
  endif
  " 为边框、左右留白及可能出现的滚动条保留五列。
  let width = min([72, window.width - 5,
        \ max(map(copy(a:content.lines), 'strdisplaywidth(v:val)'))])
  let width = max([1, width])
  let rows = 0
  for text in a:content.lines
    let rows += max([1, (strdisplaywidth(text) + width - 1) / width])
  endfor
  let upward = above >= min([10, rows]) + 2 || above >= below
  let available = upward ? above : below
  let column = max([window.wincol,
        \ min([column, window.wincol + window.width - width - 5])])
  let rounded = &encoding ==# 'utf-8' && &ambiwidth ==# 'single'
  return {'pos': upward ? 'botleft' : 'topleft', 'line': row + (upward ? -1 : 1),
        \ 'col': column, 'posinvert': 0, 'fixed': 1, 'minwidth': width, 'maxwidth': width,
        \ 'maxheight': min([10, available - 2]), 'padding': [0, 1, 0, 1],
        \ 'border': [1, 1, 1, 1],
        \ 'borderchars': rounded ? ['─', '│', '─', '│', '╭', '╮', '╯', '╰']
        \   : ['-', '|', '-', '|', '+', '+', '+', '+'],
        \ 'highlight': 'VimLspDiagnosticNormal',
        \ 'borderhighlight': ['VimLspDiagnosticBorder'],
        \ 'wrap': 1, 'scrollbar': 1, 'moved': 'any', 'mapping': 1,
        \ 'filter': function('s:DiagnosticPopupFilter'),
        \ 'callback': function('s:DiagnosticPopupClosed')}
endfunction

function! s:DiagnosticPopupFilter(window, key) abort
  if a:key ==# "\<Esc>"
    call popup_close(a:window)
    return 1
  endif
  return 0
endfunction

function! s:DiagnosticPopupClosed(window, result) abort
  if get(s:document, 'popup', 0) == a:window
    call s:RestoreDiagnosticMouse(s:document)
    let s:document = {}
  endif
endfunction

function! s:RestoreDiagnosticMouse(document) abort
  if has_key(a:document, 'mouse') && &mouse ==# a:document.mouse_enabled
    let &mouse = a:document.mouse
  endif
endfunction

function! s:CloseDiagnostics() abort
  if get(s:document, 'kind', '') ==# 'diagnostic'
    call s:CloseDocument(0)
  endif
endfunction

function! s:ShowDiagnostics(items, automatic) abort
  call s:CloseDocument(0)
  let items = sort(copy(a:items), function('s:DiagnosticOrder', [col('.')]))
  let content = s:DiagnosticContent(items)
  let options = g:lsp_preview_float ? s:DiagnosticPopupOptions(content) : {}
  let context = s:Context('diagnostic_details', 1)
  if !empty(options)
    let s:document = {'origin': context, 'lines': content.lines,
          \ 'window': 0, 'popup': popup_create(content.lines, options), 'kind': 'diagnostic'}
    if &mouse !~# '[an]'
      let s:document.mouse = &mouse
      let s:document.mouse_enabled = &mouse . 'n'
      let &mouse = s:document.mouse_enabled
    endif
    let buffer = winbufnr(s:document.popup)
    for [line, group, length] in content.highlights
      if !empty(content.lines[line - 1])
        if empty(prop_type_get(group, {'bufnr': buffer}))
          call prop_type_add(group, {'bufnr': buffer, 'highlight': group})
        endif
        call prop_add(line, 1, {'bufnr': buffer, 'type': group,
              \ 'length': length})
      endif
    endfor
  elseif a:automatic
    execute 'echohl ' . content.severity
    " 单行摘要不触发 hit-enter，也不会为了显示诊断改变分屏布局。
    let width = max([1, &columns - 12])
    let summary = strcharpart(substitute(items[0].text, '[\r\n\t]', ' ', 'g'), 0, width)
    while strdisplaywidth(summary) > width
      let summary = strcharpart(summary, 0, strchars(summary) - 1)
    endwhile
    echo summary
    echohl None
  else
    call s:ShowDocument(context, content.lines, 0, 0)
  endif
endfunction

function! s:DiagnosticDetails() abort
  let items = filter(s:DiagnosticItems(0), 'v:val.lnum == line(".")')
  if empty(items)
    call s:CloseDiagnostics()
    echom 'Vim LSP: no diagnostics on this line'
    return
  endif
  call s:ShowDiagnostics(items, 0)
endfunction

function! s:DiagnosticJump(direction, count) abort
  let items = s:DiagnosticItems(0)
  if empty(items)
    call s:CloseDiagnostics()
    echom 'Vim LSP: no diagnostics'
    return
  endif
  let positions = []
  for item in items
    let position = [item.lnum, item.col]
    if index(positions, position) < 0
      call add(positions, position)
    endif
  endfor
  let current = [line('.'), col('.')]
  let index = a:direction > 0 ? -1 : len(positions)
  for number in range(len(positions))
    if positions[number][0] < current[0] || (positions[number][0] == current[0]
          \ && positions[number][1] <= current[1])
      if a:direction > 0
        let index = number
      endif
    endif
    if a:direction < 0 && (positions[number][0] > current[0]
          \ || (positions[number][0] == current[0] && positions[number][1] >= current[1]))
      let index = number
      break
    endif
  endfor
  let index = (index + a:direction * a:count) % len(positions)
  let index = (index + len(positions)) % len(positions)
  normal! m'
  call cursor(positions[index])
  silent normal! zv
  call s:ShowDiagnostics(filter(items, 'v:val.lnum == line(".")'), 1)
endfunction

function! s:DiagnosticList(project) abort
  let items = s:DiagnosticItems(a:project)
  if empty(items)
    echom 'Vim LSP: no diagnostics'
    return
  endif
  let origin = s:Context('diagnostic_list', 1)
  if a:project
    call s:OpenReferences(origin, items, 'Project diagnostics')
  else
    call setloclist(0, [], ' ', {'items': items, 'title': 'Buffer diagnostics',
          \ 'context': {'vimrc_lite_lsp_references': origin}})
    botright lopen
    call s:PreviewReference()
  endif
endfunction

command! LspNextDiagnostic call <SID>DiagnosticJump(1, v:count1)
command! LspPreviousDiagnostic call <SID>DiagnosticJump(-1, v:count1)
nnoremap <silent> ]d :<C-u>call <SID>DiagnosticJump(1, v:count1)<CR>
nnoremap <silent> [d :<C-u>call <SID>DiagnosticJump(-1, v:count1)<CR>

function! s:SetReferenceIndex(index) abort
  if get(w:, 'vimrc_lite_reference_location', 0)
    call setloclist(0, [], 'a', {'idx': a:index})
  else
    call setqflist([], 'a', {'idx': a:index})
  endif
endfunction

function! s:CloseReferenceList(window) abort
  let info = getwininfo(a:window)
  if !empty(info) && info[0].loclist
    lclose
  else
    cclose
  endif
endfunction

function! s:ReferenceList() abort
  if &buftype !=# 'quickfix'
    return {}
  endif
  let location = getwininfo(win_getid())[0].loclist
  let list = location ? getloclist(0, {'id': 0, 'context': 0, 'winid': 0})
        \ : getqflist({'id': 0, 'context': 0, 'winid': 0})
  if list.winid != win_getid() || type(list.context) != type({})
        \ || !has_key(list.context, 'vimrc_lite_lsp_references')
    return {}
  endif
  " quickfix buffer 可复用；按列表 ID 和文本变更重新读取条目。
  if get(w:, 'vimrc_lite_reference_id', -1) != list.id
        \ || get(w:, 'vimrc_lite_reference_tick', -1) != b:changedtick
    let w:vimrc_lite_reference_id = list.id
    let w:vimrc_lite_reference_tick = b:changedtick
    let w:vimrc_lite_reference_items = location ? getloclist(0) : getqflist()
    let w:vimrc_lite_reference_preview = 0
  endif
  let w:vimrc_lite_reference_location = location
  return list.context.vimrc_lite_lsp_references
endfunction

function! s:ShowReference(item) abort
  if !get(a:item, 'valid', 0) || get(a:item, 'bufnr', 0) <= 0
        \ || !bufexists(a:item.bufnr)
    return 0
  endif
  if bufnr('%') != a:item.bufnr
    if get(s:, 'previewing_reference', 0)
          \ && empty(getbufvar(a:item.bufnr, 'vimrc_lite_lsp_binding', {}))
      call setbufvar(a:item.bufnr, 'vimrc_lite_lsp_preview', 1)
    endif
    execute 'keepalt keepjumps hide buffer ' . a:item.bufnr
  endif
  call cursor(a:item.lnum, max([1, a:item.col]))
  silent keepjumps normal! zvzz
  return 1
endfunction

function! s:PreviewReference() abort
  if get(s:, 'previewing_reference', 0)
    return
  endif
  let origin = s:ReferenceList()
  if empty(origin)
    return
  endif
  if !get(b:, 'vimrc_lite_reference_mappings', 0)
    nnoremap <silent><buffer> <CR> :<C-u>call <SID>ConfirmReference()<CR>
    nnoremap <silent><buffer> q :<C-u>call <SID>CancelReference(1)<CR>
    nnoremap <silent><buffer> <Esc> :<C-u>call <SID>CancelReference(0)<CR>
    let b:vimrc_lite_reference_mappings = 1
  endif
  let index = line('.')
  if w:vimrc_lite_reference_preview == index
    return
  endif
  let item = get(w:vimrc_lite_reference_items, index - 1, {})
  let list_window = win_getid()
  let s:previewing_reference = 1
  try
    noautocmd let found = win_gotoid(origin.window)
    if found && s:ShowReference(item)
      noautocmd call win_gotoid(list_window)
      call s:SetReferenceIndex(index)
      call setwinvar(list_window, 'vimrc_lite_reference_preview', index)
    endif
  catch
    call s:Warn(v:exception)
  finally
    noautocmd call win_gotoid(list_window)
    let s:previewing_reference = 0
  endtry
endfunction

" BufWinEnter/WinEnter 期间 Vim 可能锁住 buffer；退出该事件后再更新预览。
function! s:DelayedReferencePreview(window, timer) abort
  let s:reference_preview_timer = -1
  if win_getid() == a:window
    call s:PreviewReference()
  endif
endfunction

function! s:QueueReferencePreview() abort
  if &buftype !=# 'quickfix'
    return
  endif
  if get(s:, 'reference_preview_timer', -1) != -1
    call timer_stop(s:reference_preview_timer)
  endif
  let w:vimrc_lite_reference_preview = 0
  let s:reference_preview_timer = timer_start(0,
        \ function('s:DelayedReferencePreview', [win_getid()]))
endfunction

function! s:RestoreReferenceOrigin(origin) abort
  if !bufexists(a:origin.buffer) || !win_gotoid(a:origin.window)
    return 0
  endif
  if bufnr('%') != a:origin.buffer
    execute 'keepalt keepjumps hide buffer ' . a:origin.buffer
  endif
  call winrestview(a:origin.view)
  return 1
endfunction

function! s:ConfirmReference() abort
  let origin = s:ReferenceList()
  if empty(origin)
    execute "normal! \<CR>"
    return
  endif
  let index = line('.')
  let item = get(w:vimrc_lite_reference_items, index - 1, {})
  let list_window = win_getid()
  let location = get(w:, 'vimrc_lite_reference_location', 0)
  let s:previewing_reference = 1
  try
    if s:RestoreReferenceOrigin(origin)
      normal! m'
      if s:ShowReference(item)
        if location
          call setloclist(0, [], 'a', {'idx': index})
        else
          call setqflist([], 'a', {'idx': index})
        endif
        call setwinvar(list_window, 'vimrc_lite_reference_preview', index)
        call s:CloseReferenceList(list_window)
        return
      endif
    endif
    call win_gotoid(list_window)
  catch
    call win_gotoid(list_window)
    call s:Warn(v:exception)
  finally
    let s:previewing_reference = 0
    let b:vimrc_lite_lsp_preview = 0
    call s:PrepareBuffer(bufnr('%'))
    call lsp#activate()
  endtry
endfunction

function! s:CancelReference(close) abort
  let origin = s:ReferenceList()
  if empty(origin)
    if a:close
      close
    endif
    return
  endif
  let s:previewing_reference = 1
  try
    let list_window = win_getid()
    let restored = s:RestoreReferenceOrigin(origin)
    call s:CloseReferenceList(list_window)
    if restored
      call winrestview(origin.view)
    endif
  finally
    let s:previewing_reference = 0
  endtry
endfunction

nnoremap <silent> <plug>(lsp-references) :<C-u>call <SID>References()<CR>
nnoremap <silent> <plug>(lsp-definition) :<C-u>call <SID>Navigate('definition')<CR>
command! LspDefinition VimLspDefinition
command! LspReferences VimLspReferences
command! LspDeclaration VimLspDeclaration
command! LspTypeDefinition VimLspTypeDefinition
command! LspImplementation VimLspImplementation
nnoremap <silent> <plug>(lsp-hover) :<C-u>call <SID>Hover()<CR>
command! LspHover VimLspHover
command! LspSignatureHelp VimLspSignature
command! LspRename VimLspRename
command! -range LspCodeAction call <SID>Action('action', <range>, <line1>, <line2>)
command! LspDocumentFormat VimLspFormat
command! -range=% LspDocumentRangeFormat call <SID>Action('format', 1, <line1>, <line2>)
command! LspDocumentSymbol call <SID>Symbols(0, '')
command! -nargs=* LspWorkspaceSymbol call <SID>Symbols(1, <q-args>)
let g:lsp_hover_window_getter = expand('<SID>') . 'DocumentWindow'

function! s:Kind(name) abort
  return get(get(s:instances, a:name, {}), 'kind', a:name)
endfunction

function! s:ProjectRoot(name, buffer) abort
  let start = fnamemodify(resolve(fnamemodify(bufname(a:buffer), ':p')), ':h')
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

function! s:RootUri(name, info) abort
  return lsp#utils#path_to_uri(s:servers[a:name].root)
endfunction

function! s:FilterBuffer(name, buffer) abort
  let instance = s:instances[a:name]
  return !instance.stopped && !empty(instance.root)
        \ && get(getbufvar(a:buffer, 'vimrc_lite_lsp_binding', {}), instance.kind, '')
        \ ==# a:name
endfunction

function! s:InstanceExited(data) abort
  let name = get(get(get(a:data, 'response', {}), 'params', {}), 'server', '')
  if !has_key(s:instances, name)
    return
  endif
  let instance = s:instances[name]
  if !instance.stopped
    let instance.stopped = 1
    let instance.failed = 1
    let instance.generation += 1
  endif
  call s:CancelObsoleteRequests()
  call s:BufferEntered()
  call s:QueueIndicators()
endfunction

function! s:RegisterInstance(name) abort
  let kind = s:Kind(a:name)
  let server = s:servers[a:name]
  let capabilities = lsp#default_get_supported_capabilities({'name': a:name})
  let capabilities.window.workDoneProgress = v:true
  let capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport = v:true
  let capabilities.workspace.workspaceEdit =
        \ {'documentChanges': v:true, 'failureHandling': 'transactional'}
  let capabilities.textDocument.codeAction.dataSupport = v:true
  let capabilities.textDocument.codeAction.resolveSupport = {'properties': ['edit', 'command']}
  let capabilities.textDocument.completion.completionItem.resolveSupport.properties =
        \ ['documentation', 'detail', 'additionalTextEdits']
  let capabilities.textDocument.signatureHelp.signatureInformation =
        \ {'documentationFormat': ['markdown', 'plaintext'], 'activeParameterSupport': v:true,
        \ 'parameterInformation': {'labelOffsetSupport': v:true}}
  call lsp#register_server({'name': a:name, 'allowlist': server.filetypes,
        \ 'vimrc_generation': s:instances[a:name].generation,
        \ 'cmd': copy(server.cmd), 'buffer_filter': function('s:FilterBuffer', [a:name]),
        \ 'capabilities': capabilities,
        \ 'config': {'sort': {'max': 10000}},
        \ 'initialization_options': kind ==# 'clangd' ? {'clangdFileStatus': v:true} : {},
        \ 'root_uri': function('s:RootUri', [a:name])})
endfunction

function! s:PrepareBuffer(buffer) abort
  if !s:ready || getbufvar(a:buffer, '&buftype') !=# '' || empty(bufname(a:buffer))
        \ || getbufvar(a:buffer, 'vimrc_lite_large_file', 0)
    return
  endif
  let filetype = getbufvar(a:buffer, '&filetype')
  let key = [bufname(a:buffer), filetype]
  if getbufvar(a:buffer, 'vimrc_lite_lsp_binding_key', []) ==# key
    return
  endif
  let binding = {}
  let preview = get(s:, 'previewing_reference', 0)
        \ || getbufvar(a:buffer, 'vimrc_lite_lsp_preview', 0)
  for kind in ['pyright', 'clangd']
    if index(s:servers[kind].filetypes, filetype) < 0
      continue
    endif
    let root = s:ProjectRoot(kind, a:buffer)
    let root_key = kind . "\n" . root
    if has_key(s:roots, root_key)
      let name = s:roots[root_key]
    elseif !empty(s:servers[kind].reason)
      continue
    elseif empty(s:instances[kind].root)
      let name = kind
      let s:instances[name].root = root
      let s:servers[name].root = root
      let s:roots[root_key] = name
    else
      " 浏览列表时可绑定已有实例，但不为瞬时预览创建新项目进程。
      if preview
        continue
      endif
      let s:instance_serial += 1
      let name = kind . '#' . s:instance_serial
      let s:instances[name] = {'kind': kind, 'root': root, 'stopped': 0, 'generation': 0}
      let s:servers[name] = deepcopy(s:servers[kind])
      let s:servers[name].root = root
      let s:roots[root_key] = name
      call s:RegisterInstance(name)
    endif
    let binding[kind] = name
  endfor
  call setbufvar(a:buffer, 'vimrc_lite_lsp_binding', binding)
  " 临时预览没有新实例时，确认后的正常 BufEnter 仍需重新判断。
  if !empty(binding) || !preview
    call setbufvar(a:buffer, 'vimrc_lite_lsp_binding_key', key)
  endif
endfunction

function! s:ReloadSettings() abort
  for kind in ['pyright', 'clangd']
    let command = deepcopy(get(g:, 'vimrc_lite_lsp_' . kind . '_cmd',
          \ kind ==# 'pyright' ? ['pyright-langserver', '--stdio']
          \ : ['clangd', '--background-index']))
    let reason = type(command) != type([]) || empty(command)
          \ || !empty(filter(copy(command), 'type(v:val) != type("")'))
          \ ? 'invalid command (expected a nonempty list of strings)'
          \ : !executable(command[0]) ? 'missing executable: ' . command[0] : ''
    for name in keys(s:instances)
      if s:Kind(name) ==# kind
        let s:servers[name].cmd = deepcopy(command)
        let s:servers[name].reason = reason
      endif
    endfor
    if empty(reason) && index(lsp#get_server_names(), kind) < 0
      call s:RegisterInstance(kind)
    endif
  endfor
  for buffer in getbufinfo({'bufloaded': 1})
    call setbufvar(buffer.bufnr, 'vimrc_lite_lsp_binding_key', [])
  endfor
endfunction

function! s:RestoreBindings() abort
  if !exists('b:vimrc_lite_lsp_saved')
    return
  endif
  for [key, saved] in items(b:vimrc_lite_lsp_saved.maps)
    if maparg(key, 'n') =~# '^<Plug>(lsp-'
      execute 'silent! nunmap <buffer> ' . key
      if !empty(saved) && exists('*mapset')
        call mapset('n', 0, saved)
      elseif !empty(saved)
        execute (saved.noremap ? 'nnoremap' : 'nmap') . ' <buffer> ' . key . ' ' . saved.rhs
      endif
    endif
  endfor
  if &omnifunc ==# 'lsp#complete'
    let &l:omnifunc = b:vimrc_lite_lsp_saved.omnifunc
  endif
  unlet b:vimrc_lite_lsp_saved
endfunction

function! s:BufferEntered() abort
  if !get(s:, 'previewing_reference', 0)
    let b:vimrc_lite_lsp_preview = 0
  endif
  call s:PrepareBuffer(bufnr('%'))
  if s:ready && empty(filter(lsp#get_allowed_servers(), 'lsp#is_server_running(v:val)'))
    call s:RestoreBindings()
  endif
endfunction

function! s:RestartInstance(name, buffer, started, generation, timer) abort
  if s:instances[a:name].generation != a:generation
    call timer_stop(a:timer)
    return
  endif
  if lsp#get_server_status(a:name) ==# 'running'
        \ || lsp#get_server_status(a:name) ==# 'starting'
    if reltimefloat(reltime(a:started)) > 3
      call timer_stop(a:timer)
      call s:Warn('server did not stop: ' . a:name)
    endif
    return
  endif
  call timer_stop(a:timer)
  if !empty(s:servers[a:name].reason)
    call s:Warn(s:servers[a:name].reason)
    return
  endif
  let s:instances[a:name].stopped = 0
  let s:instances[a:name].failed = 0
  call s:RegisterInstance(a:name)
  for buffer in getbufinfo({'bufloaded': 1})
    if index(values(getbufvar(buffer.bufnr, 'vimrc_lite_lsp_binding', {})), a:name) >= 0
      call lsp#activate_buffer(buffer.bufnr)
    endif
  endfor
endfunction

function! s:Control(action) abort
  if !s:ready || !empty(s:BufferReason(bufnr('%')))
    call s:Warn('language service unavailable for this buffer; see :VimLspInfo')
    return
  endif
  call s:ReloadSettings()
  call s:PrepareBuffer(bufnr('%'))
  let names = values(get(b:, 'vimrc_lite_lsp_binding', {}))
  for name in names
    if a:action ==# 'start' && lsp#is_server_running(name)
      continue
    endif
    if has_key(s:instances[name], 'control_timer')
      call timer_stop(remove(s:instances[name], 'control_timer'))
    endif
    let s:instances[name].stopped = 1
    let s:instances[name].failed = 0
    let s:instances[name].generation += 1
    call lsp#stop_server(name)
    if a:action !=# 'stop'
      let s:instances[name].control_timer = timer_start(20,
            \ function('s:RestartInstance', [name, bufnr('%'), reltime(),
            \ s:instances[name].generation]), {'repeat': -1})
    endif
  endfor
  call s:RestoreBindings()
  call s:QueueIndicators()
endfunction

function! s:OnBufferEnabled() abort
  if &buftype !=# '' || empty(bufname('%'))
    return
  endif
  let servers = filter(lsp#get_allowed_servers(), 'lsp#is_server_running(v:val)')
  if empty(servers)
    return
  endif
  if !exists('b:vimrc_lite_lsp_saved')
    let b:vimrc_lite_lsp_saved = {'omnifunc': &l:omnifunc, 'maps': {}}
    for key in ['gd', 'gr', 'K']
      let b:vimrc_lite_lsp_saved.maps[key] = maparg(key, 'n', 0, 1)
    endfor
  endif
  setlocal omnifunc=lsp#complete
  if !exists('b:lsp_diagnostics_enabled')
    let b:lsp_diagnostics_enabled = get(g:, 'vimrc_lite_lsp_diagnostics', 1)
  endif
  nmap <silent><buffer> gd <plug>(lsp-definition)
  nmap <silent><buffer> gr <plug>(lsp-references)
  nmap <silent><buffer> K <plug>(lsp-hover)
endfunction

function! s:BeforeRename() abort
  if &buftype ==# '' && exists('#lsp#BufDelete')
    doautocmd <nomodeline> lsp BufDelete
  endif
endfunction

if !s:ready
  for s:name in sort(keys(s:servers))
    let s:server = s:servers[s:name]
    let s:instances[s:name] = {'kind': s:name, 'root': '', 'stopped': 0, 'generation': 0}
    if type(s:server.cmd) != type([]) || empty(s:server.cmd)
          \ || !empty(filter(copy(s:server.cmd), 'type(v:val) != type("")'))
      let s:server.reason = 'invalid command (expected a nonempty list of strings)'
    elseif !executable(s:server.cmd[0])
      let s:server.reason = 'missing executable: ' . s:server.cmd[0]
    else
      call s:RegisterInstance(s:name)
    endif
  endfor
else
  call s:ReloadSettings()
endif
let s:ready = 1
if exists('s:ExitSubscription')
  call s:ExitSubscription()
endif
let s:ExitSubscription = lsp#callbag#pipe(lsp#stream(),
      \ lsp#callbag#filter({data -> get(get(data, 'response', {}), 'method', '')
      \ ==# '$/vimlsp/lsp_server_exit'}),
      \ lsp#callbag#tap(function('s:InstanceExited')), lsp#callbag#subscribe())
let g:lsp_buffer_prepare = expand('<SID>') . 'PrepareBuffer'
call lsp#register_notifications('vimrc_lite_lsp_indicator', function('s:IndicatorNotification'))
call s:DiagnosticHighlights()
augroup vimrc_lite_lsp
  autocmd!
  autocmd User lsp_buffer_enabled call s:OnBufferEnabled()
  autocmd BufFilePre * call s:BeforeRename()
  autocmd BufFilePost * call lsp#activate()
  autocmd BufEnter * call s:BufferEntered()
  autocmd BufEnter,WinEnter,TabEnter,BufWipeout * call s:CancelObsoleteRequests()
  autocmd CursorMoved,TextChanged,TextChangedI * call s:CancelObsoleteRequests()
  autocmd InsertLeave,BufLeave * call lsp#omni#leave()
  autocmd CompleteDone * call lsp#omni#done()
  autocmd CursorMoved,BufEnter,WinEnter,TabEnter * call s:CloseMovedDocument()
  autocmd TextChanged,TextChangedI * call s:CloseMovedDocument()
  autocmd InsertEnter,WinLeave,BufLeave,TabLeave,VimResized * call s:CloseDiagnostics()
  if exists('##WinScrolled')
    autocmd WinScrolled * call s:CloseMovedDocument()
  endif
  autocmd ColorScheme * call s:DiagnosticHighlights()
  autocmd VimEnter * call lsp#enable()
  autocmd BufWinEnter,WinEnter * call s:QueueReferencePreview()
  autocmd CursorMoved * nested call s:PreviewReference()
  " 上游预览用 :normal Ctrl-w p 返回原窗口；仅在该 buffer 避免触发 Ctrl-w 关闭。
  autocmd BufWinEnter LspHoverPreview nnoremap <silent><buffer> <C-w>p <C-w>p
augroup END
if v:vim_did_enter
  call lsp#enable()
endif
