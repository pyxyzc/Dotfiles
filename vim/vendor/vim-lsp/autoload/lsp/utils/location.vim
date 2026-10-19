function! s:open_location(path, line, col, ...) abort
    normal! m'
    let l:mods = a:0 ? a:1 : ''
    let l:buffer = bufnr(a:path)
    if l:mods ==# '' && &modified && !&hidden && l:buffer != bufnr('%')
        let l:mods = &splitbelow ? 'rightbelow' : 'leftabove'
    endif
    if l:mods ==# ''
        if l:buffer == bufnr('%')
            let l:cmd = ''
        else
            let l:cmd = (l:buffer !=# -1 ? 'b ' . l:buffer : 'edit ' . fnameescape(a:path)) . ' | '
        endif
    else
        let l:cmd = l:mods . ' ' . (l:buffer !=# -1 ? 'sb ' . l:buffer : 'split ' . fnameescape(a:path)) . ' | '
    endif
    execute l:cmd . 'call cursor('.a:line.','.a:col.')'
endfunction

" @param location = {
"   'filename',
"   'lnum',
"   'col',
" }
function! lsp#utils#location#_open_vim_list_item(location, mods) abort
    call s:open_location(a:location['filename'], a:location['lnum'], a:location['col'], a:mods)
endfunction

" @params {location} = {
"   'uri': 'file://....',
"   'range': {
"       'start': { 'line': 1, 'character': 1 },
"       'end': { 'line': 1, 'character': 1 },
"   }
" }
function! lsp#utils#location#_open_lsp_location(location) abort
    let l:path = lsp#utils#uri_to_path(a:location['uri'])
    let l:bufnr = bufnr(l:path)

    let [l:start_line, l:start_col] = lsp#utils#position#lsp_to_vim(l:bufnr, a:location['range']['start'])
    let [l:end_line, l:end_col] = lsp#utils#position#lsp_to_vim(l:bufnr, a:location['range']['end'])

    call s:open_location(l:path, l:start_line, l:start_col)

    normal! V
    call setpos("'<", [l:bufnr, l:start_line, l:start_col])
    call setpos("'>", [l:bufnr, l:end_line, l:end_col])
endfunction

" @param loc = Location | LocationLink
" @param cache = {} empty dict
" @returns {
"   'filename',
"   'lnum',
"   'col',
"   'end_lnum',
"   'end_col',
"   'text',
"   'viewstart?',
"   'viewend?',
" }
function! s:lsp_location_item_to_vim(loc, cache) abort
    if has_key(a:loc, 'targetUri') " LocationLink
        let l:uri = a:loc['targetUri']
        let l:range = a:loc['targetSelectionRange']
        let l:use_link = 1
    else " Location
        let l:uri = a:loc['uri']
        let l:range = a:loc['range']
        let l:use_link = 0
    endif

    if !lsp#utils#is_file_uri(l:uri)
        return v:null
    endif

    let l:path = lsp#utils#uri_to_path(l:uri)
    if !has_key(a:cache, l:path)
        let l:contents = getbufline(l:path, 1, '$')
        if empty(l:contents)
            let l:contents = readfile(l:path)
        endif
        let a:cache[l:path] = l:contents
    endif
    " One response owns one snapshot per file, including unsaved buffer text.
    " Convert both UTF-16 columns from that snapshot instead of rereading files.
    let l:start = l:range['start']
    let l:end = l:range['end']
    let l:text = get(a:cache[l:path], l:start.line, '')
    let l:loc_range = {
        \ 'lnum': l:start.line + 1,
        \ 'col': lsp#utils#utf16#byteidx(l:text, l:start.character) + 1,
        \ 'end_lnum': l:end.line + 1,
        \ 'end_col': lsp#utils#utf16#byteidx(
        \     get(a:cache[l:path], l:end.line, ''), l:end.character) + 1,
        \ }

    if l:use_link
        " viewstart/end decremented to account for incrementing in _lsp_to_vim
        return extend({
            \ 'filename': l:path,
            \ 'text': l:text,
            \ 'viewstart': a:loc['targetRange']['start']['line'],
            \ 'viewend': a:loc['targetRange']['end']['line'],
            \ }, l:loc_range)
    else
        return extend({
            \ 'filename': l:path,
            \ 'text': l:text,
            \ }, l:loc_range)
    endif
endfunction

" @summary Use this to convert loc to vim list that is compatible with
" quickfix and locllist items
" @param loc = v:null | Location | Location[] | LocationLink
" @param cache? = {} shared only within the current response
" @returns []
function! lsp#utils#location#_lsp_to_vim_list(loc, ...) abort
    let l:result = []
    let l:cache = a:0 ? a:1 : {}
    if empty(a:loc) " v:null
        return l:result
    elseif type(a:loc) == type([]) " Location[]
        for l:location in a:loc
            let l:vim_loc = s:lsp_location_item_to_vim(l:location, l:cache)
            if !empty(l:vim_loc) " https:// uri will return empty
                call add(l:result, l:vim_loc)
            endif
        endfor
    else " Location or LocationLink
        let l:vim_loc = s:lsp_location_item_to_vim(a:loc, l:cache)
        if !empty(l:vim_loc) " https:// uri will return empty
            call add(l:result, l:vim_loc)
        endif
    endif
    return l:result
endfunction
