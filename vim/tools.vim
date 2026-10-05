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
        \ 'wall': '保存全部 / save all',
        \ }
  let rows = []
  let key_labels = {'af': '函数整体 / entire function', 'if': '函数体 / function body',
        \ 'ac': '类整体 / entire class', 'ic': '类体 / class body',
        \ 'ab': '控制块整体 / entire block', 'ib': '控制块内容 / block body',
        \ 'gd': '跳转定义 / definition', 'gr': '列出引用 / references',
        \ 'K': '查看文档 / hover', 'gc': '切换注释 / comment motion',
        \ 'gcc': '切换行注释 / comment line', '<C-W>': '关闭 buffer / close buffer',
        \ 'H': '上一个 buffer / previous buffer', 'L': '下一个 buffer / next buffer',
        \ '[c': '上一个 Git hunk / previous hunk', ']c': '下一个 Git hunk / next hunk',
        \ '[q': '上一个 quickfix 结果 / previous result', ']q': '下一个 quickfix 结果',
        \ '[d': '上一个诊断 / previous diagnostic', ']d': '下一个诊断 / next diagnostic',
        \ ' e': '开关文件树 / toggle tree', ' bn': '新建 buffer / new buffer',
        \ ' bp': '选择 buffer / select buffer', ' bD': '清空 buffer 或选区 / clear',
        \ ' bw': '去除行尾空白 / trim whitespace', ' fh': '清除搜索高亮',
        \ ' nh': '查看消息 / messages', 'q': '普通模式禁用宏录制；辅助窗口关闭',
        \ }
  if exists('*maplist')
    for mapping in maplist()
      if mapping.lhs =~? '^<Plug>' || mapping.rhs =~# '^<Plug>'
            \ && index(['gd', 'gr', 'K'], mapping.lhs) < 0
        continue
      endif
      let command = matchstr(mapping.rhs, '\<\%(Vim[A-Za-z]*\|wall\)\>')
      let description = get(key_labels, mapping.lhs, get(labels, command, mapping.rhs))
      let key = substitute(mapping.lhs, '^ ', '<Space>', '')
      let row = printf('%-4s %-22s %s', mapping.mode, key, description)
      if empty(a:query) || stridx(tolower(row), tolower(a:query)) >= 0
        call add(rows, row)
      endif
    endfor
    call sort(rows)
  else
    let rows = split(execute('map') . "\n" . execute('tmap'), "\n")
    call filter(rows, 'empty(a:query) || stridx(tolower(v:val), tolower(a:query)) >= 0')
  endif
  call s:Show('快捷键 / :VimKeys [搜索词] / q 关闭', rows)
endfunction

function! s:Health() abort
  let lines = ['Vim: ' . matchstr(execute('version'), 'VIM[^\n]*'),
        \ 'Project: ' . VimLiteProjectRoot(), '']
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
  if exists('g:vimrc_lite_undo_error') && !&undofile
    call add(lines, 'Undo error: ' . g:vimrc_lite_undo_error)
  endif
  let tasks = VimLiteProjectRoot() . '/.vim-lite-tasks.json'
  call add(lines, 'Tasks: ' . (filereadable(tasks) ? tasks : 'no project task file'))
  if exists(':VimLspStatus')
    let lines += [''] + split(execute('VimLspStatus'), "\n")
  endif
  call s:Show('环境检查 / q 关闭', lines)
endfunction

command! -nargs=* VimKeys call <SID>Keys(<q-args>)
command! VimHealth call <SID>Health()
