"""Small real-binary smoke checks, including early Vim 8 without v:argv."""

from test_vim import VimSession


class CompatibilityTests(VimSession):
    def test_interactive_startup_has_no_errors(self):
        self.terminal_vim(r'''
call assert_equal('', v:errmsg)
if exists('v:argv')
  call assert_equal('vimdashboard', &filetype)
else
  call assert_equal('', &filetype)
endif
Dashboard
call assert_equal('vimdashboard', &filetype)
call assert_true(search('Les annees', 'nw') > 0)
call assert_true(search('help version' . (v:version / 100), 'nw') > 0)
''')

    def test_dashboard_does_not_change_global_fillchars(self):
        self.vim(r'''
let original = &g:fillchars
Dashboard
call assert_equal(original, &g:fillchars)
vnew
call assert_equal(original, &g:fillchars)
wincmd p
enew
call assert_equal(original, &g:fillchars)
call assert_equal(original, &fillchars)
''')
