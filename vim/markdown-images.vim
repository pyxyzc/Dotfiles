" 图片通过异步 helper 或本地预览页进入文档旁 imgs/，定位用文本属性跟踪。
let s:directory = fnamemodify(resolve(expand('<sfile>:p')), ':h') . '/markdown'
let s:requests = {}
let s:next = 0

function! s:Warn(message) abort
  echohl WarningMsg
  echom 'Markdown image: ' . a:message
  echohl None
endfunction

function! s:Forget(id) abort
  if !has_key(s:requests, a:id)
    return
  endif
  let request = remove(s:requests, a:id)
  if has('textprop') && bufexists(request.buf)
    call prop_remove({'bufnr': request.buf, 'type': 'VimMarkdownImageAnchor',
          \ 'id': a:id, 'both': 1, 'all': 1}, 1, getbufinfo(request.buf)[0].linecount)
  endif
endfunction

function! s:Markup(relative, name) abort
  let path = substitute(a:relative, '[ ()#%<>]', '\=printf("%%%02X", char2nr(submatch(0)))', 'g')
  let title = escape(fnamemodify(a:name, ':r'), '\[]')
  let result = '![' . title . '](' . path . ')'
  let width = get(g:, 'vimrc_lite_markdown_image_width', '')
  let align = get(g:, 'vimrc_lite_markdown_image_align', '')
  let attributes = []
  if width =~# '^\d\+%\=$'
    call add(attributes, 'width=' . width)
  endif
  if index(['left', 'center', 'right'], align) >= 0
    call add(attributes, 'align=' . align)
  endif
  return result . (empty(attributes) ? '' : '{' . join(attributes, ' ') . '}')
endfunction

function! s:Insert(id, image) abort
  if !has_key(s:requests, a:id)
    return
  endif
  let request = s:requests[a:id]
  try
    if !bufloaded(request.buf) || getbufvar(request.buf, '&readonly')
          \ || !getbufvar(request.buf, '&modifiable')
      call s:Warn('image saved at ' . a:image.path . '; source buffer is unavailable')
      return
    endif
    let position = has('textprop') ? prop_find({'bufnr': request.buf,
          \ 'type': 'VimMarkdownImageAnchor', 'id': a:id, 'both': 1,
          \ 'lnum': 1, 'col': 1}, 'f') : {}
    if empty(position)
      if getbufvar(request.buf, 'changedtick') != request.tick
        call s:Warn('image saved at ' . a:image.path . '; insertion point changed')
        return
      endif
      let position = {'lnum': request.line, 'col': request.column}
    endif
    let text = getbufline(request.buf, position.lnum)[0]
    let markup = s:Markup(a:image.relative, a:image.name)
    call setbufline(request.buf, position.lnum, strpart(text, 0, position.col - 1)
          \ . markup . strpart(text, position.col - 1))
    echom 'Markdown image: ' . a:image.relative
    if exists('*VimMarkdownPreviewSync')
      call VimMarkdownPreviewSync()
    endif
  finally
    call s:Forget(a:id)
  endtry
endfunction

function! s:Bridge(id) abort
  if !has_key(s:requests, a:id)
    return
  endif
  let request = s:requests[a:id]
  if bufnr('%') != request.buf
    call s:Warn('return to the source buffer and run :VimMarkdownImage! for browser paste')
    call s:Forget(a:id)
    return
  endif
  call VimMarkdownImageBridge({'id': a:id, 'folder': request.folder,
        \ 'name': get(g:, 'vimrc_lite_markdown_image_name', '')})
  echom 'Markdown image: click 粘贴图片 or paste in the local preview page (SSH supported)'
endfunction

function! s:Output(id, channel, message) abort
  if !has_key(s:requests, a:id)
    return
  endif
  try
    let result = json_decode(a:message)
    if has_key(result, 'error')
      let s:requests[a:id].error = result.error
    elseif has_key(result, 'relative')
      call s:Insert(a:id, result)
    endif
  catch
    if has_key(s:requests, a:id)
      let s:requests[a:id].error = 'invalid clipboard helper output'
    endif
  endtry
endfunction

function! s:Closed(id, channel) abort
  if has_key(s:requests, a:id)
    call s:Bridge(a:id)
  endif
endfunction

function! VimMarkdownImage(browser, source) abort
  if &filetype !=# 'markdown' || &buftype !=# '' || !&modifiable || &readonly
    return
  endif
  if empty(bufname('%'))
    call s:Warn('give the Markdown document a filename before pasting an image')
    return
  endif
  let folder = get(g:, 'vimrc_lite_markdown_image_dir', 'imgs')
  call VimMarkdownImagesStop(bufnr('%'))
  let s:next += 1
  let id = s:next
  let request = {'buf': bufnr('%'), 'tick': b:changedtick, 'line': line('.'),
        \ 'column': col('.'), 'folder': folder, 'path': expand('%:p')}
  let s:requests[id] = request
  if has('textprop')
    if empty(prop_type_get('VimMarkdownImageAnchor'))
      call prop_type_add('VimMarkdownImageAnchor', {'start_incl': 0})
    endif
    call prop_add(request.line, request.column,
          \ {'type': 'VimMarkdownImageAnchor', 'id': id, 'length': 0})
  endif
  if a:browser || (empty(a:source) && !empty($SSH_CONNECTION)
        \ && empty(get(g:, 'vimrc_lite_markdown_image_command', [])))
    call s:Bridge(id)
    return
  endif
  let command = ['python3', '-B', s:directory . '/images.py',
        \ '--directory', expand('%:p:h'), '--folder', folder,
        \ '--name', get(g:, 'vimrc_lite_markdown_image_name', '')]
  if !empty(a:source)
    let command += ['--file', fnamemodify(expand(a:source), ':p')]
  elseif !empty(get(g:, 'vimrc_lite_markdown_image_command', []))
    let command += ['--command-json', json_encode(g:vimrc_lite_markdown_image_command)]
  endif
  let request.job = job_start(command, {'out_cb': function('<SID>Output', [id]),
        \ 'close_cb': function('<SID>Closed', [id]), 'err_io': 'null', 'stoponexit': 'term'})
  if job_status(request.job) ==# 'fail'
    call s:Warn('could not start python3 image helper')
    call s:Forget(id)
  endif
endfunction

function! VimMarkdownImageReceived(event) abort
  let id = get(a:event, 'request', -1)
  if has_key(s:requests, id)
    if fnamemodify(a:event.source, ':p') ==# s:requests[id].path
      call s:Insert(id, a:event)
    endif
  else
    call s:Warn('image saved at ' . a:event.path . '; paste request is no longer active')
  endif
endfunction

function! VimMarkdownImageSize(arguments) abort
  if &filetype !=# 'markdown' || &buftype !=# '' || !&modifiable || &readonly
    return
  endif
  let args = split(a:arguments)
  let width = get(args, 0, '70%')
  let align = get(args, 1, 'center')
  if width !~# '^\d\+%\=$' || str2nr(width) < 1
        \ || str2nr(width) > (width =~# '%' ? 100 : 4096)
        \ || index(['left', 'center', 'right'], align) < 0
    call s:Warn('size: width 1..100% or 1..4096 pixels, then left/center/right')
    return
  endif
  let text = getline('.')
  let match = matchstrpos(text, '!\[[^]]*\]([^)]*)\%({[^}]*}\)\=')
  if match[1] < 0 || !&modifiable || &readonly
    call s:Warn('put the cursor on a line containing an image')
    return
  endif
  let image = substitute(match[0], '{[^}]*}$', '', '')
  call setline('.', strpart(text, 0, match[1]) . image . '{width=' . width
        \ . ' align=' . align . '}' . strpart(text, match[2]))
endfunction

function! VimMarkdownImagesAttach() abort
  nnoremap <silent><buffer> <leader>mv :VimMarkdownImage<CR>
  nnoremap <silent><buffer> <leader>mV :VimMarkdownImage!<CR>
endfunction

function! VimMarkdownImagesStop(...) abort
  for id in keys(copy(s:requests))
    let request = s:requests[id]
    if a:0 && request.buf != a:1
      continue
    endif
    if has_key(request, 'job') && job_status(request.job) ==# 'run'
      call job_stop(request.job)
    endif
    call s:Forget(str2nr(id))
  endfor
endfunction

command! -bang -nargs=? -complete=file VimMarkdownImage
      \ call VimMarkdownImage(<bang>0, <q-args>)
command! -nargs=* VimMarkdownImageSize call VimMarkdownImageSize(<q-args>)
augroup vimrc_lite_markdown_images
  autocmd!
  autocmd BufWipeout * call VimMarkdownImagesStop(str2nr(expand('<abuf>')))
augroup END
