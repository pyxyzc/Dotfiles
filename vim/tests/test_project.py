"""Shared project scopes, user configuration, and effective mapping diagnostics."""

from test_vim import ROOT, VimSession, quoted


class ProjectTests(VimSession):
    def test_python_project_opened_from_outside_has_consistent_roots(self):
        project = self.work / 'python project'
        source = project / 'src' / 'main.py'
        source.parent.mkdir(parents=True)
        source.touch()
        (project / 'pyproject.toml').touch()
        self.vim('edit ' + str(source).replace(' ', '\\ ') + r'''
let root = ''' + quoted(project) + r'''
call assert_equal(root, VimLiteProjectRoot())
let search = ScriptPrefix('/search\.vim$')
call assert_equal(root, call(function(search . 'ProjectRoot'), []))
let lsp = ScriptPrefix('/lsp\.vim$')
call assert_equal(root, call(function(lsp . 'ProjectRoot'), ['pyright', bufnr('%')]))
''')

    def test_language_subprojects_and_explicit_scope_overrides(self):
        project = self.work / 'project'
        child = project / 'component'
        child.mkdir(parents=True)
        (project / '.git').mkdir()
        (child / 'CMakeLists.txt').touch()
        (child / 'main.cpp').touch()
        self.vim('edit ' + str(child / 'main.cpp') + r'''
let project = ''' + quoted(project) + r'''
let child = ''' + quoted(child) + r'''
call assert_equal(child, VimLiteProjectRoot())
let g:vimrc_lite_root_markers = {'search': ['.git']}
call assert_equal(project, VimLiteProjectRoot({'purpose': 'search'}))
call assert_equal(child, VimLiteProjectRoot({'purpose': 'clangd',
      \ 'markers': ['CMakeLists.txt', '.git']}))
let g:vimrc_lite_project_root = {'default': project, 'clangd': child}
call assert_equal(project, VimLiteProjectRoot({'purpose': 'tasks'}))
call assert_equal(child, VimLiteProjectRoot({'purpose': 'clangd'}))
let b:vimrc_lite_project_root = '..'
call assert_equal(project, VimLiteProjectRoot())
let b:vimrc_lite_project_root = '/does-not-exist-vim-project'
try
  call VimLiteProjectRoot()
  call assert_report('accepted a missing root')
catch /root does not exist/
endtry
''')

    def test_personal_settings_precede_modules_and_mappings_win_after_reload(self):
        settings = self.work / 'personal settings.vim'
        mappings = self.work / 'personal mappings.vim'
        settings.write_text('let g:vimrc_lite_persistent_undo = 0\n'
                            'let g:vimrc_lite_buffer_slogans = []\n')
        mappings.write_text('nnoremap <C-l> :let g:personal_hits += 1<CR>\n')
        self.vim(r'''
call assert_false(&undofile)
call assert_equal([], g:vimrc_lite_buffer_slogans)
let g:personal_hits = 0
call feedkeys("\<C-l>", 'xt')
call assert_equal(1, g:personal_hits)
source ''' + str(ROOT / '.vimrc') + r'''
call feedkeys("\<C-l>", 'xt')
call assert_equal(2, g:personal_hits)
call assert_false(&undofile)
''', before=['let g:vimrc_lite_settings_file = ' + quoted(settings),
             'let g:vimrc_lite_mappings_file = ' + quoted(mappings)])

    def test_keys_show_local_precedence_source_and_tree_action(self):
        self.vim(r'''
call feedkeys(' e', 'xt')
let tree = win_getid()
VimKeys <C-l>
let rows = join(getline(1, '$'), "\n")
call assert_match('\[buffer active\]', rows)
call assert_match('\[global overridden\]', rows)
call assert_match('右侧窗口', rows)
call assert_match('source=.*tree\|source=.*netrw', rows)
call assert_match('source=.*\.vimrc:', rows)
call feedkeys('q', 'xt')
call assert_equal(tree, win_getid())
VimKeys hidden
call assert_match('显示隐藏文件', join(getline(1, '$'), "\n"))
''')
