" 直接运行本机 LazyGit，终端的启动与退出交给 terminal.vim。
function! s:LazyGit() abort
  if !executable('lazygit')
    echohl WarningMsg
    echom 'Vim Git: LazyGit requires lazygit in PATH'
    echohl None
    return
  endif
  VimTerminal lazygit
endfunction

command! VimGit call <SID>LazyGit()
