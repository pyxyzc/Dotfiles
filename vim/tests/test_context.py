"""Statusline scopes use cached document ranges without floating windows."""

import json
import shutil
import unittest

from test_lsp import LspFixture, WAIT
from test_lsp_behaviors import CONFIGURE
from test_vim import ROOT, VimSession, quoted


HELPERS = WAIT + CONFIGURE + r'''
function! ContextLabel(window) abort
  call win_execute(a:window, 'let w:context_test_label = VimContextLabel()')
  return getwinvar(a:window, 'context_test_label', '')
endfunction
function! ContextView(cursor, top) abort
  setlocal scrolloff=0
  call cursor(a:cursor, 1)
  let view = winsaveview()
  let view.topline = a:top
  call winrestview(view)
  redraw
endfunction
function! AssertContext(label) abort
  call WaitFor({-> VimContextLabel() ==# a:label})
  redraw
  call assert_equal([], popup_list(), 'context created a floating window')
endfunction
'''


def symbol(name, kind, row, column, end, children=()):
    return {'name': name, 'kind': kind,
            'range': {'start': {'line': row - 1, 'character': 0},
                      'end': {'line': end - 1, 'character': 80}},
            'selectionRange': {'start': {'line': row - 1, 'character': column},
                               'end': {'line': row - 1, 'character': column + len(name)}},
            'children': list(children)}


class ContextTests(LspFixture):
    def setUp(self):
        super().setUp()
        rows = ['# target', 'class Parser:']
        rows += [f'    value{i} = {i}' for i in range(3, 9)]
        rows[7] = '    @staticmethod'
        rows += ['    def parse(', '        self,', '        text="a:{b}",', '    ):']
        rows += [f'        value{i} = {i}' for i in range(13, 40)]
        rows += ['        def nested():']
        rows += [f'            value{i} = {i}' for i in range(41, 80)]
        rows += ['        return nested()', '', '', '', '', 'class Other:']
        rows += [f'    value{i} = {i}' for i in range(86, 111)]
        self.source.write_text('\n'.join(rows) + '\n')
        self.symbols = [symbol('Other', 5, 85, 6, 110),
                        symbol('Parser', 5, 2, 6, 80, [
                            symbol('parse', 6, 9, 8, 80, [
                                symbol('text', 13, 11, 8, 11),
                                symbol('nested', 12, 40, 12, 79)])])]
        self.responses = self.work / 'responses.json'
        self.settings += ['let g:vimrc_lite_lsp_diagnostics = 0']

    def configured(self, **config):
        config.setdefault('results', {})['textDocument/documentSymbol'] = self.symbols
        self.responses.write_text(json.dumps(config))
        return self.settings + ['let g:vimrc_lite_lsp_pyright_cmd = '
                                + json.dumps(self.command + ['--response-config', str(self.responses)])]

    def test_statusline_scope_nesting_and_cursor_boundary(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 1)
sleep 100m
call AssertContext(':Parser:parse')
let status = join(map(range(1, &columns), 'screenstring(&lines - 1, v:val)'), '')
call assert_match('main.py:Parser:parse ', status)
call ContextView(25, 4)
call AssertContext(':Parser:parse')
call ContextView(25, 9)
call AssertContext(':Parser:parse')
call ContextView(25, 20)
call AssertContext(':Parser:parse')
call ContextView(60, 55)
call AssertContext(':Parser:parse:nested')
call ContextView(100, 95)
call AssertContext(':Other')
call ContextView(85, 80)
sleep 30m
call AssertContext(':Other')
call ContextView(1, 1)
sleep 30m
call assert_equal('', ContextLabel(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertTrue(self.messages('initialize')[0]['params']['capabilities']
                        ['textDocument']['documentSymbol']['hierarchicalDocumentSymbolSupport'])
        self.assertEqual(len(self.messages('textDocument/documentSymbol')), 1)

    def test_shared_cache_split_positions_scroll_and_native_state(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
call AssertContext(':Parser:parse')
let first = win_getid()
vsplit
let second = win_getid()
call ContextView(100, 95)
call AssertContext(':Other')
call assert_equal(':Parser:parse', ContextLabel(first))
let @/ = 'native search'
let @" = 'native register'
let view = winsaveview()
let jumps = getjumplist()
let windows = map(getwininfo(), 'v:val.winid')
for iteration in range(100)
  call VimContextLabel()
endfor
sleep 30m
call assert_equal(view, winsaveview())
call assert_equal(jumps, getjumplist())
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
call assert_equal('native search', @/)
call assert_equal('native register', @")
call assert_false(&modified)
vertical resize 22
redraw
call AssertContext(':Other')
call win_gotoid(first)
close
sleep 30m
call assert_equal([], getwininfo(first))
call AssertContext(':Other')
normal! 5zl
redraw
sleep 30m
call assert_equal(view.lnum, line('.'))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertEqual(len(self.messages('textDocument/documentSymbol')), 1)

    def test_unicode_and_percent_names_are_literal_statusline_text(self):
        self.symbols[1]['name'] = '解析%{1+1}'
        self.symbols[1]['children'][0]['name'] = '处理'
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(':解析%{1+1}:处理')
let status = join(map(range(1, &columns), 'screenstring(&lines - 1, v:val)'), '')
call assert_true(stridx(status, 'main.py:解析%{1+1}:处理') >= 0, status)
for row in range(26, 35)
  call cursor(row, 1)
  redraw
  call assert_equal(':解析%{1+1}:处理', VimContextLabel())
endfor
call assert_equal([], popup_list())
call assert_false(exists('#vimrc_lite_context#CursorMoved'))
call assert_false(exists('#vimrc_lite_context#CursorMovedI'))
call assert_false(exists('#vimrc_lite_context#WinScrolled'))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertEqual(len(self.messages('textDocument/documentSymbol')), 1)

    def test_same_line_unicode_scope_boundaries_and_gaps(self):
        prefix = '    # 中🙂e\u0301 '
        first = 'first_body'
        gap = '   '
        second = 'second_body'
        line = prefix + first + gap + second + ' tail'
        self.source.write_text('class Parser:\n' + line + '\n    pass\n')

        def units(text):
            return len(text.encode('utf-16-le')) // 2

        def child(name, start, end):
            return {'name': name, 'kind': 6,
                    'range': {'start': {'line': 1, 'character': start},
                              'end': {'line': 1, 'character': end}},
                    'selectionRange': {'start': {'line': 1, 'character': start},
                                       'end': {'line': 1, 'character': start + 1}}}

        first_start = units(prefix)
        first_end = units(prefix + first)
        second_start = units(prefix + first + gap)
        second_end = units(prefix + first + gap + second)
        self.symbols = [symbol('Parser', 5, 1, 6, 3, [
            child('first', first_start, first_end),
            child('second', second_start, second_end)])]
        checks = [(1, ':Parser'), (len(prefix.encode()) + 1, ':Parser:first'),
                  (len((prefix + first).encode()) + 1, ':Parser'),
                  (len((prefix + first + gap).encode()) + 1, ':Parser:second'),
                  (len((prefix + first + gap + second).encode()) + 1, ':Parser')]
        self.terminal_vim(HELPERS + r'''
call ContextView(2, 1)
call AssertContext(':Parser')
let checks = ''' + json.dumps(checks) + r'''
for check in checks + reverse(copy(checks)) + checks
  call cursor(2, check[0])
  call assert_equal(check[1], VimContextLabel(), string(check))
endfor
call cursor(3, 1)
call assert_equal(':Parser', VimContextLabel())
call assert_equal([], popup_list())
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertEqual(len(self.messages('textDocument/documentSymbol')), 1)

    def test_edits_debounce_stale_response_and_undo(self):
        shifted = json.loads(json.dumps(self.symbols))

        def shift(nodes):
            for node in nodes:
                for key in ('range', 'selectionRange'):
                    for point in ('start', 'end'):
                        node[key][point]['line'] += 1
                shift(node['children'])

        shift(shifted)
        shifted[1]['name'] = 'New'
        update = {'results': {'textDocument/documentSymbol': shifted},
                  'delay_ms': {'textDocument/documentSymbol': 0}}
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(':Parser:parse')
call Configure({'delay_ms': {'textDocument/documentSymbol': 350}})
call setline(2, 'class Old:')
doautocmd vimrc_lite_context TextChanged
call assert_equal('', ContextLabel(win_getid()), 'edit must hide stale coordinates immediately')
sleep 200m
call Configure(''' + json.dumps(update) + r''')
call append(0, '# inserted')
call setline(3, 'class New:')
doautocmd vimrc_lite_context TextChanged
call ContextView(26, 21)
call assert_equal('', ContextLabel(win_getid()))
call AssertContext(':New:parse')
sleep 400m
call assert_equal(':New:parse', ContextLabel(win_getid()),
      \ 'late response replaced current coordinates')
call Configure({'results': {'textDocument/documentSymbol': ''' + json.dumps(self.symbols) + r'''}})
undo
doautocmd vimrc_lite_context TextChanged
call ContextView(25, 20)
call AssertContext(':Parser:parse')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertGreaterEqual(len(self.messages('$/cancelRequest')), 1)

    def test_toggle_reload_tabs_and_restart(self):
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(':Parser:parse')
VimContextToggle
call assert_equal('', ContextLabel(win_getid()))
VimContextToggle
call AssertContext(':Parser:parse')
source ''' + str(ROOT / '.vimrc') + r'''
call AssertContext(':Parser:parse')
call assert_false(exists('#vimrc_lite_context#CursorMoved'))
call assert_false(exists('#vimrc_lite_context#WinScrolled'))
call popup_clear()
redrawstatus
call AssertContext(':Parser:parse')
tabnew
sleep 30m
call assert_equal('', VimContextLabel())
call assert_equal([], popup_list())
tabclose
call AssertContext(':Parser:parse')
VimLspStop
sleep 30m
call assert_equal('', ContextLabel(win_getid()))
VimLspStart
call AssertContext(':Parser:parse')
VimLspRestart
call AssertContext(':Parser:parse')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())

    def test_flat_results_missing_capability_and_errors_stay_quiet(self):
        cases = [({'capabilities': {'documentSymbolProvider': False}}, 0),
                 ({'errors': {'textDocument/documentSymbol': {'code': -32603, 'message': 'failed'}}}, 1),
                 ({'delay_ms': {'textDocument/documentSymbol': 500}}, 1)]
        for config, count in cases:
            with self.subTest(config=config):
                self.log.write_text('')
                self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
sleep 600m
call assert_equal('', ContextLabel(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured(**config)
                    + ['let g:vimrc_lite_lsp_request_timeout_ms = 50'])
                self.assertEqual(len(self.messages('textDocument/documentSymbol')), count)
        self.symbols = [{'name': 'Parser', 'kind': 5, 'location': {
            'uri': self.source.as_uri(), 'range': self.symbols[1]['selectionRange']}}]
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
sleep 100m
call assert_equal('', ContextLabel(win_getid()), 'name locations are not scope ranges')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())

    def test_disabled_feature_does_not_request_symbols(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
sleep 100m
call assert_equal('', ContextLabel(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured() + ['let g:vimrc_lite_context = 0'])
        self.assertEqual([], self.messages('textDocument/documentSymbol'))

    def test_two_projects_keep_separate_cache_and_server_bindings(self):
        project = self.work / 'second project'
        project.mkdir()
        (project / '.git').mkdir()
        source = project / 'second.py'
        source.write_text(self.source.read_text().replace('class Parser:', 'class Second:'))
        second_symbols = json.loads(json.dumps(self.symbols))
        second_symbols[1]['name'] = 'Second'
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(':Parser:parse')
let first = win_getid()
let g:first_server = lsp#get_allowed_servers()[0]
execute 'vsplit ' . fnameescape(''' + quoted(source) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
call AssertContext(':Parser:parse')
call Configure({'results': {'textDocument/documentSymbol': ''' + json.dumps(second_symbols) + r'''}})
call setline(2, 'class Second:')
doautocmd vimrc_lite_context TextChanged
call AssertContext(':Second:parse')
call assert_notequal(g:first_server, lsp#get_allowed_servers()[0])
call assert_equal(':Parser:parse', ContextLabel(first))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        roots = {message['_pid']: message['params']['rootUri']
                 for message in self.messages('initialize')}
        for message in self.messages('textDocument/documentSymbol'):
            self.assertTrue(message['params']['textDocument']['uri'].startswith(
                roots[message['_pid']] + '/'))

    def test_scroll_only_fold_small_window_and_excluded_buffers(self):
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 4)
call AssertContext(':Parser:parse')
let position = getpos('.')
execute "normal! 10\<C-e>"
redraw
call AssertContext(':Parser:parse')
call assert_equal(position, getpos('.'), 'scroll-only update moved the cursor')
setlocal foldmethod=manual
40,79fold
call ContextView(80, 38)
call AssertContext(':Parser:parse')
split
resize 2
redraw
sleep 30m
call assert_equal([], popup_list())
call assert_equal(':Parser:parse', VimContextLabel())
close
call ContextView(25, 20)
call AssertContext(':Parser:parse')
let b:vimrc_lite_large_file = 1
redrawstatus
sleep 30m
call assert_equal('', ContextLabel(win_getid()))
unlet b:vimrc_lite_large_file
redrawstatus
call AssertContext(':Parser:parse')
enew
setlocal buftype=nofile filetype=python
call setline(1, 'class Helper:')
redrawstatus
sleep 30m
call assert_equal('', ContextLabel(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())

    @unittest.skipUnless(shutil.which('pyright-langserver'), 'Requires installed Pyright')
    def test_real_pyright_multiline_decorated_method_and_nested_function(self):
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(':Parser:parse')
call ContextView(60, 55)
call AssertContext(':Parser:parse:nested')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.settings + [
            'let g:vimrc_lite_lsp_pyright_cmd = '
            + json.dumps([shutil.which('pyright-langserver'), '--stdio'])])

    @unittest.skipUnless(shutil.which('clangd'), 'Requires installed clangd')
    def test_real_clangd_namespace_constructor_and_multiline_method(self):
        source = self.source_dir / 'context.cpp'
        rows = ['// target', 'namespace sample {', 'class Parser {', 'public:',
                '  Parser(int x) : value{x} {']
        rows += ['    value += 1;' for _ in range(6, 35)]
        rows += ['  }', '  int parse(', '    int text = 0,',
                 '    const char* message = "//:{") const noexcept {']
        rows += ['    text += 1;' for _ in range(39, 69)]
        rows += ['    return text;', '  }', 'private:', '  int value;', '};',
                 'int standalone(', '    int text) {']
        rows += ['  text += 1;' for _ in range(76, 96)]
        rows += ['  return text;', '}', '}']
        source.write_text('\n'.join(rows) + '\n')
        self.terminal_vim(HELPERS + r'''
call ContextView(20, 15)
call AssertContext(':Parser:Parser')
call ContextView(60, 55)
call AssertContext(':Parser:parse')
call ContextView(90, 85)
call AssertContext(':standalone')
call assert_equal('', v:errmsg)
''', args=[str(source)], before=self.settings + [
            "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-vim-lite-pyright']",
            'let g:vimrc_lite_lsp_clangd_cmd = '
            + json.dumps([shutil.which('clangd'), '--background-index=false'])])


class ContextMigrationTests(VimSession):
    def test_reload_closes_legacy_context_and_keeps_other_popups(self):
        legacy_module = self.work / 'legacy-context.vim'
        legacy_module.write_text(r'''
function! s:LateResponse(timer) abort
  let popup = popup_create(['class Late:'], {'line': 2, 'col': 1})
  call setbufvar(winbufnr(popup), 'vimrc_lite_context_popup', win_getid())
endfunction
let s:timer = timer_start(80, function('s:LateResponse'))
function! s:Reset() abort
  call timer_stop(s:timer)
endfunction
function! s:Toggle() abort
  call s:Reset()
endfunction
command! VimContextToggle call <SID>Toggle()
''')
        self.terminal_vim(r'''
let legacy = popup_create(['class Old:'], {'line': 2, 'col': 1})
call setbufvar(winbufnr(legacy), 'vimrc_lite_context_popup', win_getid())
let other = popup_create(['other feature'], {'line': 4, 'col': 1})
source ''' + str(legacy_module) + r'''
source ''' + str(ROOT / 'context.vim') + r'''
sleep 150m
call assert_equal({}, popup_getpos(legacy))
call assert_equal([other], popup_list(), 'old module recreated its context popup')
call assert_false(empty(popup_getpos(other)))
call popup_close(other)
call assert_equal('', VimContextLabel())
call assert_equal('', v:errmsg)
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
