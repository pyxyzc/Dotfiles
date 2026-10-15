" 按需展示快捷键和环境状态，不运行版本探测进程或项目任务。
function! s:Show(title, lines) abort
  botright new
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile noundofile
  call setline(1, [a:title, ''] + a:lines)
  setlocal nomodifiable nowrap
  nnoremap <silent><buffer> q :close<CR>
endfunction

function! s:Keys(query) abort
  let labels = {
        \ 'VimFind': '查找文件 / find files',
        \ 'VimSearch': '项目搜索 / project search',
        \ 'VimSearchWord': '搜索当前单词 / search word',
        \ 'VimSearchSelection': '搜索选区 / search selection',
        \ 'VimRecent': '最近文件 / recent files',
        \ 'VimPinToggle': '切换行级 pin / toggle pin',
        \ 'VimPinClear': '清除当前行 pin / clear pin',
        \ 'VimPinClearFile': '清除当前文件 pins / clear file pins',
        \ 'VimPinClearProject': '清除当前项目 pins / clear project pins',
        \ 'VimPinNext': '下一个 pin / next pin',
        \ 'VimPinPrev': '上一个 pin / previous pin',
        \ 'VimLspRename': '符号重命名 / rename',
        \ 'VimLspCodeAction': '代码操作 / code action',
        \ 'VimLspFormat': '格式化 / format',
        \ 'VimLspSymbols': '函数与类列表 / symbols',
        \ 'VimLspDiagnostics': '诊断开关 / diagnostics',
        \ 'VimLspDiagnosticDetails': '当前行诊断详情 / diagnostic details',
        \ 'VimLspDiagnosticList': '当前文件诊断列表 / diagnostic list',
        \ 'VimLspDeclaration': '跳转声明 / declaration',
        \ 'VimLspTypeDefinition': '跳转类型定义 / type definition',
        \ 'VimLspImplementation': '选择实现 / implementation',
        \ 'VimLspWorkspaceSymbols': '查询工作区符号 / workspace symbols',
        \ 'VimLspSignature': '手动签名帮助 / signature help',
        \ 'VimLspInfo': 'LSP 状态面板 / language server info',
        \ 'VimTask': '运行项目任务 / run task',
        \ 'VimTaskStop': '停止任务 / stop task',
        \ 'VimTaskStatus': '任务状态 / task status',
        \ 'VimTaskOutput': '任务输出 / task output',
        \ 'VimTerminal': '新终端标签页 / new terminal',
        \ 'VimTerminalToggle': '显示隐藏终端 / toggle terminal',
        \ 'VimSessionSave': '保存会话 / save session',
        \ 'VimSessionLoad': '恢复会话 / restore session',
        \ 'VimHealth': '环境检查 / health',
        \ 'VimKeys': '快捷键查询 / keys',
        \ 'VimGit': '打开 LazyGit / git',
        \ 'VimCopyPath': '复制文件路径 / copy path',
        \ 'VimCopyContent': '复制全文 / copy content',
        \ 'VimMarkdownPreview': 'Markdown 实时预览 / live preview',
        \ 'VimMarkdownStop': '停止 Markdown 预览 / stop preview',
        \ 'VimMarkdownOutline': 'Markdown 标题目录 / outline',
        \ 'VimMarkdownRender': 'Markdown 阅读与源码切换 / reading view',
        \ 'VimMarkdownFocus': 'Markdown 专注写作 / focus',
        \ 'VimMarkdownTask': 'Markdown 任务勾选 / task',
        \ 'VimMarkdownTable': 'Markdown 表格对齐 / table',
        \ 'VimMarkdownLink': '打开 Markdown 链接 / follow link',
        \ 'VimMarkdownWrap': 'Markdown 选区格式 / selection format',
        \ 'VimMarkdownInsert': 'Markdown 模板 / insert template',
        \ 'VimMarkdownHelp': 'Markdown 操作说明 / help',
        \ 'wall': '保存全部 / save all',
        \ }
  let rows = []
  let sources = {}
  for script in split(execute('scriptnames'), "\n")
    let number = matchstr(script, '^\s*\zs\d\+')
    let sources[number] = substitute(script, '^\s*\d\+:\s*', '', '')
  endfor
  let key_labels = {'af': '函数整体 / entire function', 'if': '函数体 / function body',
        \ 'ac': '类整体 / entire class', 'ic': '类体 / class body',
        \ 'ab': '控制块整体 / entire block', 'ib': '控制块内容 / block body',
        \ 'gd': '跳转定义 / definition', 'gr': '列出引用 / references',
        \ 'K': '查看文档 / hover', 'gc': '切换注释 / comment motion',
        \ 'gcc': '切换行注释 / comment line', '<C-W>': '关闭 buffer / close buffer',
        \ 'H': '上一个 buffer / previous buffer', 'L': '下一个 buffer / next buffer',
        \ '[c': '上一个 Git hunk / previous hunk', ']c': '下一个 Git hunk / next hunk',
        \ '[q': '上一个 quickfix 结果 / previous result', ']q': '下一个 quickfix 结果',
        \ '[h': '上一个 Markdown 标题 / previous heading', ']h': '下一个 Markdown 标题',
        \ '[d': '上一个诊断 / previous diagnostic', ']d': '下一个诊断 / next diagnostic',
        \ ' e': '开关文件树 / toggle tree', ' bn': '新建 buffer / new buffer',
        \ ' bp': '选择 buffer / select buffer', ' bD': '清空 buffer 或选区 / clear',
        \ ' bw': '去除行尾空白 / trim whitespace', ' fh': '清除搜索高亮',
        \ ' nh': '查看消息 / messages', 'q': '普通模式禁用宏录制；辅助窗口关闭',
        \ '<C-H>': '左侧窗口 / focus left', '<C-J>': '下方窗口 / focus down',
        \ '<C-K>': '上方窗口 / focus up', '<C-L>': '右侧窗口 / focus right',
        \ }
  let tree_labels = {'Create': '新建文件或目录 / create', 'Rename': '重命名 / rename',
        \ 'Delete': '删除 / delete', 'Copy': '复制 / copy', 'Cut': '剪切 / cut',
        \ 'Paste': '粘贴 / paste', 'YankName': '复制文件名 / copy name',
        \ 'YankPath': '复制相对路径 / copy relative path', 'Refresh': '刷新文件树 / refresh',
        \ 'Hidden': '显示隐藏文件 / hidden files', 'FocusRight': '右侧窗口 / focus right'}
  if exists('*maplist')
    for mapping in maplist()
      if mapping.lhs =~? '^<Plug>' || mapping.rhs =~# '^<Plug>'
            \ && index(['gd', 'gr', 'K'], mapping.lhs) < 0
        continue
      endif
      let command = matchstr(mapping.rhs, '\<\%(Vim[A-Za-z]*\|wall\)\>')
      let description = get(key_labels, mapping.lhs, get(labels, command, mapping.rhs))
      if get(mapping, 'buffer', 0) && &filetype ==# 'netrw'
        let action = matchstr(mapping.rhs, '_\zs[A-Za-z]\+\ze'')')
        let description = get(tree_labels, action, mapping.rhs)
      endif
      let key = substitute(mapping.lhs, '^ ', '<Space>', '')
      let mode = mapping.mode ==# ' ' ? 'n' : mapping.mode[0]
      let effective = maparg(mapping.lhs, mode, 0, 1)
      let local = get(mapping, 'buffer', 0)
      let active = !empty(effective) && get(effective, 'buffer', 0) == local
      let source = get(sources, string(get(mapping, 'sid', 0)), '(interactive)')
      let source = fnamemodify(source, ':~') . ':' . get(mapping, 'lnum', 0)
      let row = printf('%-4s %-22s [%s %s] %s source=%s', mapping.mode, key,
            \ local ? 'buffer' : 'global', active ? 'active' : 'overridden', description, source)
      if empty(a:query) || stridx(tolower(row), tolower(a:query)) >= 0
        call add(rows, row)
      endif
    endfor
    call sort(rows)
  else
    let rows = split(execute('verbose map') . "\n" . execute('verbose tmap'), "\n")
    call filter(rows, 'empty(a:query) || stridx(tolower(v:val), tolower(a:query)) >= 0')
  endif
  call s:Show('快捷键 / :VimKeys [搜索词] / q 关闭', rows)
endfunction

function! s:Health() abort
  let lines = ['Vim: ' . matchstr(execute('version'), 'VIM[^\n]*'),
        \ 'Project: ' . VimLiteProjectRoot(), '']
  call add(lines, 'Search root: ' . VimLiteProjectRoot({'purpose': 'search'}))
  call add(lines, 'Tasks root: ' . VimLiteProjectRoot({'purpose': 'tasks'}))
  for feature in ['terminal', 'job', 'channel', 'timers', 'clipboard', 'persistent_undo']
    call add(lines, (has(feature) ? '[ok] ' : '[missing] ') . '+' . feature)
  endfor
  call add(lines, '')
  for name in ['bash', 'fd', 'fdfind', 'rg', 'fzf', 'gawk', 'lazygit']
    call add(lines, (executable(name) ? '[ok] ' : '[missing] ') . name
          \ . (executable(name) ? ' -> ' . exepath(name) : ''))
  endfor
  let finder = executable('fd') || executable('fdfind')
  call add(lines, 'File search: ' . (finder && executable('fzf') && executable('gawk')
        \ ? 'tools available' : 'missing tools (fd and fdfind are alternatives)'))
  call add(lines, 'fzf compatibility: requires 0.29.0+; checked when search opens')
  call add(lines, 'Clipboard: ' . (get(g:, 'vimrc_lite_osc52',
        \ !empty($SSH_CONNECTION) || !empty($SSH_TTY)) ? 'OSC 52' : has('clipboard')
        \ ? 'local clipboard' : 'unnamed register fallback'))
  call add(lines, 'Undo: ' . (exists('+undofile') && &undofile ? &undodir : 'disabled'))
  call add(lines, 'Pins: ' . (v:version >= 802 && has('textprop')
        \ && exists('*listener_add') && exists('*prop_find')
        \ && exists('*json_encode') && exists('*sha256') && exists('*timer_start')
        \ ? 'persistent line pins available' : 'requires Vim 8.2/9 with +textprop/listeners'))
  if exists('g:vimrc_lite_undo_error') && !&undofile
    call add(lines, 'Undo error: ' . g:vimrc_lite_undo_error)
  endif
  let tasks = VimLiteProjectRoot({'purpose': 'tasks'}) . '/.vim-lite-tasks.json'
  call add(lines, 'Tasks: ' . (filereadable(tasks) ? tasks : 'no project task file'))
  call add(lines, 'Markdown: native reading/editing; browser preview '
        \ . (executable('python3') && has('job') && has('channel') && has('timers')
        \ ? 'available (offline assets)' : 'needs python3 +job +channel +timers'))
  if exists(':VimLspStatus')
    let lines += [''] + split(execute('VimLspStatus'), "\n")
  endif
  call s:Show('环境检查 / q 关闭', lines)
endfunction

command! -nargs=* VimKeys call <SID>Keys(<q-args>)
command! VimHealth call <SID>Health()
