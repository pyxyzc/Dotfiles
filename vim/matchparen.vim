" 保留系统括号高亮，仅跳过光标附近没有配对字符时的整行正则扫描。
function! s:Highlight() abort
  if &encoding !=# 'utf-8' || pumvisible()
    call call(s:highlight, [])
    return
  endif
  " UTF-8 字符最多四字节；前后多保留一点，宁可交回系统处理，不漏掉真实配对。
  let nearby = strpart(getline('.'), max([0, col('.') - 5]), 12)
  for character in split(&l:matchpairs, '.\zs[:,]')
    if stridx(nearby, character) >= 0
      call call(s:highlight, [])
      return
    endif
  endfor
  call call(s:remove, [])
endfunction

function! s:Install() abort
  " 仅适配具有这些辅助函数的系统版本；结构不同则完整保留原插件。
  let scripts = filter(split(execute('scriptnames'), "\n"), 'v:val =~# "/plugin/matchparen\.vim$"')
  if len(scripts) != 1
    return
  endif
  let prefix = '<SNR>' . matchstr(scripts[0], '^\s*\zs\d\+\ze:') . '_'
  if !exists('*' . prefix . 'Highlight_Matching_Pair') || !exists('*' . prefix . 'Remove_Matches')
    return
  endif
  let s:highlight = function(prefix . 'Highlight_Matching_Pair')
  let s:remove = function(prefix . 'Remove_Matches')
  for event in ['CursorMoved', 'CursorMovedI', 'WinEnter', 'BufWinEnter', 'WinScrolled',
        \ 'TextChanged', 'TextChangedI']
    if exists('##' . event) && exists('#matchparen#' . event)
      execute 'autocmd! matchparen ' . event
      execute 'autocmd matchparen ' . event . ' * call ' . expand('<SID>') . 'Highlight()'
    endif
  endfor
endfunction

" :NoMatchParen 仍清空原组；:DoMatchParen 再次加载插件后重新接入前置检查。
if exists('##SourcePost')
  augroup vimrc_lite_matchparen
    autocmd!
    autocmd SourcePost */plugin/matchparen.vim call <SID>Install()
  augroup END
endif
runtime plugin/matchparen.vim
call s:Install()
