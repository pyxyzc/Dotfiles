" Validate every document before changing any buffer. No file is written to disk.
function! lsp#utils#workspace_edit#apply_workspace_edit(edit, ...) abort
    if type(a:edit) != type({})
        throw 'LSP: invalid workspace edit'
    endif
    let documents = has_key(a:edit, 'documentChanges') ? a:edit.documentChanges : []
    if !has_key(a:edit, 'documentChanges')
        for [uri, edits] in items(get(a:edit, 'changes', {}))
            call add(documents, {'textDocument': {'uri': uri}, 'edits': edits})
        endfor
    endif
    let targets = []
    let seen = {}
    for document in documents
        if type(document) != type({}) || has_key(document, 'kind')
                    \ || !has_key(document, 'textDocument') || !has_key(document, 'edits')
            throw 'LSP: file create/rename/delete operations are not supported'
        endif
        let uri = get(document.textDocument, 'uri', '')
        if !lsp#utils#is_file_uri(uri)
            throw 'LSP: only local file edits are supported'
        endif
        let path = resolve(lsp#utils#uri_to_path(uri))
        if has_key(seen, path)
            throw 'LSP: duplicate document edit: ' . path
        endif
        let seen[path] = 1
        let buffer = bufnr(path)
        if buffer < 0
            if !filereadable(path)
                throw 'LSP: edit target does not exist: ' . path
            endif
            execute 'silent badd ' . fnameescape(path)
            let buffer = bufnr(path)
        endif
        if exists('*bufload')
            call bufload(buffer)
        elseif !bufloaded(buffer)
            let load_origin = bufnr('%')
            let load_view = winsaveview()
            try
                execute 'noautocmd keepalt keepjumps hide buffer ' . buffer
            finally
                execute 'noautocmd keepalt keepjumps hide buffer ' . load_origin
                call winrestview(load_view)
            endtry
        endif
        if !getbufvar(buffer, '&modifiable') || getbufvar(buffer, '&readonly')
                    \ || getbufvar(buffer, '&buftype') !=# ''
            throw 'LSP: edit target is not editable: ' . path
        endif
        let document_version = get(document.textDocument, 'version', v:null)
        if document_version isnot v:null
            let current = a:0 ? lsp#get_document_version(a:1, buffer) : v:null
            if current is v:null || current != document_version
                throw 'LSP: stale document version: ' . path
            endif
        endif
        let lines = getbufline(buffer, 1, '$')
        let output = s:EditedLines(lines, document.edits)
        call add(targets, {'buffer': buffer, 'lines': lines, 'output': output,
                    \ 'modified': getbufvar(buffer, '&modified'),
                    \ 'tick': getbufvar(buffer, 'changedtick'), 'edits': len(document.edits)})
    endfor
    let origin = bufnr('%')
    let view = winsaveview()
    let changed = []
    try
        for target in targets
            if getbufvar(target.buffer, 'changedtick') != target.tick
                throw 'LSP: edit target changed during validation'
            endif
        endfor
        for target in targets
            if target.lines !=# target.output
                execute 'noautocmd keepalt keepjumps hide buffer ' . target.buffer
                " Break the undo sequence while preserving previous undo history.
                let &l:undolevels = &l:undolevels
                call add(changed, target)
                call s:SetLines(target.output)
            endif
        endfor
    catch
        let failure = v:exception
        for target in reverse(changed)
            execute 'noautocmd keepalt keepjumps hide buffer ' . target.buffer
            silent undo
            call setbufvar(target.buffer, '&modified', target.modified)
        endfor
        throw 'LSP: ' . failure
    finally
        if bufexists(origin)
            execute 'noautocmd keepalt keepjumps hide buffer ' . origin
            call winrestview(view)
        endif
    endtry
    return {'files': len(changed), 'edits': empty(targets) ? 0
                \ : eval(join(map(copy(targets), 'v:val.edits'), '+'))}
endfunction

function! s:SetLines(lines) abort
    let old_count = line('$')
    if setline(1, a:lines) != 0
        throw 'LSP: failed to replace buffer text'
    endif
    if old_count > len(a:lines)
        undojoin
        if exists('*deletebufline')
            if deletebufline(bufnr('%'), len(a:lines) + 1, '$') != 0
                throw 'LSP: failed to delete buffer lines'
            endif
        else
            execute (len(a:lines) + 1) . ',$delete _'
        endif
    endif
endfunction

function! s:PositionCompare(first, second) abort
    return a:first.line != a:second.line ? a:first.line - a:second.line
                \ : a:first.character - a:second.character
endfunction

function! s:EditCompare(first, second) abort
    return s:PositionCompare(a:first.range.start, a:second.range.start)
endfunction

function! s:CheckPosition(lines, position) abort
    if type(a:position) != type({}) || type(get(a:position, 'line', '')) != type(0)
                \ || type(get(a:position, 'character', '')) != type(0)
                \ || a:position.line < 0 || a:position.line > len(a:lines)
                \ || a:position.character < 0
        throw 'LSP: invalid text edit position'
    endif
    let text = get(a:lines, a:position.line, '')
    if a:position.character > lsp#utils#utf16#length(text)
        throw 'LSP: text edit position is outside the document'
    endif
    let byte = lsp#utils#utf16#byteidx(text, a:position.character)
    if lsp#utils#utf16#length(strpart(text, 0, byte)) != a:position.character
        throw 'LSP: text edit splits a UTF-16 character'
    endif
endfunction

function! s:EditedLines(lines, edits) abort
    if type(a:edits) != type([])
        throw 'LSP: invalid text edits'
    endif
    let edits = deepcopy(a:edits)
    for edit in edits
        if type(edit) != type({}) || !has_key(edit, 'range')
                    \ || type(get(edit, 'newText', 0)) != type('')
            throw 'LSP: invalid text edit'
        endif
        call s:CheckPosition(a:lines, get(edit.range, 'start', v:null))
        call s:CheckPosition(a:lines, get(edit.range, 'end', v:null))
        if s:PositionCompare(edit.range.start, edit.range.end) > 0
            throw 'LSP: reversed text edit range'
        endif
    endfor
    call sort(edits, function('s:EditCompare'))
    let previous = v:null
    for edit in edits
        if previous isnot v:null && s:PositionCompare(previous, edit.range.start) > 0
            throw 'LSP: overlapping text edits'
        endif
        let previous = edit.range.end
    endfor
    let lines = copy(a:lines)
    for edit in reverse(edits)
        let start = edit.range.start
        let end = edit.range.end
        let first = get(lines, start.line, '')
        let last = get(lines, end.line, '')
        let before = strpart(first, 0, lsp#utils#utf16#byteidx(first, start.character))
        let after = strpart(last, lsp#utils#utf16#byteidx(last, end.character))
        let replacement = split(edit.newText, '\r\?\n', 1)
        let replacement[0] = before . replacement[0]
        let replacement[-1] .= after
        if start.line == len(lines)
            if replacement[-1] ==# ''
                call remove(replacement, -1)
            endif
            let lines += replacement
        else
            if end.line == len(lines) && replacement[-1] ==# ''
                call remove(replacement, -1)
            endif
            let lines = (start.line > 0 ? lines[:start.line - 1] : [])
                        \ + replacement + (end.line + 1 < len(lines) ? lines[end.line + 1:] : [])
        endif
    endfor
    return empty(lines) ? [''] : lines
endfunction
