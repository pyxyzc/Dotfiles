"""Exercise the vendored client through a real Vim and a local protocol peer."""

import json
from pathlib import Path
import shutil
import sys
import unittest

sys.dont_write_bytecode = True

from test_vim import ROOT, VimSession, quoted


WAIT = r'''
function! WaitFor(Check) abort
  let started = reltime()
  while !a:Check() && reltimefloat(reltime(started)) < 4
    sleep 10m
  endwhile
  call assert_true(a:Check(), 'asynchronous LSP operation timed out')
endfunction
'''


class LspTests(VimSession):
    def setUp(self):
        super().setUp()
        self.env['HOME'] = str(self.work)
        self.project = self.work / 'project 中文 with spaces'
        self.source_dir = self.project / 'src'
        self.source_dir.mkdir(parents=True)
        (self.project / '.git').mkdir()
        self.prefix = '说明 = "中文"; '
        self.source = self.source_dir / 'main.py'
        self.source.write_text(self.prefix + 'target\n', encoding='utf-8')
        self.target = self.source_dir / 'definition.py'
        self.target.write_text(self.prefix + 'target = 42\n', encoding='utf-8')
        self.log = self.work / 'protocol.jsonl'
        self.command = [sys.executable, str(ROOT / 'tests' / 'mock_lsp.py'),
                        '--log', str(self.log), '--target', str(self.target),
                        '--stdio', 'literal $(touch UNEXPECTED) `touch ALSO_UNEXPECTED`']
        self.settings = [
            'let g:vimrc_lite_lsp_pyright_cmd = ' + json.dumps(self.command),
            "let g:vimrc_lite_lsp_clangd_cmd = ['/missing-vim-lite-clangd']",
        ]

    def messages(self, method=None):
        values = [json.loads(line) for line in self.log.read_text().splitlines()]
        return values if method is None else [value for value in values if value.get('method') == method]

    def test_navigation_hover_completion_and_unsaved_unicode(self):
        body = WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_equal('<Plug>(lsp-definition)', maparg('gd', 'n'))
call assert_equal('<Plug>(lsp-references)', maparg('gr', 'n'))
call assert_equal('<Plug>(lsp-hover)', maparg('K', 'n'))
call assert_equal('', maparg("\<C-o>", 'n'))
call assert_equal('', &tagfunc)
call assert_equal('.,w,b', &complete)
call assert_equal('manual', &foldmethod)
let origin = bufnr('%')
let original_cwd = getcwd()
call setline(1, ''' + quoted(self.prefix + 'target + 1') + r''')
call cursor(1, ''' + str(len(self.prefix.encode()) + 1) + r''')
call feedkeys('gd', 'xt')
call WaitFor({-> expand('%:p') ==# ''' + quoted(self.target) + r'''})
call assert_equal([1, ''' + str(len(self.prefix.encode()) + 1) + r'''], [line('.'), col('.')])
call feedkeys("\<C-o>", 'xt')
call assert_equal(origin, bufnr('%'))
call assert_true(&modified)
call assert_equal(original_cwd, getcwd())
call feedkeys('gr', 'xt')
call WaitFor({-> len(getqflist()) == 2})
call assert_equal(2, len(getqflist()))
cclose
call feedkeys('K', 'xt')
call WaitFor({-> lsp#document_hover_preview_winid() > 0})
let hover = lsp#document_hover_preview_winid()
call assert_match('target: int', join(getbufline(winbufnr(hover), 1, '$'), "\n"))
call popup_clear()
call assert_equal([], getloclist(0))
call assert_equal([], filter(sign_getplaced(origin, {'group': '*'})[0].signs, 'v:val.group =~? "lsp"'))
call assert_equal(0, g:lsp_diagnostics_enabled)
call assert_equal(0, g:lsp_signature_help_enabled)
call assert_equal(0, g:lsp_document_highlight_enabled)
call assert_equal(0, g:lsp_semantic_enabled)
call assert_equal(0, g:lsp_inlay_hints_enabled)
call setline(1, 'tar')
call cursor(1, 3)
let g:completion_items = []
let g:completion_polls = 0
function! PickCompletion(timer) abort
  let g:completion_polls += 1
  if pumvisible()
    let g:completion_items = complete_info(['items']).items
    call feedkeys("\<C-n>\<C-y>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:completion_polls > 150
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(20, function('PickCompletion'), {'repeat': -1})
call feedkeys("A\<C-x>\<C-o>", 'xt!')
call assert_equal(['target'], map(copy(g:completion_items), 'v:val.word'))
call assert_equal('target', getline(1))
call assert_equal(original_cwd, getcwd())
'''
        self.terminal_vim(body, args=[str(self.source)], before=self.settings)
        self.assertEqual(self.source.read_text(), self.prefix + 'target\n')
        self.assertEqual(len(self.messages('_start')), 1)
        self.assertEqual(self.messages('_start')[0]['argv'], self.command[2:])
        self.assertEqual(self.messages('initialize')[0]['params']['rootUri'], self.project.as_uri())
        self.assertEqual(self.messages('textDocument/definition')[0]['params']['position'],
                         {'line': 0, 'character': len(self.prefix.encode('utf-16-le')) // 2})
        self.assertTrue(any(self.prefix + 'target + 1' in value['text']
                            for value in self.messages('_snapshot')))
        methods = [value.get('method') for value in self.messages()]
        self.assertEqual(methods.count('textDocument/completion'), 1)
        self.assertNotIn('textDocument/signatureHelp', methods)
        self.assertFalse((self.work / 'UNEXPECTED').exists())
        self.assertFalse((self.work / 'ALSO_UNEXPECTED').exists())

    def test_multiple_definitions_reload_and_buffer_activation(self):
        body = WAIT + r'''
call assert_equal('vimdashboard', &filetype)
call assert_equal('not running', lsp#get_server_status('pyright'))
help help
call assert_equal('', maparg('gd', 'n'))
call assert_equal('not running', lsp#get_server_status('pyright'))
close
edit ''' + str(self.source).replace(' ', r'\ ') + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call setline(1, 'target # multiple')
call cursor(1, 1)
call feedkeys('gd', 'xt')
call WaitFor({-> len(getqflist()) == 2})
cclose
source ''' + str(ROOT / '.vimrc') + r'''
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(3, len(split(&runtimepath, ',')))
call assert_equal(['pyright'], lsp#get_server_names())
execute 'edit ' . fnameescape(''' + quoted(self.target) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_match('running', execute('VimLspStatus'))
call assert_match('root:', execute('VimLspStatus'))
call assert_false(&loadplugins)
call assert_equal('', &packpath)
call assert_equal('', maparg("\<C-n>", 'i'))
call assert_equal('', maparg("\<C-]>", 'n'))
'''
        self.terminal_vim(body, before=self.settings)
        self.assertEqual(len(self.messages('_start')), 1)
        self.assertEqual(len(self.messages('initialize')), 1)
        self.assertEqual(len(self.messages('textDocument/didOpen')), 2)

    def test_large_file_skips_running_server_and_survives_reload(self):
        large = self.source_dir / 'large.py'
        large.write_text('target = 1\n' * 100000)
        body = WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
source ''' + str(ROOT / '.vimrc') + r'''
execute 'edit ' . fnameescape(''' + quoted(large) + r''')
call assert_equal(['text', 'OFF', 'manual'], [&filetype, &syntax, &foldmethod])
call assert_equal([], lsp#get_allowed_servers())
call assert_equal('', &omnifunc)
call assert_equal(1, b:vimrc_lite_large_file)
call setline(1, 'target = 2')
write
execute 'edit ' . fnameescape(''' + quoted(self.target) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
'''
        self.terminal_vim(body, args=[str(self.source)], before=self.settings)
        opened = [message['params']['textDocument']['uri']
                  for message in self.messages('textDocument/didOpen')]
        self.assertNotIn(large.as_uri(), opened)
        self.assertIn(self.target.as_uri(), opened)

    def test_large_file_threshold_can_be_disabled(self):
        self.source.write_text('target = 1\n' * 100000)
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_equal('python', &filetype)
call assert_false(get(b:, 'vimrc_lite_large_file', 0))
''', args=[str(self.source)], before=self.settings + ['let g:vimrc_lite_large_file_bytes = 0'])

    def test_language_routing_and_project_markers(self):
        for language, suffix, marker in [('python', '.py', 'pyrightconfig.json'),
                                         ('c', '.c', 'compile_commands.json'),
                                         ('cpp', '.cpp', 'CMakeLists.txt')]:
            with self.subTest(language=language):
                case = self.source_dir / language
                case.mkdir()
                (case / marker).write_text('{}' if marker.endswith('.json') else '')
                source = case / ('main' + suffix)
                source.write_text('target\n')
                name = 'pyright' if language == 'python' else 'clangd'
                settings = ["let g:vimrc_lite_lsp_pyright_cmd = ['/missing-pyright']",
                            "let g:vimrc_lite_lsp_clangd_cmd = ['/missing-clangd']",
                            f'let g:vimrc_lite_lsp_{name}_cmd = ' + json.dumps(self.command)]
                self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_equal([''' + quoted(name) + r'''], lsp#get_allowed_servers())
call assert_equal(''' + quoted(case.as_uri()) + r''', lsp#get_server_root_uri(''' + quoted(name) + r'''))
''', args=[str(source)], before=settings)
        self.assertEqual(len(self.messages('initialize')), 3)

    def test_fallback_root_symlink_and_preview_window(self):
        source = self.work / 'standalone.py'
        source.write_text('target\n')
        config = self.work / 'linked vimrc'
        config.symlink_to(ROOT / '.vimrc')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_equal(''' + quoted(self.work.as_uri()) + r''', lsp#get_server_root_uri('pyright'))
let origin = bufnr('%')
call feedkeys('K', 'xt')
call WaitFor({-> !empty(filter(getwininfo(), 'getwinvar(v:val.winid, "&previewwindow")'))})
call assert_equal(origin, bufnr('%'))
let previews = filter(getwininfo(), 'getwinvar(v:val.winid, "&previewwindow")')
call assert_equal(1, len(previews))
call assert_match('target: int', join(getbufline(previews[0].bufnr, 1, '$'), "\n"))
pclose
''', args=[str(source)], before=self.settings + ['let g:lsp_preview_float = 0'], config=config)

    @unittest.expectedFailure
    def test_upstream_non_bmp_position_conversion(self):
        # Track the pinned upstream's UTF-32/UTF-16 mismatch without patching its sources.
        prefix = '说明 = "🙂"; '
        self.vim(r'''
call setline(1, ''' + quoted(prefix + 'target') + r''')
let position = {'line': 0, 'character': ''' + str(len(prefix.encode('utf-16-le')) // 2) + r'''}
call assert_equal([1, ''' + str(len(prefix.encode()) + 1) + r'''], lsp#utils#position#lsp_to_vim(bufnr('%'), position))
''')

    def test_disabled_missing_invalid_and_failed_servers(self):
        for settings, expected in [
            (['let g:vimrc_lite_lsp = 0'], 'disabled'),
            (["let g:vimrc_lite_lsp_pyright_cmd = ['/missing-pyright']"], 'missing executable'),
            (["let g:vimrc_lite_lsp_pyright_cmd = 'not a list'"], 'invalid command'),
        ]:
            with self.subTest(expected=expected):
                self.terminal_vim(r'''
call assert_match(''' + quoted(expected) + r''', execute('VimLspStatus'))
call assert_equal('', maparg('gd', 'n'))
call assert_equal('', maparg('K', 'n'))
call setline(1, 'editing still works')
call assert_true(&modified)
''', args=[str(self.source)], before=self.settings + settings)
        self.terminal_vim(WAIT + r'''
call WaitFor({-> execute('VimLspStatus') =~# 'exited\|failed'})
call assert_equal('', maparg('gd', 'n'))
call setline(1, 'editing still works')
call assert_true(&modified)
''', args=[str(self.source)], before=self.settings + ["let g:vimrc_lite_lsp_pyright_cmd = ['/bin/false']"])

    def test_missing_plugin_and_missing_module(self):
        config_dir = self.work / 'incomplete configuration'
        config_dir.mkdir()
        config = config_dir / '.vimrc'
        shutil.copy2(ROOT / '.vimrc', config)
        shutil.copy2(ROOT / 'lsp.vim', config_dir / 'lsp.vim')
        self.vim("call assert_match('missing bundled vim-lsp', execute('VimLspStatus'))\n"
                 "call assert_equal(0, exists(':LspDefinition'))", config=config)
        (config_dir / 'lsp.vim').unlink()
        self.vim("call assert_match('missing lsp.vim', execute('VimLspStatus'))", config=config)


if __name__ == '__main__':
    unittest.main(verbosity=2)
