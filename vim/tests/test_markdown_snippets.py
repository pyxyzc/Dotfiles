"""Real typing through snippet placeholders, nested expansion and math contexts."""

from test_vim import ROOT, VIM, VimSession, quoted


class MarkdownSnippetTests(VimSession):
    def test_tab_expands_link_and_shift_tab_revisits_placeholder(self):
        self.terminal_vim(r'''
enew
setfiletype markdown
call feedkeys("ilink\<Tab>docs\<Tab>path\<S-Tab>label\<Tab>\<Tab>\<Esc>", 'xt')
call assert_equal('[label](path)', getline(1))
enew!
setfiletype text
call assert_equal('', maparg("\<Tab>", 'i'))
''')

    def test_math_templates_nested_fraction_and_dynamic_table(self):
        self.terminal_vim(r'''
enew
setfiletype markdown
call feedkeys("imk\<Tab>x\<Tab>\<Esc>", 'xt')
call assert_equal('$x$', getline(1))
call vsnip#deactivate()
%delete _
call feedkeys("i$ff\<Tab>ff\<Tab>a\<Tab>b\<Tab>\<Tab>c\<Tab>$\<Esc>", 'xt')
call assert_equal('$\frac{\frac{a}{b}}{c}$', getline(1))
call vsnip#deactivate()
%delete _
call feedkeys("i23tb\<Tab>\<Esc>", 'xt')
call assert_equal(5, line('$'))
call assert_equal('| --- | --- |', getline(2))
call assert_equal(2, len(VimMarkdownCells(getline(5))))
''')

    def test_math_context_excludes_code_comments_yaml_and_escaped_delimiters(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['---', 'title: $notmath', '---', '', '$x', '`$literal', '```tex',
      \ '$notmath', '```', '<!-- $notmath', '-->', '$$','x', '$$', '\(x', '\$escaped'])
for lnum in [2, 6, 8, 10, 16]
  call cursor(lnum, strlen(getline(lnum)))
  call assert_equal(0, VimMarkdownMathContext(), string(lnum))
endfor
for lnum in [5, 13, 15]
  call cursor(lnum, strlen(getline(lnum)))
  call assert_equal(1, VimMarkdownMathContext(), string(lnum))
endfor
''')

    def test_auto_subscript_and_fraction_only_inside_math_in_real_terminal(self):
        document = self.work / 'math.md'
        document.write_text('\nanchor_cursor\n')
        result = self.work / 'result.md'
        self.terminal_vim(r'''
let child = term_start([''' + quoted(VIM) + ', "-Nu", ' + quoted(ROOT / '.vimrc') + r''',
      \ '-i', 'NONE', '-n', ''' + quoted(document) + r'''], {'hidden': 1, 'term_cols': 110})
function! WaitText(child, text) abort
  for attempt in range(150)
    call term_wait(a:child, 10)
    if stridx(TerminalScreen(a:child), a:text) >= 0
      return
    endif
  endfor
  call assert_report('terminal missing ' . a:text . ': ' . TerminalScreen(a:child))
endfunction
call WaitText(child, 'anchor_cursor')
call term_sendkeys(child, 'gg0i$A1')
call WaitText(child, 'A_1')
call term_sendkeys(child, '2')
call WaitText(child, 'A_{12}')
call term_sendkeys(child, '3')
call WaitText(child, 'A_{123}')
call term_sendkeys(child, ' + x/')
call WaitText(child, '\frac{x}')
call term_sendkeys(child, "b\<Tab>$\<Esc>")
call term_sendkeys(child, ":call writefile(getline(1, '$'), " . ''' + quoted(quoted(result)) + r''' . ")\<CR>")
for attempt in range(150)
  call term_wait(child, 10)
  if getfsize(''' + quoted(result) + r''') > 0
    break
  endif
endfor
call assert_equal('$A_{123} + \frac{x}{b}$', readfile(''' + quoted(result) + r''')[0])
call term_sendkeys(child, ":qa!\<CR>")
call term_wait(child, 50)
''')
