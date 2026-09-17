" 使用 Vim 自带 netrw 管理侧边文件树；关闭插件自动加载时也显式启用。
runtime plugin/netrwPlugin.vim

let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_winsize = 25
let g:netrw_keepdir = 1

nnoremap <silent> <leader>e :Lexplore<CR>
