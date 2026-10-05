" 共享项目定位与状态目录；不读取或执行项目配置。
function! VimLiteProjectRoot() abort
  let start = &buftype ==# '' && !empty(bufname('%'))
        \ ? expand('%:p:h') : getcwd()
  let directory = start
  while 1
    for marker in ['.git', '.hg', '.svn', 'pyproject.toml', 'pyrightconfig.json',
          \ 'CMakeLists.txt', 'compile_commands.json', 'Makefile', 'package.json',
          \ '.vim-lite-tasks.json']
      if !empty(getftype(directory . '/' . marker))
        return resolve(directory)
      endif
    endfor
    let parent = fnamemodify(directory, ':h')
    if parent ==# directory
      return resolve(start)
    endif
    let directory = parent
  endwhile
endfunction

function! VimLiteStateDir(name) abort
  let home = empty($XDG_STATE_HOME) ? expand('~/.local/state') : $XDG_STATE_HOME
  let directory = home . '/vim-lite/' . a:name
  if !isdirectory(directory)
    call mkdir(directory, 'p', 0700)
  endif
  return directory
endfunction

if exists('+undofile')
  if get(g:, 'vimrc_lite_persistent_undo', 1)
    try
      let &undodir = escape(VimLiteStateDir('undo'), ' ,') . '//'
      set undofile
    catch
      set noundofile
      let g:vimrc_lite_undo_error = v:exception
    endtry
  else
    set noundofile
  endif
endif
