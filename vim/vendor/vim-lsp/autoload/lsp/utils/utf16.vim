" Local UTF-16 compatibility patch; provenance and upgrade notes: SOURCE.md.
" LSP defaults to UTF-16, including separate units for composing characters.
function! lsp#utils#utf16#length(text) abort
    if exists('*strutf16len')
        return strutf16len(a:text, 1)
    endif
    return lsp#utils#utf16#_length_fallback(a:text)
endfunction

function! lsp#utils#utf16#strpart(text, start, ...) abort
    let l:first = lsp#utils#utf16#byteidx(a:text, a:start)
    let l:last = a:0 ? lsp#utils#utf16#byteidx(a:text, a:start + a:1) : strlen(a:text)
    return strpart(a:text, l:first, l:last - l:first)
endfunction

function! lsp#utils#utf16#byteidx(text, units) abort
    let l:units = max([0, a:units])
    if exists('*utf16idx')
        let l:index = byteidxcomp(a:text, l:units, 1)
        return l:index < 0 ? strlen(a:text) : l:index
    endif
    return lsp#utils#utf16#_byteidx_fallback(a:text, l:units)
endfunction

" Keep the fallback callable for regression tests on Vim versions with native support.
" Early Vim 8 lacks str2list(). Splitting on \zs would merge composing marks.
function! lsp#utils#utf16#_codepoints_legacy(text) abort
    let l:characters = []
    let l:offset = 0
    let l:size = strlen(a:text)
    while l:offset < l:size
        " Bound strgetchar's rescan to 128 codepoints, including composing marks.
        let l:chunk = strcharpart(strpart(a:text, l:offset, 512), 0, 128)
        call extend(l:characters, map(range(strchars(l:chunk)), 'strgetchar(l:chunk, v:val)'))
        let l:offset += strlen(l:chunk)
    endwhile
    return l:characters
endfunction

function! lsp#utils#utf16#_length_fallback(text) abort
    let l:characters = exists('*str2list') ? str2list(a:text, 1)
        \ : lsp#utils#utf16#_codepoints_legacy(a:text)
    let l:length = len(l:characters)
    return l:length + len(filter(l:characters, 'v:val > 0xffff'))
endfunction

function! lsp#utils#utf16#_byteidx_fallback(text, units) abort
    let l:units = 0
    let l:bytes = 0
    let l:size = strlen(a:text)
    while l:bytes < l:size && l:units < a:units
        " Skip whole chunks with native list operations; decode only the final
        " at-most-128-codepoint chunk individually; read at most one extra chunk.
        let l:chunk = strcharpart(strpart(a:text, l:bytes, 512), 0, 128)
        let l:characters = exists('*str2list') ? str2list(l:chunk, 1)
            \ : lsp#utils#utf16#_codepoints_legacy(l:chunk)
        let l:width = len(l:characters) + len(filter(copy(l:characters), 'v:val > 0xffff'))
        if l:units + l:width <= a:units
            let l:units += l:width
            let l:bytes += strlen(l:chunk)
            continue
        endif
        for l:codepoint in l:characters
            let l:width = l:codepoint > 0xffff ? 2 : 1
            " An offset within a surrogate pair rounds down to the character start.
            if l:units + l:width > a:units
                return l:bytes
            endif
            let l:units += l:width
            let l:bytes += l:codepoint < 0x80 ? 1 : l:codepoint < 0x800 ? 2
                \ : l:codepoint < 0x10000 ? 3 : 4
        endfor
    endwhile
    return l:bytes
endfunction
