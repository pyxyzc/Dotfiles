"""CUDA document routing and real clangd navigation with a host-only database."""

import json
import shutil
import unittest

from test_lsp import LspFixture, WAIT
from test_vim import ROOT, VimSession, quoted


class CudaRoutingTests(LspFixture):
    def test_reload_updates_cuda_allowlist_without_restarting_existing_server(self):
        source = self.source_dir / 'kernel.cu'
        source.write_text('int target() { return 1; }\n')
        cpp = self.source_dir / 'main.cpp'
        cpp.write_text('int target() { return 1; }\n')
        self.terminal_vim(WAIT + r'''
call WaitFor({-> lsp#get_server_status('clangd') ==# 'running'})
let server_id = lsp#get_server_info('clangd')._root_uri_resolved
let info = lsp#get_server_info('clangd')
let info.allowlist = ['c', 'cpp']
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(['c', 'cpp', 'cuda'], lsp#get_server_info('clangd').allowlist)
call assert_equal(server_id, lsp#get_server_info('clangd')._root_uri_resolved)
execute 'edit ' . fnameescape(''' + quoted(source) + r''')
call WaitFor({-> &omnifunc ==# 'lsp#complete'})
call assert_equal(['clangd'], lsp#get_allowed_servers())
''', args=[str(cpp)], before=[
            "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-pyright']",
            'let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps(self.command)])
        self.assertEqual(1, len(self.messages('initialize')))
        self.assertTrue(any(message['params']['textDocument']['languageId'] == 'cuda'
                            for message in self.messages('textDocument/didOpen')))

    def test_cuda_binds_clangd_and_uses_shared_project_root(self):
        source = self.source_dir / 'kernel.cu'
        source.write_text('int target() { return 1; }\n')
        self.terminal_vim(WAIT + r'''
call assert_equal('cuda', &filetype)
call WaitFor({-> lsp#get_server_status('clangd') ==# 'running'})
call assert_equal(['clangd'], lsp#get_allowed_servers())
call assert_equal(''' + quoted(self.project) + r''', VimLiteProjectRoot())
VimLspInfo
call assert_match('cuda', join(getline(1, '$'), "\n"))
''', args=[str(source)], before=[
            "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-pyright']",
            'let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps(self.command)])
        opened = self.messages('textDocument/didOpen')[0]['params']['textDocument']
        self.assertEqual(opened['languageId'], 'cuda')
        self.assertTrue(self.messages('initialize')[0]['params']['initializationOptions']['clangdFileStatus'])


class RealCudaTests(VimSession):
    @unittest.skipUnless(shutil.which('clangd'), 'clangd is not installed')
    def test_real_cuda_host_only_definition_and_return_jump(self):
        source = self.work / 'kernel.cu'
        source.write_text('int helper(int x) { return x + 1; }\n'
                          'int main() { return helper(3); }\n')
        database = [{'directory': str(self.work), 'file': str(source),
                     'arguments': ['clang++', '-x', 'cuda', '--cuda-host-only',
                                   '-nocudainc', '-nocudalib', '-c', str(source)]}]
        (self.work / 'compile_commands.json').write_text(json.dumps(database))
        self.terminal_vim(WAIT + r'''
call assert_equal('cuda', &filetype)
call WaitFor({-> lsp#get_server_status('clangd') ==# 'running'})
call cursor(2, 1)
call search('helper', 'c')
call feedkeys('gd', 'xt')
call WaitFor({-> line('.') == 1})
call assert_match('int helper', getline('.'))
call feedkeys("\<C-o>", 'xt')
call assert_equal(2, line('.'))
call assert_equal('kernel.cu', expand('%:t'))
''', args=[str(source)], before=[
            'let g:vimrc_lite_lsp_clangd_cmd = ' + json.dumps([shutil.which('clangd'), '--background-index']),
            "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-pyright']"])
