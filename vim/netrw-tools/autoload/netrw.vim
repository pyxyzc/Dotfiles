" 仅由 tree.vim 显式加载，保持原生传输的参数、范围与脚本私有状态。
if !exists('g:vimrc_lite_netrw_bridge')
  finish
endif
let s:state = g:vimrc_lite_netrw_bridge

function! netrw#NetRead(...) abort
  call call(s:state.Resolve, [])
  return call(s:state.Read, a:000)
endfunction

function! netrw#NetWrite(...) range abort
  call call(s:state.Resolve, [])
  let NativeWrite = s:state.Write
  let arguments = join(map(range(a:0), '"a:000[" . v:val . "]"'), ',')
  execute a:firstline . ',' . a:lastline . 'call NativeWrite(' . arguments . ')'
endfunction

function! netrw#NetSource(...) abort
  call call(s:state.Resolve, [])
  return call(s:state.Source, a:000)
endfunction
