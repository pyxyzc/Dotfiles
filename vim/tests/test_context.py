"""Sticky context uses document ranges without changing native editor state."""

import json
import shutil
import unittest

from test_lsp import LspFixture, WAIT
from test_lsp_behaviors import CONFIGURE
from test_vim import ROOT, VimSession, quoted


HELPERS = WAIT + CONFIGURE + r'''
function! ContextPopup(window) abort
  return get(filter(popup_list(),
        \ 'getbufvar(winbufnr(v:val), "vimrc_lite_context_popup", 0) == a:window'), 0, 0)
endfunction
function! ContextLines(window) abort
  let popup = ContextPopup(a:window)
  return popup ? map(getbufline(winbufnr(popup), 1, '$'),
        \ 'substitute(v:val, "^\\s\\+", "", "")') : []
endfunction
function! ContextView(cursor, top) abort
  setlocal scrolloff=0
  call cursor(a:cursor, 1)
  let view = winsaveview()
  let view.topline = a:top
  call winrestview(view)
  redraw
  doautocmd vimrc_lite_context CursorMoved
endfunction
function! AssertContext(lines) abort
  call WaitFor({-> ContextLines(win_getid()) ==# a:lines})
  redraw
  let popup = ContextPopup(win_getid())
  if popup
    let position = popup_getpos(popup)
    let window = getwininfo(win_getid())[0]
    call assert_equal(window.winrow, position.line)
    call assert_equal(window.wincol, position.col)
    call assert_equal(window.width, position.width)
    call assert_true(position.line + position.height <= window.winrow + winline() - 1)
  endif
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

    def test_visibility_nesting_multiline_and_cursor_boundary(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 1)
sleep 100m
call assert_equal([], ContextLines(win_getid()), 'visible definitions must not be repeated')
call ContextView(25, 4)
call AssertContext(['class Parser:'])
call ContextView(25, 9)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call ContextView(60, 55)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):', 'def nested():'])
let g:vimrc_lite_context_max_lines = 2
doautocmd vimrc_lite_context CursorMoved
call AssertContext(['def parse( self, text="a:{b}", ):', 'def nested():'])
let g:vimrc_lite_context_max_lines = 3
call ContextView(100, 95)
call AssertContext(['class Other:'])
call ContextView(85, 80)
sleep 30m
call assert_equal([], ContextLines(win_getid()))
call ContextView(1, 1)
sleep 30m
call assert_equal([], ContextLines(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertTrue(self.messages('initialize')[0]['params']['capabilities']
                        ['textDocument']['documentSymbol']['hierarchicalDocumentSymbolSupport'])
        self.assertEqual(len(self.messages('textDocument/documentSymbol')), 1)

    def test_shared_cache_split_positions_scroll_and_native_state(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
let first = win_getid()
vsplit
let second = win_getid()
call ContextView(100, 95)
call AssertContext(['class Other:'])
call assert_equal(['class Parser:', 'def parse( self, text="a:{b}", ):'], ContextLines(first))
let @/ = 'native search'
let @" = 'native register'
let view = winsaveview()
let jumps = getjumplist()
let windows = map(getwininfo(), 'v:val.winid')
for iteration in range(100)
  doautocmd vimrc_lite_context CursorMoved
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
doautocmd vimrc_lite_context VimResized
call WaitFor({-> popup_getpos(ContextPopup(win_getid())).width == 22})
call win_gotoid(first)
close
sleep 30m
call assert_equal(0, ContextPopup(first))
call AssertContext(['class Other:'])
normal! 5zl
redraw
doautocmd vimrc_lite_context WinScrolled
sleep 30m
call assert_equal(view.lnum, line('.'))
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
        update = {'results': {'textDocument/documentSymbol': shifted},
                  'delay_ms': {'textDocument/documentSymbol': 0}}
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call Configure({'delay_ms': {'textDocument/documentSymbol': 350}})
call setline(2, 'class Old:')
doautocmd vimrc_lite_context TextChanged
call assert_equal([], ContextLines(win_getid()), 'edit must hide stale coordinates immediately')
sleep 200m
call Configure(''' + json.dumps(update) + r''')
call append(0, '# inserted')
call setline(3, 'class New:')
doautocmd vimrc_lite_context TextChanged
call ContextView(26, 21)
call assert_equal([], ContextLines(win_getid()))
call AssertContext(['class New:', 'def parse( self, text="a:{b}", ):'])
sleep 400m
call assert_equal(['class New:', 'def parse( self, text="a:{b}", ):'], ContextLines(win_getid()),
      \ 'late response replaced current coordinates')
call Configure({'results': {'textDocument/documentSymbol': ''' + json.dumps(self.symbols) + r'''}})
undo
doautocmd vimrc_lite_context TextChanged
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())
        self.assertGreaterEqual(len(self.messages('$/cancelRequest')), 1)

    def test_toggle_reload_popup_clear_tabs_and_restart(self):
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
VimContextToggle
call assert_equal([], ContextLines(win_getid()))
VimContextToggle
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
source ''' + str(ROOT / '.vimrc') + r'''
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call assert_equal(1, len(filter(split(execute('autocmd vimrc_lite_context CursorMoved'), "\n"),
      \ 'v:val =~# "Queue"')))
call popup_clear()
doautocmd vimrc_lite_context CursorMoved
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
let source_window = win_getid()
tabnew
sleep 30m
call assert_equal(0, ContextPopup(source_window))
tabclose
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
VimLspStop
sleep 30m
call assert_equal([], ContextLines(win_getid()))
VimLspStart
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
VimLspRestart
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
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
call assert_equal([], ContextLines(win_getid()))
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
call assert_equal([], ContextLines(win_getid()), 'name locations are not scope ranges')
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())

    def test_disabled_feature_does_not_request_symbols(self):
        self.terminal_vim(HELPERS + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
sleep 100m
call assert_equal([], ContextLines(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured() + ['let g:vimrc_lite_context = 0'])
        self.assertEqual([], self.messages('textDocument/documentSymbol'))

    def test_two_projects_keep_separate_cache_and_server_bindings(self):
        project = self.work / 'second project'
        project.mkdir()
        (project / '.git').mkdir()
        source = project / 'second.py'
        source.write_text(self.source.read_text().replace('class Parser:', 'class Second:'))
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
let first = win_getid()
let g:first_server = lsp#get_allowed_servers()[0]
execute 'vsplit ' . fnameescape(''' + quoted(source) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call ContextView(25, 20)
call AssertContext(['class Second:', 'def parse( self, text="a:{b}", ):'])
call assert_notequal(g:first_server, lsp#get_allowed_servers()[0])
call assert_equal(['class Parser:', 'def parse( self, text="a:{b}", ):'], ContextLines(first))
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
call AssertContext(['class Parser:'])
let position = getpos('.')
execute "normal! 10\<C-e>"
redraw
doautocmd vimrc_lite_context WinScrolled
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call assert_equal(position, getpos('.'), 'scroll-only update moved the cursor')
setlocal foldmethod=manual
40,79fold
call ContextView(80, 38)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
split
resize 2
redraw
doautocmd vimrc_lite_context VimResized
sleep 30m
let popup = ContextPopup(win_getid())
call assert_true(!popup || popup_getpos(popup).height <= 1)
close
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
let b:vimrc_lite_large_file = 1
doautocmd vimrc_lite_context CursorMoved
sleep 30m
call assert_equal([], ContextLines(win_getid()))
unlet b:vimrc_lite_large_file
doautocmd vimrc_lite_context CursorMoved
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
enew
setlocal buftype=nofile filetype=python
call setline(1, 'class Helper:')
doautocmd vimrc_lite_context CursorMoved
sleep 30m
call assert_equal([], ContextLines(win_getid()))
call assert_equal('', v:errmsg)
''', args=[str(self.source)], before=self.configured())

    @unittest.skipUnless(shutil.which('pyright-langserver'), 'Requires installed Pyright')
    def test_real_pyright_multiline_decorated_method_and_nested_function(self):
        self.terminal_vim(HELPERS + r'''
call ContextView(25, 20)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):'])
call ContextView(60, 55)
call AssertContext(['class Parser:', 'def parse( self, text="a:{b}", ):', 'def nested():'])
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
call AssertContext(['class Parser {', 'Parser(int x)'])
call ContextView(60, 55)
call AssertContext(['class Parser {',
      \ 'int parse( int text = 0, const char* message = "//:{") const noexcept {'])
call ContextView(90, 85)
call AssertContext(['int standalone( int text) {'])
call assert_equal('', v:errmsg)
''', args=[str(source)], before=self.settings + [
            "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-vim-lite-pyright']",
            'let g:vimrc_lite_lsp_clangd_cmd = '
            + json.dumps([shutil.which('clangd'), '--background-index=false'])])


class ContextHeaderTests(VimSession):
    def test_source_signature_strings_defaults_constructor_and_unicode(self):
        self.vim(r'''
let prefix = ScriptPrefix('/context.vim$')
setfiletype cpp
call setline(1, ['std::string Parser::parse(',
      \ '    std::array<int, 2> values = {1, 2},',
      \ '    const char* text = "//:{ignored}") const { return "body"; }'])
let node = {'name': [0, 12], 'end': [2, 99], 'header': v:null}
call assert_equal('std::string Parser::parse( std::array<int, 2> values = {1, 2},'
      \ . ' const char* text = "//:{ignored}") const {',
      \ call(function(prefix . 'Header'), [node]))
call setline(1, 'Parser::Parser(int x) : value{x} { body(); }')
let node = {'name': [0, 8], 'end': [0, 99], 'header': v:null}
call assert_equal('Parser::Parser(int x)', call(function(prefix . 'Header'), [node]))
setlocal filetype=python
call setline(1, 'async def 解析(text="a:\"b", value={"x": 1}): return text')
let node = {'name': [0, 10], 'end': [0, 99], 'header': v:null}
call assert_equal('async def 解析(text="a:\"b", value={"x": 1}):',
      \ call(function(prefix . 'Header'), [node]))
call assert_equal('中文…', call(function(prefix . 'Clip'), ['中文字符', 5]))
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
