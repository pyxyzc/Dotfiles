" 共享项目定位与状态目录；不读取或执行项目配置。
function! VimLiteProjectRoot(...) abort
  let options = get(a:000, 0, {})
  let buffer = get(options, 'buffer', bufnr('%'))
  let purpose = get(options, 'purpose', 'default')
  let path = bufname(buffer)
  let start = getbufvar(buffer, '&buftype') ==# '' && !empty(path)
        \ ? (isdirectory(path) ? fnamemodify(path, ':p') : fnamemodify(path, ':p:h')) : getcwd()
  let start = substitute(resolve(start), '/\+$', '', '')
  let start = empty(start) ? '/' : start
  let override = getbufvar(buffer, 'vimrc_lite_project_root',
        \ get(g:, 'vimrc_lite_project_root', ''))
  if type(override) == type({})
    let override = get(override, purpose, get(override, 'default', ''))
  endif
  if type(override) != type('')
    throw 'Vim project: root override must be a path or a dictionary of paths'
  endif
  if !empty(override)
    let root = expand(override)
    let root = root =~# '^/' ? root : start . '/' . root
    if !isdirectory(root)
      throw 'Vim project: root does not exist: ' . root
    endif
    let root = substitute(resolve(fnamemodify(root, ':p')), '/\+$', '', '')
    return empty(root) ? '/' : root
  endif
  let defaults = ['.git', '.hg', '.svn', '.bzr', '_darcs', 'pyproject.toml',
        \ 'pyrightconfig.json', 'setup.py', 'setup.cfg', '.clangd', 'CMakeLists.txt',
        \ 'compile_commands.json', 'Makefile', 'package.json', 'pom.xml', '.vim-lite-tasks.json']
  let configured = get(g:, 'vimrc_lite_root_markers', {})
  let markers = get(configured, purpose, get(options, 'markers', defaults))
  if type(markers) != type([]) || !empty(filter(copy(markers), 'type(v:val) != type("")'))
    throw 'Vim project: root markers must be a list of strings'
  endif
  let directory = start
  while 1
    for marker in markers
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
