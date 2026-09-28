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
        self.prefix = '说明 = "中文🙂𝄞é"; '
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

    def test_non_bmp_position_conversion(self):
        prefix = '说明 = "🙂"; '
        self.vim(r'''
call setline(1, ''' + quoted(prefix + 'target') + r''')
let position = {'line': 0, 'character': ''' + str(len(prefix.encode('utf-16-le')) // 2) + r'''}
call assert_equal([1, ''' + str(len(prefix.encode()) + 1) + r'''], lsp#utils#position#lsp_to_vim(bufnr('%'), position))
''')

    def test_utf16_native_and_fallback_boundaries(self):
        cases = ['', 'plain ascii', '中🙂𝄞éZ', '👩\u200d💻️!', '𝄞𝅥x', 'a\nb']
        checks = []
        for text in cases:
            byte = 0
            offsets = [0]
            for character in text:
                if ord(character) > 0xffff:
                    offsets.append(byte)
                byte += len(character.encode())
                offsets.append(byte)
            checks += [f'let text = {quoted(text)}',
                       f'call assert_equal({[ord(c) for c in text]}, lsp#utils#utf16#_codepoints_legacy(text))',
                       f'call assert_equal({len(text.encode("utf-16-le")) // 2}, lsp#utils#utf16#length(text))',
                       f'call assert_equal({len(text.encode("utf-16-le")) // 2}, lsp#utils#utf16#_length_fallback(text))']
            for units, expected in enumerate(offsets + [byte, byte]):
                checks += [f'call assert_equal({expected}, lsp#utils#utf16#byteidx(text, {units}))',
                           f'call assert_equal({expected}, lsp#utils#utf16#_byteidx_fallback(text, {units}))']
        (self.work / 'empty.txt').touch()
        self.vim('\n'.join(checks) + r'''
call assert_equal([1, 1], lsp#utils#position#lsp_to_vim('empty.txt', {'line': 0, 'character': 99}))
call assert_equal({'line': 0, 'character': 0}, lsp#utils#position#vim_to_lsp('empty.txt', [1, 1]))
''')

    def test_legacy_codepoints_cross_chunk_boundaries(self):
        checks = []
        for padding in [127, 128, 129, 255, 256, 257]:
            for text in ['🙂' * padding + '中é𝅥END',
                         'a' + '𝅥́' * padding + '\n',
                         '中a🙂𝄞é' * padding]:
                checks.append(f'call assert_equal({[ord(c) for c in text]}, '
                              f'lsp#utils#utf16#_codepoints_legacy({quoted(text)}))')
                checks.append(f'let text = {quoted(text)}')
                checks.append('call assert_equal(0, lsp#utils#utf16#_byteidx_fallback(text, -1))')
                for index in sorted({0, 126, 127, 128, 129, 254, 255, 256, len(text)}):
                    prefix = text[:index]
                    units = len(prefix.encode('utf-16-le')) // 2
                    byte = len(prefix.encode())
                    checks.append(f'call assert_equal({byte}, '
                                  f'lsp#utils#utf16#_byteidx_fallback(text, {units}))')
                    if prefix and ord(prefix[-1]) > 0xffff:
                        checks.append(f'call assert_equal({byte - 4}, '
                                      f'lsp#utils#utf16#_byteidx_fallback(text, {units - 1}))')
        self.vim('\n'.join(checks))

    def test_utf16_incremental_changes_reconstruct_exact_document(self):
        from mock_lsp import offset
        cases = [
            (['中🙂𝄞tail'], ['中🙂X𝄞tail']),
            (['🙂tail'], ['𝄞tail']),
            (['é🙂tail'], ['étail']),
            (['🙂one', '中𝄞two', 'tail'], ['🙂oX𝄞two', 'tail']),
            (['🙂one'], ['🙂one', '𝄞two']),
            (['🙂one', '𝄞two'], ['🙂one']),
            ([''], ['🙂']), (['🙂'], ['']), (['🙂same'], ['🙂same']),
        ]
        report = self.work / 'changes.json'
        body = 'let changes = []\n'
        for old, new in cases:
            body += 'call add(changes, lsp#utils#diff#compute(' + json.dumps(old, ensure_ascii=False)
            body += ', ' + json.dumps(new, ensure_ascii=False) + '))\n'
        body += f'call writefile([json_encode(changes)], {quoted(report)}, "S")\n'
        self.vim(body)
        for (old, new), change in zip(cases, json.loads(report.read_text())):
            before = '\n'.join(old) + '\n'
            start = offset(before, change['range']['start'])
            end = offset(before, change['range']['end'])
            self.assertEqual(len(before[start:end].encode('utf-16-le')) // 2, change['rangeLength'])
            self.assertEqual('\n'.join(new) + '\n', before[:start] + change['text'] + before[end:])

    def test_utf16_text_edits_keep_prefix_suffix_cursor_and_undo(self):
        self.vim(r'''
edit edited.py
call setline(1, '🙂étarget𝄞tail')
call cursor(1, strlen('🙂étarget𝄞') + 1)
let &undolevels = &undolevels
call lsp#utils#text_edit#apply_text_edits(lsp#utils#get_buffer_uri(bufnr('%')), [
      \ {'range': {'start': {'line': 0, 'character': 4}, 'end': {'line': 0, 'character': 10}},
      \  'newText': '中🚀'}])
call assert_equal('🙂é中🚀𝄞tail', getline(1))
call assert_equal(strlen('🙂é中🚀𝄞') + 1, col('.'))
undo
call assert_equal('🙂étarget𝄞tail', getline(1))
call setline(1, ['🙂left', '𝄞middle', 'end🚀tail'])
call cursor(3, strlen('end🚀') + 1)
call lsp#utils#text_edit#apply_text_edits(lsp#utils#get_buffer_uri(bufnr('%')), [
      \ {'range': {'start': {'line': 0, 'character': 2}, 'end': {'line': 2, 'character': 3}},
      \  'newText': "中\n🙂"}])
call assert_equal(['🙂中', '🙂🚀tail'], getline(1, '$'))
call assert_equal([2, strlen('🙂🚀') + 1], [line('.'), col('.')])
''')

    def test_completion_text_edit_and_additional_edits_after_non_bmp_prefix(self):
        original = self.prefix + 'tar # completion-edit'
        self.source.write_text(original + '\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call cursor(1, ''' + str(len((self.prefix + 'tar').encode())) + r''')
let g:accepted = 0
let g:polls = 0
function! AcceptEdit(timer) abort
  let g:polls += 1
  if pumvisible()
    let g:accepted = 1
    call feedkeys("\<C-n>\<C-y>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:polls > 100
    call assert_report('LSP edit completion missing')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('AcceptEdit'), {'repeat': -1})
call feedkeys("a\<C-x>\<C-o>", 'xt!')
call assert_equal(1, g:accepted)
call assert_equal(['# 𝄞', ''' + quoted(self.prefix + 'target🙂 # completion-edit') + r'''], getline(1, '$'))
''', args=[str(self.source)], before=self.settings)
        self.assertEqual(original + '\n', self.source.read_text())
        self.assertEqual(len((self.prefix + 'tar').encode('utf-16-le')) // 2,
                         self.messages('textDocument/completion')[0]['params']['position']['character'])

    def test_legacy_completion_identity_cancellation_and_disabled_edits(self):
        # Force the no-user_data branch on modern Vim as well as real Vim 8.0.
        config_dir = self.work / 'legacy completion config'
        config_dir.mkdir()
        shutil.copy2(ROOT / '.vimrc', config_dir / '.vimrc')
        for pattern in ['*.vim', '*.sh', '*.awk']:
            for source in ROOT.glob(pattern):
                shutil.copy2(source, config_dir / source.name)
        shutil.copytree(ROOT / 'colors', config_dir / 'colors')
        shutil.copytree(ROOT / 'vendor', config_dir / 'vendor')
        omni = config_dir / 'vendor' / 'vim-lsp' / 'autoload' / 'lsp' / 'omni.vim'
        code = omni.read_text()
        guard = "let s:is_user_data_support = has('patch-8.0.1493')"
        self.assertIn(guard, code)
        omni.write_text(code.replace(guard, 'let s:is_user_data_support = 0', 1))
        original = self.prefix + 'tar # completion-edit-duplicates'
        self.source.write_text(original + '\n')
        for selected, enabled in [(1, 1), (2, 1), (0, 1), (2, 0)]:
            with self.subTest(selected=selected, enabled=enabled):
                expected = [original] if not selected else [original.replace('tar #', 'target🙂 #')]
                if selected and enabled:
                    expected.insert(0, '# FIRST 𝄞' if selected == 1 else '# SECOND 🙂')
                self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call cursor(1, ''' + str(len((self.prefix + 'tar').encode())) + r''')
let g:accepted = 0
let g:polls = 0
let g:selected = ''' + str(selected) + r'''
function! AcceptLegacy(timer) abort
  let g:polls += 1
  if pumvisible()
    let g:accepted = 1
    let candidate = {'word': 'target🙂', 'abbr': 'target', 'kind': 'variable',
          \ 'menu': '[LSP pyright:0]', 'info': ''}
    let metadata = lsp#omni#get_managed_user_data_from_completed_item(candidate)
    call assert_false(empty(metadata))
    if !empty(metadata)
      call assert_equal("# FIRST 𝄞\n", metadata.completion_item.additionalTextEdits[0].newText)
    endif
    let candidate.word = 'unrelated'
    call assert_equal({}, lsp#omni#get_managed_user_data_from_completed_item(candidate))
    call feedkeys(g:selected ? repeat("\<C-n>", g:selected) . "\<C-y>\<Esc>" : "\<C-e>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:polls > 100
    call assert_report('legacy completion missing')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('AcceptLegacy'), {'repeat': -1})
call feedkeys("a\<C-x>\<C-o>", 'xt!')
call assert_equal(1, g:accepted)
call assert_equal(''' + json.dumps(expected, ensure_ascii=False) + r''', getline(1, '$'))
call assert_equal({}, lsp#omni#get_managed_user_data_from_completed_item({'word': 'target🙂'}))
''', args=[str(self.source)], config=config_dir / '.vimrc',
                                  before=self.settings + [f'let g:lsp_text_edit_enabled = {enabled}'])
                self.assertEqual(original + '\n', self.source.read_text())

    def test_protocol_snippet_completion_keeps_unicode_placeholder(self):
        original = self.prefix + 'tar # completion-snippet'
        self.source.write_text(original + '\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call cursor(1, ''' + str(len((self.prefix + 'tar').encode())) + r''')
let g:accepted = 0
let g:polls = 0
function! AcceptSnippet(timer) abort
  let g:polls += 1
  if pumvisible()
    let g:accepted = 1
    call feedkeys("\<C-n>\<C-y>\<Esc>", 't')
    call timer_stop(a:timer)
  elseif g:polls > 100
    call assert_report('snippet completion missing')
    call feedkeys("\<Esc>", 't')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(10, function('AcceptSnippet'), {'repeat': -1})
call feedkeys("a\<C-x>\<C-o>", 'xt!')
call assert_equal(1, g:accepted)
call assert_equal(''' + quoted(self.prefix + 'target(中🙂) # completion-snippet') + r''', getline(1))
''', args=[str(self.source)], before=self.settings)
        self.assertEqual(original + '\n', self.source.read_text())

    def test_unicode_snippet_fallback_keeps_placeholder_cursor(self):
        self.vim(r'''
runtime autoload/lsp/ui/vim/completion.vim
let completion = ScriptPrefix('/autoload/lsp/ui/vim/completion.vim$')
edit snippet.py
call setline(1, '🚀 END')
call cursor(1, strlen('🚀 ') + 1)
call call(function(completion . 'simple_expand_text'), ['中🙂${1:VALUE}𝄞$0'])
call assert_equal('🚀 中🙂VALUE𝄞END', getline(1))
call assert_equal([1, strlen('🚀 中🙂') + 1], [line('.'), col('.')])
call setline(1, '🚀 END')
call cursor(1, strlen('🚀 ') + 1)
call call(function(completion . 'simple_expand_text'), ["中\n🙂${1:VALUE}𝄞$0"])
call assert_equal(['🚀 中', '🙂VALUE𝄞END'], getline(1, '$'))
call assert_equal([2, strlen('🙂') + 1], [line('.'), col('.')])
''')

    def test_protocol_sync_uses_fallback_diff_without_listener_or_native_diff(self):
        # Isolated client snapshot emulates the old-Vim feature path; never alter installed Vim.
        config_dir = self.work / 'fallback-config'
        config_dir.mkdir()
        shutil.copy2(ROOT / '.vimrc', config_dir / '.vimrc')
        for pattern in ['*.vim', '*.sh', '*.awk']:
            for source in ROOT.glob(pattern):
                shutil.copy2(source, config_dir / source.name)
        shutil.copytree(ROOT / 'colors', config_dir / 'colors')
        shutil.copytree(ROOT / 'vendor', config_dir / 'vendor')
        listener = config_dir / 'vendor' / 'vim-lsp' / 'autoload' / 'lsp' / 'internal' / 'listener.vim'
        content = listener.read_text()
        for feature in ['listener_add', 'diff']:
            guard = f"exists('*{feature}')"
            self.assertIn(guard, content)
            content = content.replace(guard, '0', 1)
        listener.write_text(content)
        prefix = 'note = "' + '中🙂é' * 5000 + '"; '
        self.source.write_text(prefix + 'target\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_false(lsp#internal#listener#is_enabled())
let prefix = strpart(getline(1), 0, strlen(getline(1)) - strlen('target'))
let origin = bufnr('%')
for value in [1, 2]
  call setline(1, prefix . 'target + ' . value)
  call cursor(1, strlen(prefix) + 1)
  call feedkeys('gd', 'xt')
  call WaitFor({-> expand('%:p') ==# ''' + quoted(self.target) + r'''})
  call feedkeys("\<C-o>", 'xt')
  call assert_equal(origin, bufnr('%'))
endfor
''', args=[str(self.source)], before=self.settings, config=config_dir / '.vimrc')
        snapshots = [message['text'] for message in self.messages('_snapshot')
                     if message['uri'] == self.source.as_uri()]
        self.assertIn(prefix + 'target + 1\n', snapshots)
        self.assertIn(prefix + 'target + 2\n', snapshots)
        changes = self.messages('textDocument/didChange')
        self.assertTrue(changes)
        for message in changes:
            for change in message['params']['contentChanges']:
                self.assertIn('range', change)
                self.assertLessEqual(len(change['text'].encode()), 4)

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
