" 剪贴板模块：复刻 Neovim 配置 lua/clipboard.lua 的行为——
"   clipboard=unnamedplus：未指定寄存器的 yank/删除/修改自动同步剪贴板；
"   SSH 会话改用 OSC 52 提供者：复制写入本地终端剪贴板；
"   自定义 paste 处理器：远端粘贴退回 Vim 未命名寄存器，不读取远程剪贴板。

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Vim clipboard: ' . a:message
  echohl None
endfunction

function! s:Ssh() abort
  return !empty($SSH_TTY) || !empty($SSH_CONNECTION)
endfunction

" OSC 52 传输开关；默认仅在 SSH 会话启用，可手动强制开或关。
function! s:Osc52Enabled() abort
  return get(g:, 'vimrc_lite_osc52', s:Ssh())
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

" 静默同步剪贴板：远端发送 OSC 52，本地尽力写入 + 寄存器。
" 供 yank 钩子与文件树复用；同一失败原因只提示一次，不中断编辑。
let s:notified = ''
function! s:Sync(text, regtype) abort
  try
    if s:Osc52Enabled()
      call writefile([s:Osc52(a:text)], '/dev/tty', 'b')
    elseif has('clipboard')
      call setreg('+', a:text, a:regtype)
    endif
  catch
    if s:notified !=# v:exception
      let s:notified = v:exception
      call s:Warn('clipboard sync skipped: ' . v:exception)
    endif
  endtry
endfunction

" 显式复制：始终写入未命名寄存器，再按环境同步并报告结果。
function! s:Copy(text, regtype) abort
  call setreg('"', a:text, a:regtype)
  if s:Osc52Enabled()
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

" TextYankPost 钩子：等价 Neovim 的 clipboard=unnamedplus。
" 未显式指定寄存器的 yank/删除/修改自动同步；命名寄存器与黑洞寄存器
" 保持 Vim 原生行为（后者不触发该事件）。
function! s:YankPost() abort
  if !get(g:, 'vimrc_lite_clipboard_yank', 1) || get(v:event, 'regname', '') !=# ''
    return
  endif
  call s:Sync(join(get(v:event, 'regcontents', []), "\n"), get(v:event, 'regtype', 'v'))
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

command! VimCopyPath call <SID>CopyPath()
command! VimCopyContent call <SID>CopyContent()

" 文件树等模块的同步入口（解析后的函数名）；模块缺失时调用方自行退回原生行为。
let g:vimrc_lite_clipboard_sync = expand('<SID>') . 'Sync'

if exists('##TextYankPost')
  augroup vimrc_lite_clipboard
    autocmd!
    autocmd TextYankPost * call s:YankPost()
  augroup END
endif

" 远端会话或无系统剪贴板时，+/* 寄存器粘贴退回未命名寄存器，
" 与 Neovim 自定义 OSC 52 paste 处理器一致：不读取远程剪贴板。
if s:Osc52Enabled() || !has('clipboard')
  nnoremap <silent> "+p ""p
  nnoremap <silent> "+P ""P
  nnoremap <silent> "*p ""p
  nnoremap <silent> "*P ""P
  xnoremap <silent> "+p ""p
  xnoremap <silent> "+P ""P
  xnoremap <silent> "*p ""p
  xnoremap <silent> "*P ""P
  inoremap <silent> <C-r>+ <C-r>"
  inoremap <silent> <C-r>* <C-r>"
endif
