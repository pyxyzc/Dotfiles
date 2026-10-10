"""Project isolation, stale responses, quiet UI, and transactional LSP edits."""

import json

from test_lsp import LspFixture, WAIT, INDICATOR_PEER
from test_vim import ROOT, quoted


CONFIGURE = r'''
function! Configure(params) abort
  call lsp#send_request(lsp#get_allowed_servers()[0], {'method': 'test/configure',
        \ 'params': a:params, 'sync': 1})
endfunction
'''


DIAGNOSTIC_UI = WAIT + INDICATOR_PEER + r'''
function! Diagnostic(lnum, column, severity, message) abort
  return {'range': {'start': {'line': a:lnum - 1, 'character': a:column},
        \ 'end': {'line': a:lnum - 1, 'character': a:column + 1}},
        \ 'severity': a:severity, 'message': a:message}
endfunction
function! PublishDiagnostics(items) abort
  let server = lsp#get_allowed_servers()[0]
  let uri = lsp#utils#get_buffer_uri()
  call PeerNotify(server, 'textDocument/publishDiagnostics',
        \ {'uri': uri, 'diagnostics': a:items})
  call WaitFor({-> get(get(get(
        \ lsp#internal#diagnostics#state#_get_all_diagnostics_grouped_by_server_for_uri(uri),
        \ server, {}), 'params', {}), 'diagnostics', []) ==# a:items})
endfunction
function! AssertDiagnosticPopup(side) abort
  redraw
  call assert_equal(1, len(popup_list()))
  if empty(popup_list())
    return {}
  endif
  let position = popup_getpos(popup_list()[0])
  let window = getwininfo(win_getid())[0]
  let row = window.winrow + winline() - 1
  call assert_true(position.visible)
  call assert_true(position.line >= window.winrow, string(position))
  call assert_true(position.line + position.height <= window.winrow + window.height,
        \ string(position))
  call assert_true(position.col >= window.wincol, string(position))
  call assert_true(position.col + position.width <= window.wincol + window.width,
        \ string(position))
  call assert_true(position.core_width <= 72)
  call assert_true(position.core_height <= 10)
  let above = position.line + position.height - 1 < row
  let below = position.line > row
  call assert_true(above || below, 'popup covered target row: ' . string(position))
  if a:side ==# 'above'
    call assert_true(above, string(position))
  elseif a:side ==# 'below'
    call assert_true(below, string(position))
  endif
  return position
endfunction
'''


class LspBehaviorTests(LspFixture):
    def configured(self, config):
        path = self.work / 'responses.json'
        path.write_text(json.dumps(config), encoding='utf-8')
        return self.settings + ['let g:vimrc_lite_lsp_pyright_cmd = '
                                + json.dumps(self.command + ['--response-config', str(path)])]

    def test_two_projects_stop_start_restart_reload_and_unsaved_buffers(self):
        project = self.work / 'second project'
        project.mkdir()
        (project / '.git').mkdir()
        source = project / 'second.py'
        source.write_text('target\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let cwd = getcwd()
let first = bufnr('%')
call setline(1, 'target + unsaved')
let g:first_server = lsp#get_allowed_servers()[0]
execute 'vsplit ' . fnameescape(''' + quoted(source) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let second = bufnr('%')
let saved_omnifunc = b:vimrc_lite_lsp_saved.omnifunc
let g:second_server = lsp#get_allowed_servers()[0]
call assert_notequal(g:first_server, g:second_server)
call assert_equal(''' + quoted(project.as_uri()) + r''', lsp#get_server_root_uri(g:second_server))
call assert_equal([g:second_server], lsp#get_allowed_servers(second))
call assert_equal([g:first_server], lsp#get_allowed_servers(first))
let saved_command = copy(g:vimrc_lite_lsp_pyright_cmd)
let g:vimrc_lite_lsp_pyright_cmd = ['/missing-new-command']
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal([g:second_server], lsp#get_allowed_servers(second))
call assert_true(lsp#is_server_running(g:second_server), 'reload interrupted the running command')
let g:vimrc_lite_lsp_pyright_cmd = saved_command
VimLspStop
call WaitFor({-> !lsp#is_server_running(g:second_server)})
call assert_equal(saved_omnifunc, &omnifunc)
call assert_equal('', maparg('gd', 'n'))
execute 'buffer ' . first
execute 'buffer ' . second
source ''' + str(ROOT / '.vimrc') + r'''
sleep 100m
call assert_equal([], lsp#get_allowed_servers())
call assert_true(lsp#is_server_running(g:first_server))
VimLspStart
VimLspStop
sleep 100m
call assert_false(lsp#is_server_running(g:second_server), 'pending start escaped a newer stop')
VimLspStart
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let g:vimrc_lite_lsp_pyright_cmd += ['new-setting']
source ''' + str(ROOT / '.vimrc') + r'''
call assert_true(lsp#is_server_running(g:second_server))
VimLspRestart
call WaitFor({-> &omnifunc ==# 'lsp#complete' && lsp#is_server_running(g:second_server)})
call assert_true(lsp#is_server_running(g:first_server))
call assert_equal('target + unsaved', getbufline(first, 1)[0])
call assert_true(getbufvar(first, '&modified'))
call assert_equal(cwd, getcwd())
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)
        starts = self.messages('_start')
        self.assertEqual(4, len(starts))
        self.assertIn('new-setting', starts[-1]['argv'])
        roots = [m['params']['rootUri'] for m in self.messages('initialize')]
        self.assertEqual(1, roots.count(self.project.as_uri()))
        self.assertEqual(3, roots.count(project.as_uri()))
        instance_roots = {m['_pid']: m['params']['rootUri'] for m in self.messages('initialize')}
        for message in self.messages('textDocument/didOpen'):
            self.assertTrue(message['params']['textDocument']['uri'].startswith(
                instance_roots[message['_pid']] + '/'), 'document broadcast across project roots')

    def test_preview_does_not_start_a_new_project_until_confirmation(self):
        project = self.work / 'preview project'
        project.mkdir()
        (project / '.git').mkdir()
        target = project / 'outside.py'
        target.write_text('target\n')
        command = self.command.copy()
        command[command.index('--target') + 1] = str(target)
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = bufnr('%')
VimLspReferences
call WaitFor({-> &buftype ==# 'quickfix'})
let index = index(map(getqflist(), 'bufname(v:val.bufnr)'), ''' + quoted(target) + r''')
call cursor(index + 1, 1)
doautocmd CursorMoved
sleep 150m
call assert_equal(['pyright'], lsp#get_server_names())
call assert_equal(origin, getqflist({'context': 0}).context.vimrc_lite_lsp_references.buffer)
call feedkeys("\<CR>", 'xt')
call WaitFor({-> len(lsp#get_server_names()) == 2 && &omnifunc ==# 'lsp#complete'})
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_equal(0, getqflist({'winid': 0}).winid)
call feedkeys("\<C-o>", 'xt')
call assert_equal(origin, bufnr('%'))
''', args=[str(self.source)], before=self.settings + [
            'let g:vimrc_lite_lsp_pyright_cmd = ' + json.dumps(command)])
        self.assertEqual(2, len(self.messages('_start')))

    def test_delayed_requests_cancel_on_move_edit_tab_and_source_close(self):
        self.terminal_vim(WAIT + CONFIGURE + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = bufnr('%')
call setqflist([], ' ', {'items': [{'bufnr': origin, 'lnum': 1}], 'title': 'keep'})
let list = getqflist({'id': 0}).id
VimLspDefinition
call cursor(1, 4)
doautocmd CursorMoved
sleep 250m
call assert_equal(origin, bufnr('%'))
call assert_equal(list, getqflist({'id': 0}).id)
VimLspFormat
call setline(1, 'target changed')
doautocmd TextChanged
sleep 250m
call assert_equal('target changed', getline(1))
VimLspHover
tabnew
sleep 250m
call assert_equal(0, lsp#document_hover_preview_winid())
tabclose
VimLspReferences
execute 'bwipeout! ' . origin
sleep 250m
call assert_equal(0, getqflist({'winid': 0}).winid)
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured({'delay_ms': {
            'textDocument/definition': 120, 'textDocument/formatting': 120,
            'textDocument/hover': 120, 'textDocument/references': 120}}))
        self.assertGreaterEqual(len(self.messages('$/cancelRequest')), 3)

    def test_timeout_replacement_and_independent_operations(self):
        self.terminal_vim(WAIT + CONFIGURE + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = bufnr('%')
let g:vimrc_lite_lsp_request_timeout_ms = 35
VimLspDefinition
sleep 200m
call assert_equal(origin, bufnr('%'))
call assert_match('timed out: textDocument/definition', execute('messages'))
let g:vimrc_lite_lsp_request_timeout_ms = 1000
VimLspHover
VimLspSignature
call WaitFor({-> lsp#document_hover_preview_winid() > 0})
sleep 180m
call assert_match('target: int', join(getbufline(winbufnr(lsp#document_hover_preview_winid()), 1, '$')))
call popup_clear()
VimLspReferences
call Configure({'delay_ms': {'textDocument/references': 10}})
VimLspReferences
call WaitFor({-> &buftype ==# 'quickfix'})
let list = getqflist({'id': 0}).id
sleep 200m
call assert_equal(list, getqflist({'id': 0}).id)
call feedkeys('q', 'xt')
call assert_equal(origin, bufnr('%'))
''', args=[str(self.source)], before=self.configured({'delay_ms': {
            'textDocument/definition': 120, 'textDocument/hover': 100,
            'textDocument/signatureHelp': 40, 'textDocument/references': 150}}))
        self.assertEqual(2, len(self.messages('textDocument/references')))

    def test_quiet_diagnostics_cache_details_navigation_and_location_list(self):
        self.terminal_vim(WAIT + INDICATOR_PEER + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, ['target', 'other', 'last'])
let uri = lsp#utils#get_buffer_uri()
let diagnostics = [{'range': {'start': {'line': 0, 'character': 0},
      \ 'end': {'line': 0, 'character': 1}}, 'severity': 1, 'message': 'first',
      \ 'source': 'mock', 'code': 7},
      \ {'range': {'start': {'line': 2, 'character': 1},
      \ 'end': {'line': 2, 'character': 3}}, 'severity': 2, 'message': 'last'}]
call PeerNotify('pyright', 'textDocument/publishDiagnostics',
      \ {'uri': uri, 'diagnostics': diagnostics})
call WaitFor({-> len(sign_getplaced(bufnr('%'), {'group': 'vim_lsp'})[0].signs) == 2})
call assert_equal(0, g:lsp_diagnostics_virtual_text_enabled)
call assert_equal(0, g:lsp_diagnostics_float_cursor)
call assert_equal([], popup_list())
call cursor(2, 1)
let origin = win_getid()
call feedkeys(']d', 'xt')
call assert_equal([3, 2], [line('.'), col('.')])
call assert_equal(origin, win_getid())
call assert_equal(1, len(popup_list()))
call assert_equal('Warning', getbufline(winbufnr(popup_list()[0]), 1)[0])
call assert_equal('VimLspDiagnosticWarn',
      \ prop_list(1, {'bufnr': winbufnr(popup_list()[0])})[0].type)
call assert_equal([], prop_list(2, {'bufnr': winbufnr(popup_list()[0])}))
call assert_match('last', join(getbufline(winbufnr(popup_list()[0]), 1, '$')))
doautocmd CursorMoved
call assert_equal(1, len(popup_list()), 'jump event closed the new popup')
call feedkeys('2]d', 'xt')
call assert_equal([3, 2], [line('.'), col('.')])
call assert_equal(1, len(popup_list()), 'counted jump left extra popups')
call feedkeys('[d', 'xt')
call assert_equal([1, 1], [line('.'), col('.')])
call assert_match('first', join(getbufline(winbufnr(popup_list()[0]), 1, '$')))
VimLspDiagnosticDetails
call assert_true(lsp#document_hover_preview_winid() > 0)
call assert_match('first', join(getbufline(winbufnr(lsp#document_hover_preview_winid()), 1, '$')))
call popup_clear()
VimLspDiagnostics
call WaitFor({-> empty(sign_getplaced(bufnr('%'), {'group': 'vim_lsp'})[0].signs)})
call assert_equal([], sign_getplaced(bufnr('%'), {'group': 'vim_lsp'})[0].signs)
VimLspDiagnosticList
call assert_equal(2, len(getloclist(0)))
call assert_true(getwininfo(win_getid())[0].loclist)
call cursor(2, 1)
doautocmd CursorMoved
call feedkeys("\<CR>", 'xt')
call assert_equal([3, 2], [line('.'), col('.')])
call assert_equal(0, getloclist(0, {'winid': 0}).winid)
VimLspDiagnostics
call WaitFor({-> len(sign_getplaced(bufnr('%'), {'group': 'vim_lsp'})[0].signs) == 2})
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)

    def test_diagnostic_popup_order_theme_multiline_and_repeated_jumps(self):
        self.terminal_vim(DIAGNOSTIC_UI + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, repeat(['abcdefgh 中文🙂'], 60))
let error = Diagnostic(15, 0, 1, "严重报错\n第二行 中文🙂\n")
let error.source = 'pyright'
let error.code = 'reportArgumentType'
let warning = Diagnostic(15, 4, 2, "当前警告\n另一行说明")
let warning.source = 'mock'
let warning.code = 7
call PublishDiagnostics([warning, Diagnostic(15, 2, 4, 'hint message'),
      \ Diagnostic(15, 6, 3, 'info message'), error, Diagnostic(30, 0, 1, 'next line')])
setlocal scrolloff=0
call cursor(14, 1)
silent normal! zz
let origin = win_getid()
let windows = winnr('$')
call feedkeys(']d', 'xt')
call assert_equal([15, 1], [line('.'), col('.')])
call AssertDiagnosticPopup('above')
let popup = popup_list()[0]
let options = popup_getoptions(popup)
call assert_equal('', options.title)
call assert_equal(repeat(['VimLspDiagnosticBorder'], 4), options.borderhighlight)
call assert_equal(['─', '│', '─', '│', '╭', '╮', '╯', '╰'], options.borderchars)
call assert_equal('VimLspDiagnosticNormal', options.highlight)
call assert_equal(hlID('NormalFloat'), synIDtrans(hlID('VimLspDiagnosticNormal')))
call assert_equal(hlID('DiagnosticError'), synIDtrans(hlID('VimLspDiagnosticError')))
let lines = getbufline(winbufnr(popup), 1, '$')
call assert_equal(['Error · pyright (4)', '严重报错', '第二行 中文🙂', '',
      \ 'reportArgumentType', '', 'Warning · mock', '当前警告', '另一行说明', '', '7', '',
      \ 'Info', 'info message', '', 'Hint', 'hint message'], lines)
call assert_equal('VimLspDiagnosticError',
      \ prop_list(1, {'bufnr': winbufnr(popup)})[0].type)
call assert_equal(strlen('Error · pyright'), prop_list(1, {'bufnr': winbufnr(popup)})[0].length)
let position = popup_getpos(popup)
let border = screenattr(position.line, position.col)
call assert_equal(border, screenattr(position.line, position.col + 2))
call assert_equal(border, screenattr(position.line + 1, position.col))
call assert_equal(border, screenattr(position.line + position.height - 1, position.col))
call assert_notequal(border, screenattr(position.core_line, position.core_col),
      \ 'severity label must have its own color')
call assert_equal(screenattr(position.core_line, position.core_col + 17),
      \ screenattr(position.core_line + 1, position.core_col),
      \ 'diagnostic count must keep the normal text color')
call assert_equal('VimLspDiagnosticDetail',
      \ prop_list(5, {'bufnr': winbufnr(popup)})[0].type)
call feedkeys('2]d', 'xt')
call assert_equal([15, 5], [line('.'), col('.')])
call AssertDiagnosticPopup('above')
let popup = popup_list()[0]
call assert_equal('', popup_getoptions(popup).title)
call assert_equal(repeat(['VimLspDiagnosticBorder'], 4), popup_getoptions(popup).borderhighlight)
call assert_equal('Warning · mock (4)', getbufline(winbufnr(popup), 1)[0])
call assert_equal('VimLspDiagnosticWarn', prop_list(1, {'bufnr': winbufnr(popup)})[0].type)
call feedkeys(']d]d[d[d', 'xt')
call assert_equal([15, 5], [line('.'), col('.')])
call assert_equal(1, len(popup_list()))
call assert_match('当前警告', join(getbufline(winbufnr(popup_list()[0]), 1, '$')))
call assert_equal(origin, win_getid())
call assert_equal(windows, winnr('$'))
VimLspDiagnostics
call feedkeys(']d', 'xt')
call assert_equal([15, 7], [line('.'), col('.')])
call assert_equal(1, len(popup_list()), 'hidden decorations disabled diagnostic details')
call feedkeys("\<Esc>", 'xt')
call assert_equal([], popup_list())
call feedkeys('[d', 'xt')
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(origin, win_getid())
VimLspDiagnosticDetails
call AssertDiagnosticPopup('')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)
        self.assertEqual([], self.messages('textDocument/hover'))
        self.assertEqual([], self.messages('textDocument/diagnostic'))

    def test_diagnostic_popup_bounds_scrollbar_folds_wrapping_and_splits(self):
        self.terminal_vim(DIAGNOSTIC_UI + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, repeat(['target ' . repeat('中文🙂 ', 25) . ' tail'], 80))
call PublishDiagnostics([Diagnostic(20, 70, 1, repeat("长消息 中文🙂\n", 30)),
      \ Diagnostic(55, 0, 2, 'bottom warning')])
setlocal scrolloff=0 sidescrolloff=0
call cursor(19, 1)
silent normal! zt
call feedkeys(']d', 'xt')
call assert_equal(20, line('.'))
call AssertDiagnosticPopup('below')
call assert_true(popup_getpos(popup_list()[0]).scrollbar)
silent normal! zb
redraw
let view = winsaveview()
VimLspDiagnosticDetails
call AssertDiagnosticPopup('above')
call assert_equal(view, winsaveview(), 'manual details scrolled the source')
vsplit
vertical resize 25
VimLspDiagnosticDetails
call AssertDiagnosticPopup('')
vertical resize 12
VimLspDiagnosticDetails
call AssertDiagnosticPopup('')
setlocal ambiwidth=double
VimLspDiagnosticDetails
call assert_equal(['-', '|', '-', '|', '+', '+', '+', '+'],
      \ popup_getoptions(popup_list()[0]).borderchars)
setlocal ambiwidth=single
setlocal wrap linebreak
VimLspDiagnosticDetails
call AssertDiagnosticPopup('')
only
setlocal nowrap foldmethod=manual
20,28fold
call cursor(19, 1)
silent normal! zz
call assert_equal(20, foldclosed(20))
call feedkeys(']d', 'xt')
call assert_equal(-1, foldclosed(20))
call AssertDiagnosticPopup('')
split
resize 8
VimLspDiagnosticDetails
call AssertDiagnosticPopup('')
call cursor(55, 1)
silent normal! zb
VimLspDiagnosticDetails
call AssertDiagnosticPopup('above')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)

    def test_diagnostic_popup_lifetime_and_quiet_cursor_movement(self):
        self.terminal_vim(DIAGNOSTIC_UI + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, repeat(['target diagnostic'], 60))
call PublishDiagnostics([Diagnostic(15, 0, 1, 'diagnostic details')])
let mouse = &mouse
call cursor(14, 1)
call feedkeys(']d', 'xt')
call AssertDiagnosticPopup('')
call assert_match('[an]', &mouse, 'diagnostic scrollbar cannot receive mouse input')
call feedkeys('l', 'xt')
" :source 内的 feedkeys 不进入正常的事件循环，显式派发移动事件。
doautocmd CursorMoved
call assert_equal([], popup_list())
call assert_equal(mouse, &mouse, 'closing diagnostics changed mouse preference')
call feedkeys('h', 'xt')
doautocmd CursorMoved
call assert_equal([], popup_list(), 'ordinary cursor motion opened diagnostics')
VimLspDiagnosticDetails
call feedkeys("i\<Esc>", 'xt')
call assert_equal([], popup_list(), 'entering insert mode kept the popup')
VimLspDiagnosticDetails
call setline(15, 'target changed')
doautocmd TextChanged
call assert_equal([], popup_list())
VimLspDiagnosticDetails
vsplit
call assert_equal([], popup_list())
VimLspDiagnosticDetails
tab split
call assert_equal([], popup_list())
tabclose
VimLspDiagnosticDetails
call feedkeys("\<C-e>", 'xt')
doautocmd WinScrolled
call assert_equal([], popup_list(), 'source scrolling left an unanchored popup')
VimLspDiagnosticDetails
doautocmd VimResized
call assert_equal([], popup_list())
sleep 30m
call assert_equal([], popup_list(), 'closed diagnostic popup reappeared')
VimLspDiagnosticDetails
set mouse=a
call feedkeys("\<Esc>", 'xt')
call assert_equal('a', &mouse, 'popup close discarded a newer mouse setting')
let &mouse = mouse
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)

    def test_diagnostic_jump_without_float_keeps_layout_and_manual_preview(self):
        self.terminal_vim(DIAGNOSTIC_UI + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, repeat(['target diagnostic'], 30))
call PublishDiagnostics([Diagnostic(15, 0, 1, repeat('中文🙂', 100) . "\nsecond line")])
let origin = win_getid()
let windows = winnr('$')
call feedkeys(']d', 'xt')
call assert_equal([15, 1], [line('.'), col('.')])
call assert_equal(origin, win_getid())
call assert_equal(windows, winnr('$'))
call assert_equal([], popup_list())
let message = trim(execute('LspNextDiagnostic'))
call assert_true(strdisplaywidth(message) <= &columns - 12, message)
call assert_match('中文🙂', message)
VimLspDiagnosticDetails
call assert_equal(origin, win_getid())
call assert_equal(windows + 1, winnr('$'))
let preview = lsp#document_hover_preview_winid()
call assert_true(preview > 0)
call assert_equal(1, getwinvar(preview, '&previewwindow'))
call assert_match('second line', join(getbufline(winbufnr(preview), 1, '$')))
call feedkeys('j', 'xt')
doautocmd CursorMoved
call assert_equal(windows, winnr('$'))
call assert_equal(0, lsp#document_hover_preview_winid())
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings + ['let g:lsp_preview_float = 0'])

    def test_hover_second_key_enters_cached_document_and_manual_signature_symbols(self):
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = win_getid()
call feedkeys('K', 'xt')
call WaitFor({-> lsp#document_hover_preview_winid() > 0})
call feedkeys('K', 'xt')
call assert_notequal(origin, win_getid())
call assert_equal('nofile', &buftype)
call assert_false(&modifiable)
call assert_match('target: int', getline(1))
call feedkeys("/target\<CR>", 'xt')
call feedkeys('q', 'xt')
call assert_equal(origin, win_getid())
VimLspSignature
call WaitFor({-> lsp#document_hover_preview_winid() > 0})
call assert_match('second: str', join(getbufline(winbufnr(lsp#document_hover_preview_winid()), 1, '$')))
call popup_clear()
VimLspWorkspaceSymbols target
call WaitFor({-> &buftype ==# 'quickfix'})
call assert_equal(1, len(getqflist()))
call feedkeys('q', 'xt')
call assert_equal(origin, win_getid())
VimLspImplementation
call WaitFor({-> &buftype ==# 'quickfix'})
call assert_equal(1, len(getqflist()))
call feedkeys('q', 'xt')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)
        self.assertEqual(1, len(self.messages('textDocument/hover')))
        self.assertEqual(1, len(self.messages('textDocument/signatureHelp')))

    def test_workspace_edit_preflight_version_unicode_undo_and_focus(self):
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = bufnr('%')
let window = win_getid()
let view = winsaveview()
let edit = {'range': {'start': {'line': 0, 'character': 0},
      \ 'end': {'line': 0, 'character': 0}}, 'newText': '# added\n'}
let edit.newText = "# added\n"
let uri = lsp#utils#get_buffer_uri()
let other = ''' + quoted(self.target.as_uri()) + r'''
execute 'badd ' . fnameescape(''' + quoted(self.target) + r''')
let target = bufnr(''' + quoted(self.target) + r''')
call bufload(target)
call setbufvar(target, '&readonly', 1)
let original = getline(1, '$')
try
  call lsp#utils#workspace_edit#apply_workspace_edit({'changes': {uri: [edit], other: [edit]}}, 'pyright')
  call assert_false(1, 'readonly edit should be rejected')
catch /not editable/
endtry
call assert_equal(original, getline(1, '$'))
call setbufvar(target, '&readonly', 0)
try
  call lsp#utils#workspace_edit#apply_workspace_edit({'documentChanges': [
        \ {'textDocument': {'uri': uri, 'version': 999}, 'edits': [edit]}]}, 'pyright')
  call assert_false(1, 'stale version should be rejected')
catch /stale document version/
endtry
try
  call lsp#utils#workspace_edit#apply_workspace_edit({'documentChanges': [
        \ {'textDocument': {'uri': uri}, 'edits': [edit]}, {'kind': 'delete', 'uri': other}]})
  call assert_false(1, 'resource operations should reject the entire edit')
catch /not supported/
endtry
call assert_equal(original, getline(1, '$'))
let result = lsp#utils#workspace_edit#apply_workspace_edit(
      \ {'changes': {uri: [edit], other: [edit]}}, 'pyright')
call assert_equal({'files': 2, 'edits': 2}, result)
call assert_equal(origin, bufnr('%'))
call assert_equal(window, win_getid())
call assert_equal(view, winsaveview())
call assert_equal('# added', getline(1))
call assert_equal('# added', getbufline(target, 1)[0])
undo
call assert_equal(original, getline(1, '$'))
execute 'hide buffer ' . target
undo
call assert_equal(''' + quoted(self.prefix + 'target = 42') + r''', getline(1))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)
        self.assertEqual(self.source.read_text(), self.prefix + 'target\n')
        self.assertEqual(self.target.read_text(), self.prefix + 'target = 42\n')

    def test_prepare_rename_resolve_code_action_and_unicode_selection(self):
        edit = {'changes': {self.source.as_uri(): [{
            'range': {'start': {'line': 0, 'character': 0},
                      'end': {'line': 0, 'character': 0}}, 'newText': '# resolved\n'}]}}
        self.terminal_vim(WAIT + CONFIGURE + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call cursor(1, ''' + str(len(self.prefix.encode()) + 1) + r''')
function! AnswerRename(timer) abort
  if getcmdtype() ==# '@'
    call feedkeys("\<C-u>renamed\<CR>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('AnswerRename'), {'repeat': -1})
VimLspRename
call WaitFor({-> getline(1) =~# 'renamed'})
call Configure({'results': {'textDocument/prepareRename': v:null}})
VimLspRename
sleep 100m
call assert_match('cannot be renamed', execute('messages'))
call setline(1, ['aa中🙂target', 'second'])
call setpos("'<", [0, 1, 3, 0])
call setpos("'>", [0, 1, 6, 0])
call VimLspSelection('format', 'v')
call WaitFor({-> getline(1) ==# '# formatted'})
call VimLspSelection('format', "\<C-v>")
call assert_match('block selections are not supported', execute('messages'))
call Configure(json_decode(''' + quoted(json.dumps({'results': {
            'textDocument/codeAction': [{'title': 'Resolve action', 'data': 1}],
            'codeAction/resolve': {'title': 'Resolve action', 'edit': edit}}})) + r'''))
VimLspCodeAction
call WaitFor({-> !empty(popup_list())})
call popup_filter_menu(popup_list()[0], "\<CR>")
call WaitFor({-> getline(1) ==# '# resolved'})
call assert_true(&modified)
call assert_equal(0, getqflist({'winid': 0}).winid)
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured({
            'capabilities': {'renameProvider': {'prepareProvider': True},
                             'codeActionProvider': {'resolveProvider': True}},
            'results': {'textDocument/codeAction': [{'title': 'Resolve action', 'data': 1}],
                        'codeAction/resolve': {'title': 'Resolve action', 'edit': edit}}}))
        self.assertEqual(1, len(self.messages('textDocument/rename')))
        self.assertEqual(1, len(self.messages('codeAction/resolve')))
        capabilities = self.messages('initialize')[0]['params']['capabilities']
        self.assertTrue(capabilities['textDocument']['codeAction']['dataSupport'])
        self.assertTrue(capabilities['workspace']['workspaceEdit']['documentChanges'])
        self.assertIn('documentation', capabilities['textDocument']['completion'][
            'completionItem']['resolveSupport']['properties'])
        self.assertEqual({'start': {'line': 0, 'character': 2},
                          'end': {'line': 0, 'character': 5}},
                         self.messages('textDocument/rangeFormatting')[0]['params']['range'])

    def test_semantic_completion_owns_menu_sorts_resolves_and_applies_once(self):
        additional = {'range': {'start': {'line': 0, 'character': 0},
                                 'end': {'line': 0, 'character': 0}}, 'newText': '# resolved\n'}
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, 'tar')
call cursor(1, 3)
let g:phase = 0
let g:polls = 0
function! PickResolved(timer) abort
  let g:polls += 1
  if g:phase == 0 && pumvisible()
    call assert_equal('lsp', b:vimrc_lite_completion_owner)
    " complete_info() 的循环列表顺序可能与可见菜单不同，直接核对用户看到的第一项。
    call assert_equal(['targB', 'target'],
          \ sort(map(complete_info(['items']).items, 'v:val.word')))
    redraw
    let menu = pum_getpos()
    let text = join(map(range(menu.col + 1, menu.col + menu.width),
          \ 'screenstring(menu.row + 1, v:val)'), '')
    call assert_match('^\s*target\s', text)
    call feedkeys("\<C-n>", 't')
    let g:phase = 1
  elseif g:phase == 1 && pumvisible()
    let info = complete_info(['items', 'selected'])
    if info.selected >= 0
      let data = lsp#omni#get_managed_user_data_from_completed_item(info.items[info.selected])
      if get(data, 'resolved', 0)
        call assert_match('Resolved docs', string(data.completion_item.documentation))
        call feedkeys("\<C-y>", 't')
        let g:phase = 2
      endif
    endif
  elseif g:phase == 2 && getline(1) ==# '# resolved'
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
  if g:polls > 150
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(20, function('PickResolved'), {'repeat': -1})
call feedkeys("A\<C-x>\<C-o>", 'xt!')
call assert_equal(2, g:phase)
call assert_equal(['# resolved', 'target'], getline(1, '$'))
call assert_equal('', get(b:, 'vimrc_lite_completion_owner', ''))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured({
            'capabilities': {'completionProvider': {'resolveProvider': True}},
            'results': {'textDocument/completion': [
                {'label': 'targB', 'sortText': '2', 'kind': 6},
                {'label': 'target', 'sortText': '1', 'kind': 6}],
                'completionItem/resolve': {'label': 'target', 'kind': 6,
                                          'documentation': {'kind': 'markdown', 'value': 'Resolved docs'},
                                          'additionalTextEdits': [additional]}}}))
        self.assertEqual(1, len(self.messages('completionItem/resolve')))

    def test_diagnostics_preserve_decorations_in_insert_and_reject_old_versions(self):
        self.terminal_vim(WAIT + INDICATOR_PEER + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let g:source = bufnr('%')
let g:uri = lsp#utils#get_buffer_uri()
call WaitFor({-> len(sign_getplaced(g:source, {'group': 'vim_lsp'})[0].signs) == 1})
let g:insert_phase = 0
let g:polls = 0
function! ProbeDiagnostics(timer) abort
  let g:polls += 1
  if mode()[0] ==# 'i' && g:insert_phase == 0
    call PeerNotify('pyright', 'textDocument/publishDiagnostics',
          \ {'uri': g:uri, 'diagnostics': []})
    let g:insert_phase = 1
  elseif mode()[0] ==# 'i' && g:insert_phase == 1 && g:polls > 10
    call assert_equal(1, len(sign_getplaced(g:source, {'group': 'vim_lsp'})[0].signs))
    let g:insert_phase = 2
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(20, function('ProbeDiagnostics'), {'repeat': -1})
call feedkeys('i', 'xt!')
call assert_equal(2, g:insert_phase)
call WaitFor({-> empty(sign_getplaced(g:source, {'group': 'vim_lsp'})[0].signs)})
call PeerNotify('pyright', 'textDocument/publishDiagnostics', {'uri': g:uri, 'version': 0,
      \ 'diagnostics': [{'range': {'start': {'line': 0, 'character': 0},
      \ 'end': {'line': 0, 'character': 1}}, 'severity': 1, 'message': 'stale'}]})
sleep 120m
call assert_equal([], sign_getplaced(g:source, {'group': 'vim_lsp'})[0].signs)
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)

    def test_single_definition_in_dirty_current_buffer_keeps_existing_quickfix(self):
        target = {'uri': self.source.as_uri(), 'range': {
            'start': {'line': 1, 'character': 0}, 'end': {'line': 1, 'character': 6}}}
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, ['call target', 'target = 42'])
call cursor(1, 6)
let origin = bufnr('%')
call setqflist([], ' ', {'items': [{'bufnr': origin, 'lnum': 1}], 'title': 'keep'})
let list = getqflist({'id': 0}).id
LspDefinition
call WaitFor({-> line('.') == 2})
call assert_equal(origin, bufnr('%'))
call assert_true(&modified)
call assert_equal(list, getqflist({'id': 0}).id)
call assert_equal(0, getqflist({'winid': 0}).winid)
call feedkeys("\<C-o>", 'xt')
call assert_equal([1, 6], [line('.'), col('.')])
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured({
            'results': {'textDocument/definition': [target, target]}}))

    def test_canceled_resolve_does_not_edit_and_empty_completion_releases_menu(self):
        self.terminal_vim(WAIT + CONFIGURE + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, 'tar')
call cursor(1, 3)
let g:phase = 0
let g:polls = 0
function! CancelResolved(timer) abort
  let g:polls += 1
  if g:phase == 0 && pumvisible()
    call feedkeys("\<C-n>", 't')
    let g:phase = 1
  elseif g:phase == 1 && g:polls > 7
    call feedkeys("\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(20, function('CancelResolved'), {'repeat': -1})
call feedkeys("A\<C-x>\<C-o>", 'xt!')
sleep 250m
call assert_equal(['tar'], getline(1, '$'))
call Configure({'results': {'textDocument/completion': []}})
let g:released = 0
function! EmptyCompletion(timer) abort
  if mode()[0] ==# 'i' && get(b:, 'vimrc_lite_completion_owner', '') ==# ''
    let g:released = 1
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(30, function('EmptyCompletion'), {'repeat': -1})
call feedkeys("A\<C-x>\<C-o>", 'xt!')
call assert_equal(1, g:released)
call assert_equal(['tar'], getline(1, '$'))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured({
            'capabilities': {'completionProvider': {'resolveProvider': True}},
            'delay_ms': {'completionItem/resolve': 250},
            'results': {'completionItem/resolve': {'label': 'target', 'kind': 6,
                'documentation': {'kind': 'markdown', 'value': 'late'},
                'additionalTextEdits': [{'range': {'start': {'line': 0, 'character': 0},
                                                  'end': {'line': 0, 'character': 0}},
                                         'newText': '# must not appear\n'}]}}}))
        self.assertEqual(1, len(self.messages('completionItem/resolve')))

    def test_server_workspace_edit_reports_failure_without_partial_changes(self):
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let original = getline(1, '$')
let uri = lsp#utils#get_buffer_uri()
let edit = {'documentChanges': [
      \ {'textDocument': {'uri': uri}, 'edits': [{'range': {
      \ 'start': {'line': 0, 'character': 0}, 'end': {'line': 0, 'character': 0}},
      \ 'newText': 'must not appear'}]}, {'kind': 'delete', 'uri': uri}]}
call lsp#send_request('pyright', {'method': 'test/notify', 'params': {
      \ 'id': 9091, 'method': 'workspace/applyEdit', 'params': {'edit': edit}}})
sleep 100m
call assert_equal(original, getline(1, '$'))
call assert_false(&modified)
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings)
        replies = [m for m in self.messages() if m.get('id') == 9091 and 'result' in m]
        self.assertEqual(1, len(replies))
        self.assertFalse(replies[0]['result']['applied'])
        self.assertIn('not supported', replies[0]['result']['failureReason'])

    def test_project_diagnostics_include_other_languages_with_the_same_root(self):
        cpp = self.source_dir / 'mixed.cpp'
        cpp.write_text('int target;\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
let origin = win_getid()
execute 'vsplit ' . fnameescape(''' + quoted(cpp) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call WaitFor({-> !empty(lsp#internal#diagnostics#state#_get_all_diagnostics_grouped_by_server_for_uri(
      \ lsp#utils#get_buffer_uri()))})
call win_gotoid(origin)
VimLspDiagnosticList!
call assert_equal('quickfix', &buftype)
call assert_equal(2, len(getqflist()))
let files = sort(map(getqflist(), 'fnamemodify(bufname(v:val.bufnr), ":p")'))
call assert_equal(sort([''' + quoted(cpp) + ', ' + quoted(self.source) + r''']), files)
call feedkeys('q', 'xt')
call assert_equal(origin, win_getid())
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings + [
            'let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps(self.command)])
