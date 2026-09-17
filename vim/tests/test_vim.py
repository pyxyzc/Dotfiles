#!/usr/bin/env python3
"""Offline regression checks; all writes stay in temporary directories."""

import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import struct
import sys
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
VIM = shutil.which("vim")
BASH = shutil.which("bash")


def quoted(value):
    return "'" + str(value).replace("'", "''").replace('\n', "' . \"\\n\" . '") + "'"


class VimSession(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vim-lite-tests-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.env = os.environ.copy()
        self.env['XDG_STATE_HOME'] = str(self.work / 'state')

    def vim(self, body, config=None, before=None):
        report = self.work / "errors.txt"
        script = self.work / "check.vim"
        script.write_text(
            "set nomore\n"
            "let s:prefix = matchstr(maparg(\"\\<C-w>\", 'n'), '<SNR>\\d\\+_')\n"
            "function! Call(name, args) abort\n"
            "  return call(function(s:prefix . a:name), a:args)\n"
            "endfunction\n"
            "try\n" + body + "\n"
            "catch\n"
            "  call add(v:errors, v:exception . ' at ' . v:throwpoint)\n"
            "endtry\n"
            f"call writefile(v:errors, {quoted(report)})\n"
            "if !empty(v:errors) | cquit | endif\nqa!\n",
            encoding="utf-8",
        )
        command = [VIM, "-Nu", str(config or ROOT / ".vimrc"), "-i", "NONE", "-n", "-es", "-V1"]
        command += ["--cmd", "let g:vimrc_lite_osc52 = 0"]
        command += ["--cmd", "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-vim-lite-pyright']",
                    "--cmd", "let g:vimrc_lite_lsp_clangd_cmd = ['/missing-vim-lite-clangd']"]
        for setting in before or []:
            command += ["--cmd", setting]
        result = subprocess.run(
            command + ["-S", str(script)], cwd=self.work,
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=20, start_new_session=True, env=self.env,
        )
        errors = report.read_text() if report.exists() else ""
        self.assertEqual(result.returncode, 0, errors + result.stdout + result.stderr)
        self.assertEqual(errors, "")
        return result

    def terminal_vim(self, body, args=(), before=(), stdin=None, config=None):
        """Send checks after VimEnter, so startup is not bypassed by -S/-c."""
        ready = self.work / 'ready'
        report = self.work / 'terminal-errors'
        for path in (ready, report):
            path.unlink(missing_ok=True)
        script = self.work / 'terminal-check.vim'
        script.write_text(
            'set nomore\n'
            'function! TerminalScreen(buf) abort\n'
            '  return join(map(range(1, term_getsize(a:buf)[0]), '
            "'term_getline(a:buf, v:val)'), \"\\n\")\n"
            'endfunction\ntry\n' + body + '\ncatch\n'
            "call add(v:errors, v:exception . ' at ' . v:throwpoint)\nendtry\n"
            f'call writefile(v:errors, {quoted(report)})\n'
            'if !empty(v:errors) | cquit | endif\nqa!\n', encoding='utf-8',
        )
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        env = self.env.copy()
        env['TERM'] = 'xterm-256color'
        command = [VIM, '-Nu', str(config or ROOT / '.vimrc'), '-i', 'NONE', '-n',
                   '--cmd', "let g:vimrc_lite_lsp_pyright_cmd = ['/missing-vim-lite-pyright']",
                   '--cmd', "let g:vimrc_lite_lsp_clangd_cmd = ['/missing-vim-lite-clangd']",
                   '--cmd', f'autocmd VimEnter * call writefile([], {quoted(ready)})']
        for setting in before:
            command += ['--cmd', setting]
        process = subprocess.Popen(
            command + list(args), cwd=self.work, env=env,
            stdin=slave if stdin is None else subprocess.PIPE, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = b''
        sent = False
        deadline = time.monotonic() + 10
        try:
            if stdin is not None:
                process.stdin.write(stdin)
                process.stdin.close()
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.05)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                if not sent and ready.exists():
                    os.write(master, f':source {script}\r'.encode())
                    sent = True
                if process.poll() is not None:
                    break
            self.assertTrue(sent, repr(output[-2000:]))
            self.assertEqual(process.wait(timeout=2), 0,
                             (report.read_text(errors='replace') if report.exists() else '') + repr(output[-2000:]))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
        self.assertEqual(report.read_text(), '')
        return output

class VimTests(VimSession):
    def test_dashboard_terminal_startup_and_new_file(self):
        output = self.terminal_vim(r'''
call assert_equal('vimdashboard', &filetype)
call assert_equal(['nofile', 'wipe', 0, 0, 0], [&buftype, &bufhidden, &buflisted, &swapfile, &modifiable])
call assert_equal([0, 0, 0, 0], [&number, &relativenumber, &laststatus, &cursorline])
call assert_equal(0, &showtabline)
let content = map(filter(getline(1, '$'), '!empty(v:val)'), 'substitute(v:val, "^ *", "", "")')
call assert_equal(['Les annees heureuses sont des annees perdues.'], content)
call assert_equal(0, synID(line('$'), 1, 1))
call assert_equal(0, synID(line('$'), match(getline('$'), '\S') + 1, 1))
for key in ['f', 'n', 'e', 'r', 't', 'c', 'q', 'j', 'k', "\<Down>", "\<Up>", "\<CR>"]
  call assert_false(get(maparg(key, 'n', 0, 1), 'buffer', 0), key)
endfor
let home = bufnr('%')
call feedkeys("\<Space>bnihello\<Esc>", 'xt')
call assert_equal('hello', getline(1))
call assert_equal('', &buftype)
call assert_false(bufexists(home))
call assert_equal([1, 1, 2, 1], [&number, &relativenumber, &laststatus, &cursorline])
call assert_equal(2, &showtabline)
call assert_equal('', maparg('q', 'n'))
''')
        self.assertIn(b'Les annees heureuses', output)

    def test_dashboard_startup_exclusions(self):
        (self.work / 'sample.py').write_text('preserved\n')
        (self.work / 'session.vim').write_text('let g:session_loaded = 1\n')
        cases = [
            (['sample.py'], (), None, "call assert_equal('preserved', getline(1))"),
            (['.'], (), None, "call assert_equal('netrw', &filetype)"),
            ([], ('let g:vimrc_lite_dashboard = 0',), None, 'Dashboard\ncall assert_equal(\'vimdashboard\', &filetype)'),
            (['-c', 'let g:command_loaded = 1'], (), None, 'call assert_equal(1, g:command_loaded)'),
            (['+let g:command_loaded = 1'], (), None, 'call assert_equal(1, g:command_loaded)'),
            (['-S', 'session.vim'], (), None, 'call assert_equal(1, g:session_loaded)'),
            (['-e'], (), None, ''),
            (['-'], (), b'', "call assert_equal([''], getline(1, '$'))"),
            (['-'], (), b'pipe contents\n', "call assert_equal('pipe contents', getline(1))"),
        ]
        for args, before, stdin, check in cases:
            with self.subTest(args=args, before=before, stdin=stdin):
                self.terminal_vim(
                    "call assert_notequal('vimdashboard', &filetype)\n" + check,
                    args=args, before=before, stdin=stdin,
                )

    def test_dashboard_loads_through_symlink(self):
        config = self.work / 'linked vimrc'
        config.symlink_to(ROOT / '.vimrc')
        self.vim(r'''
Dashboard
call assert_equal('vimdashboard', &filetype)
call assert_match('dashboard.vim', execute('scriptnames'))
call assert_match('tree.vim', execute('scriptnames'))
VimConfig
call assert_equal(''' + quoted(config) + r''', expand('%:p'))
''', config=config)

    def test_dashboard_restores_windows_and_preserves_unsaved_buffers(self):
        self.vim(r'''
edit unsaved.py
call setline(1, 'keep this')
let original = bufnr('%')
setlocal nonumber relativenumber foldcolumn=3 signcolumn=yes list wrap
set laststatus=1
set showtabline=1
let settings = [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars]
Dashboard
let home = bufnr('%')
call assert_equal(0, &laststatus)
call assert_equal(0, &showtabline)
Dashboard
call assert_equal(home, bufnr('%'))
call assert_true(bufexists(original))
call assert_equal(['keep this'], getbufline(original, 1, '$'))
call assert_true(getbufvar(original, '&modified'))
vsplit
call assert_equal(1, &laststatus)
call assert_equal(1, &showtabline)
enew
call assert_equal(settings, [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars])
call assert_equal(1, &laststatus)
wincmd p
call assert_equal('vimdashboard', &filetype)
let home_window = win_getid()
wincmd p
call assert_equal([0, 0, 0, 'no'], [getwinvar(home_window, '&number'), getwinvar(home_window, '&relativenumber'), str2nr(getwinvar(home_window, '&foldcolumn')), getwinvar(home_window, '&signcolumn')])
call assert_equal(settings, [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars])
wincmd p
execute 'buffer ' . original
call assert_false(bufexists(home))
call assert_equal(settings, [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars])
call assert_equal('keep this', getline(1))
call assert_true(&modified)
Dashboard
new
call assert_equal(settings, [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars])
''')

    def test_dashboard_screen_position_with_file_tree(self):
        self.terminal_vim(r'''
function! SloganPosition(window) abort
  let lines = getbufline(winbufnr(a:window), 1, '$')
  let position = win_screenpos(a:window)
  return [position[0] + len(lines) - getwininfo(a:window)[0].topline,
        \ position[1] + match(lines[-1], '\S')]
endfunction
let home = win_getid()
let position = SloganPosition(home)
call feedkeys("\<Space>e", 'xt')
call assert_equal('netrw', &filetype)
let tree = win_getid()
call assert_equal(position, SloganPosition(home))
for width in [12, 22, 18]
  call feedkeys(':vertical resize ' . width . "\<CR>", 'xt')
  " Vim normally delivers this event after returning from the sourced script.
  doautocmd WinResized
  call assert_equal(tree, win_getid())
  call assert_equal(position, SloganPosition(home))
endfor
call feedkeys(":vertical resize 70\<CR>", 'xt')
doautocmd WinResized
call assert_equal(win_screenpos(home)[1], SloganPosition(home)[1])
call feedkeys(":vertical resize 20\<CR>", 'xt')
doautocmd WinResized
call assert_equal(position, SloganPosition(home))
let tree_cursor = getpos('.')
set columns=140 lines=40
doautocmd VimResized
let width = strdisplaywidth('Les annees heureuses sont des annees perdues.')
call assert_equal([(&lines - &cmdheight - 1) / 2 + 1, (&columns - width) / 2 + 1], SloganPosition(home))
call assert_equal(tree, win_getid())
call assert_equal(tree_cursor, getpos('.'))
let position = SloganPosition(home)
call feedkeys("\<Space>e", 'xt')
call assert_equal(home, win_getid())
call assert_equal(position, SloganPosition(home))
call assert_equal([0, 0], [&laststatus, &showtabline])
''')

    def test_dashboard_resize_and_reload(self):
        self.terminal_vim(r'''
set columns=40 lines=12
doautocmd VimResized
let header = search('Les annees', 'nw')
call assert_equal('Les annees heureuses sont des annees perdues.', getline(header))
call assert_true(abs((header - 1) - (winheight(0) - line('$'))) <= 1)
call assert_equal(header, line('$'))
set columns=100 lines=30
doautocmd VimResized
let header = search('Les annees', 'nw')
call assert_equal((winwidth(0) - strdisplaywidth('Les annees heureuses sont des annees perdues.')) / 2, match(getline(header), '\S'))
call assert_equal(header, line('$'))
call assert_true(abs((header - 1) - (winheight(0) - line('$'))) <= 1)
source ''' + str(ROOT / '.vimrc') + r'''
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(1, len(filter(split(execute('autocmd vimrc_lite_dashboard VimEnter'), '\n'), 'v:val =~# "DashboardStartup"')))
call assert_equal([0, 0], [&laststatus, &cursorline])
call assert_equal(0, &showtabline)
colorscheme tokyonight-night
call assert_equal(0, synID(line('$'), match(getline('$'), '\S') + 1, 1))
call feedkeys("\<Space>bnitext\<Esc>", 'xt')
call assert_equal('text', getline(1))
call assert_equal([1, 1, 2], [&number, &relativenumber, &laststatus])
call assert_equal(2, &showtabline)
''')

    def test_startup_and_theme(self):
        self.vim(r'''
call assert_equal('tokyonight-night', g:colors_name)
call assert_equal('', &packpath)
call assert_equal($VIMRUNTIME, split(&runtimepath, ',')[0])
call assert_equal(3, len(split(&runtimepath, ',')))
call assert_false(&loadplugins)
call assert_equal(2, exists(':Lexplore'))
call assert_notmatch('/pack/\|/nvim/', execute('scriptnames'))
call assert_equal('#c0caf5', synIDattr(hlID('Normal'), 'fg', 'gui'))
call assert_equal('', synIDattr(hlID('Normal'), 'bg', 'gui'))
call assert_match('^\d\+$', synIDattr(hlID('Normal'), 'fg', 'cterm'))
source ''' + str(ROOT / ".vimrc") + r'''
call assert_equal('tokyonight-night', g:colors_name)
colorscheme tokyonight-night
call assert_equal('tokyonight-night', g:colors_name)
''')
        self.vim(r'''
call assert_false(&termguicolors)
call assert_equal('#1a1b26', synIDattr(hlID('Normal'), 'bg', 'gui'))
call assert_match('^\d\+$', synIDattr(hlID('Normal'), 'bg', 'cterm'))
''', before=["let g:vimrc_lite_truecolor = 0", "let g:vimrc_lite_transparent = 0"])

    def test_language_settings_and_folds(self):
        (self.work / "sample.py").write_text("def f():\n    return 1\n")
        (self.work / "sample.cpp").write_text("int main() {\n    return 0;\n}\n")
        (self.work / "Makefile").write_text("all:\n\techo done\n")
        self.vim(r'''
edit sample.py
call assert_equal(['python', 4, 1, 'indent'], [&filetype, &shiftwidth, &expandtab, &foldmethod])
call assert_true(foldlevel(2) > 0)
call assert_equal(-1, foldclosed(2))
edit sample.cpp
syntax sync fromstart
call assert_equal(['cpp', 4, 1, 'syntax'], [&filetype, &shiftwidth, &expandtab, &foldmethod])
call assert_true(foldlevel(2) > 0)
edit Makefile
call assert_equal(['make', 8, 0], [&filetype, &tabstop, &expandtab])
''')

    def test_close_preserves_windows_across_tabs(self):
        self.vim(r'''
edit one.py
let target = bufnr('%')
badd two.cpp
vsplit
tab split
let windows = map(getwininfo(), 'v:val.winid')
let origin = win_getid()
call Call('CloseBuffer', [])
call assert_false(buflisted(target))
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
call assert_equal(origin, win_getid())
for window in getwininfo()
  call assert_equal('two.cpp', bufname(window.bufnr))
endfor
''')

    def test_modified_close_defaults_to_cancel(self):
        self.vim(r'''
edit unsaved.py
call setline(1, 'unsaved text')
let target = bufnr('%')
badd other.cpp
vsplit
let windows = map(getwininfo(), 'v:val.winid')
call Call('CloseBuffer', [])
call assert_equal(target, bufnr('%'))
call assert_equal('unsaved text', getline(1))
call assert_true(&modified)
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
''')

    def test_last_buffer_exits(self):
        self.vim("call Call('CloseBuffer', [])\ncall writefile(['unexpected'], 'after-close')")
        self.assertFalse((self.work / "after-close").exists())

    def test_close_save_and_discard_in_terminal(self):
        for answer, saved in [(b's', 'changed'), (b'd', 'original')]:
            with self.subTest(answer=answer):
                (self.work / 'close.py').write_text('original\n')
                report = self.work / 'dialog-errors'
                script = self.work / 'dialog.vim'
                script.write_text(r'''
set nomore
edit close.py
call setline(1, 'changed')
let target = bufnr('%')
badd replacement.py
vsplit
execute "normal \<C-w>"
call assert_false(buflisted(target))
call assert_equal(2, winnr('$'))
call assert_equal('replacement.py', bufname('%'))
call writefile(v:errors, 'dialog-errors')
if !empty(v:errors) | cquit | endif
qa!
''')
                master, slave = pty.openpty()
                env = os.environ.copy()
                env['TERM'] = 'xterm-256color'
                process = subprocess.Popen(
                    [VIM, '-Nu', str(ROOT / '.vimrc'), '-i', 'NONE', '-n', '-S', str(script)],
                    cwd=self.work, env=env, stdin=slave, stdout=slave, stderr=slave,
                )
                os.close(slave)
                output = b''
                sent = False
                deadline = time.monotonic() + 10
                try:
                    while time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            try:
                                output += os.read(master, 65536)
                            except OSError:
                                break
                        if not sent and b'Save changes before closing?' in output:
                            os.write(master, answer)
                            sent = True
                        if process.poll() is not None:
                            break
                    self.assertTrue(sent, repr(output[-1000:]))
                    self.assertEqual(process.wait(timeout=2), 0, repr(output[-1000:]))
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    os.close(master)
                self.assertEqual(report.read_text(), '')
                self.assertEqual((self.work / 'close.py').read_text(), saved + '\n')

    def test_buffer_order_and_nonrecursive_navigation(self):
        self.vim(r'''
edit first.py
badd removed.py
let removed = bufnr('removed.py')
badd third.py
execute 'bwipeout ' . removed
call Call('GoBuffer', [2])
call assert_equal('third.py', bufname('%'))
vsplit
let before = winnr('$')
call feedkeys("\<C-h>\<C-l>", 'xt')
call assert_equal(before, winnr('$'))
call assert_true(buflisted('third.py'))
call assert_equal(1, maparg("\<C-h>", 'n', 0, 1).noremap)
''')

    def test_buffer_bar_names_flags_and_numbering(self):
        self.vim(r'''
set columns=200
edit src/main.py
badd removed.py
let removed = bufnr('removed.py')
badd tests/main.py
execute 'bwipeout ' . removed
call feedkeys("\<Space>2", 'xt')
call assert_equal('tests/main.py', bufname('%'))
call setline(1, 'changed')
setlocal readonly
let bar = Call('BufferLine', [])
call assert_match('1:src/main.py ', bar)
call assert_match('%#TabLineSel# 2:tests/main.py + \[RO\]', bar)
call assert_notmatch('removed.py', bar)
setlocal noreadonly
call mkdir('tests', 'p')
write
call assert_notmatch('main.py +', Call('BufferLine', []))
file renamed.py
call assert_match('2:renamed.py ', Call('BufferLine', []))
call assert_notmatch('tests/main.py', Call('BufferLine', []))
enew
call assert_match('3:\[No Name\]', Call('BufferLine', []))
let unnamed = bufnr('%')
setlocal buftype=nofile nobuflisted
call assert_notmatch('\[No Name\]', Call('BufferLine', []))
call feedkeys("\<Space>1", 'xt')
call assert_equal('src/main.py', bufname('%'))
execute 'bwipeout ' . unnamed
if has('terminal')
  let terminal = term_start(['sh', '-c', 'exit 0'], {'hidden': 1})
  call assert_match('\[term\]', Call('BufferLine', []))
endif
''')

    def test_buffer_names_with_shared_suffixes_and_unequal_depths(self):
        self.vim(r'''
let buffers = map(['/one/src/main.py', '/two/src/main.py', '/other/main.py',
      \ '/src/main.py', 'main.py', '', '/路径/x.txt', '/项目/x.txt'], '{"name": v:val}')
call assert_equal(['one/src/main.py', 'two/src/main.py', 'other/main.py',
      \ 'src/main.py', 'main.py', '[No Name]', '路径/x.txt', '项目/x.txt'], Call('BufferNames', [buffers]))
call assert_equal([], Call('BufferNames', [[]]))
''')

    def test_buffer_bar_terminal_display_and_overflow(self):
        self.terminal_vim(r'''
function! BarText() abort
  redraw!
  let text = ''
  let column = 1
  while column <= &columns
    let char = screenstring(1, column)
    let text .= char
    let column += max([1, strdisplaywidth(char)])
  endwhile
  return text
endfunction
execute 'edit ' . fnameescape('中文 100%#TabLineSel#.txt')
call setline(1, 'unsaved')
let bar = BarText()
call assert_match('1:中文 100%#TabLineSel#.txt +', bar)
call assert_equal('', v:errmsg)
execute 'file ' . fnameescape("control\tname.txt")
call assert_match('control\^Iname.txt', BarText())
for number in range(2, 15)
  execute 'badd file' . number . '.txt'
endfor
call feedkeys("\<Space>8", 'xt')
set columns=40
doautocmd VimResized
let bar = BarText()
call assert_match('^< ', bar)
call assert_match('8:file8.txt', bar)
call assert_match(' >\s*$', bar)
let selected_column = match(bar, '8:file8.txt') + 1
call assert_notequal(screenattr(1, 1), screenattr(1, selected_column))
call feedkeys("\<Space>9", 'xt')
call assert_match('9:file9.txt', BarText())
buffer file15.txt
let bar = BarText()
call assert_match('15:file15.txt', bar)
call assert_notmatch(' >', bar)
file 超长中文文件名称需要截断以保持编号可见.txt
set columns=24
doautocmd VimResized
call setline(1, 'changed')
setlocal readonly
let bar = BarText()
call assert_match('15:', bar)
call assert_match('\V~ + [RO]', bar)
call assert_equal('', v:errmsg)
set columns=100
tab split
call assert_match('Tab 2/2', BarText())
tabprevious
call assert_match('Tab 1/2', BarText())
colorscheme tokyonight-night
call assert_equal(synIDtrans(hlID('StatusLine')), synIDtrans(hlID('VimrcBufferLine')))
''', args=['-c', 'let g:skip_home = 1'])

    def test_buffer_bar_reload_and_empty_list(self):
        self.vim(r'''
setlocal nobuflisted
call assert_equal('%#TabLineFill#', Call('BufferLine', []))
source ''' + str(ROOT / '.vimrc') + r'''
source ''' + str(ROOT / '.vimrc') + r'''
call assert_equal(2, &showtabline)
call assert_equal(1, len(filter(split(execute('autocmd vimrc_lite_buffers BufEnter'), '\n'), 'v:val =~# "redrawtabline"')))
call assert_match('BufferLine()', &tabline)
''')

    def test_content_edits_preserve_registers_and_undo(self):
        self.vim(r'''
edit edits.py
call setline(1, ['alpha  ', '    beta' . "\t", ''])
let &undolevels = &undolevels
let @" = 'copied earlier'
let @/ = 'existing search'
call cursor(2, 5)
normal! zz
let view = winsaveview()
call Call('TrimWhitespace', [])
call assert_equal(['alpha', '    beta', ''], getline(1, '$'))
call assert_equal(view, winsaveview())
call assert_equal('existing search', @/)
call assert_equal('copied earlier', @")
undo
call assert_equal(['alpha  ', '    beta' . "\t", ''], getline(1, '$'))
let &undolevels = &undolevels
call Call('ClearBuffer', [])
call assert_equal([''], getline(1, '$'))
call assert_equal('copied earlier', @")
undo
call assert_equal('alpha  ', getline(1))
setlocal readonly
call Call('ClearBuffer', [])
call assert_equal('alpha  ', getline(1))
''')

    def test_ctrl_s_keeps_insertion_position(self):
        self.vim(r'''
edit save.py
call setline(1, 'ab')
call cursor(1, 2)
call feedkeys("iX\<C-s>Y\<Esc>", 'xt')
call assert_equal('aXYb', getline(1))
call assert_equal(['aXb'], readfile('save.py'))
''')

    def test_copy_and_osc52_fallbacks(self):
        text = "中文\nquotes '\" and $() \\ / |\n"
        payload = base64.b64encode(text.encode()).decode()
        self.vim(r'''
execute 'edit ' . fnameescape('space 中文.py')
call Call('CopyPath', [])
call assert_equal(expand('%:p'), @")
call setline(1, ['中文', 'second line'])
call Call('CopyContent', [])
call assert_equal("中文\nsecond line\n", @")
setlocal noendofline
call Call('CopyContent', [])
call assert_equal("中文\nsecond line", @")
setlocal endofline fileformat=dos
call Call('CopyContent', [])
call assert_equal("中文\r\nsecond line\r\n", @")
let text = "中文\nquotes '\" and $() \\ / |\n"
call assert_equal("\e]52;c;" . ''' + quoted(payload) + r''' . "\x07", Call('Osc52', [text]))
let old_path = $PATH
let $PATH = getcwd() . '/missing-bin'
try
  let g:vimrc_lite_osc52 = 1
  call Call('Copy', ['fallback', 'v'])
  call assert_equal('fallback', @")
  call assert_match('base64 is unavailable', execute('messages'))
finally
  let $PATH = old_path
endtry
" The subprocess has no controlling tty: exercise a delivery failure safely.
call Call('Copy', ['no tty', 'v'])
call assert_equal('no tty', @")
call assert_match('OSC 52 unavailable', execute('messages'))
''')

    def test_quickfix_and_location_lists(self):
        self.vim(r'''
call setqflist([{'filename': 'notes.txt', 'lnum': 1, 'text': 'quickfix'}])
call Call('ToggleList', [0])
call assert_true(getqflist({'winid': 0}).winid > 0)
call Call('ToggleList', [0])
call assert_equal(0, getqflist({'winid': 0}).winid)
call setloclist(0, [{'filename': 'notes.txt', 'lnum': 1, 'text': 'location'}])
call Call('ToggleList', [1])
call assert_true(getloclist(0, {'winid': 0}).winid > 0)
call Call('ToggleList', [1])
call assert_equal(0, getloclist(0, {'winid': 0}).winid)
''')

    def test_netrw_toggle(self):
        self.vim(r'''
call feedkeys(' e', 'xt')
call assert_equal(2, winnr('$'))
call assert_equal('netrw', &filetype)
call feedkeys(' e', 'xt')
call assert_equal(1, winnr('$'))
''')

    def test_terminal_opens_one_window_in_new_tab(self):
        self.vim(r'''
if has('terminal')
  let original_tabs = tabpagenr('$')
  execute "normal \<Space>;"
  call assert_equal(original_tabs + 1, tabpagenr('$'))
  call assert_equal(1, winnr('$'))
  call assert_equal('terminal', &buftype)
  let terminal = bufnr('%')
  call Call('CloseBuffer', [])
  call assert_equal(terminal, bufnr('%'))
  call term_sendkeys(terminal, "exit\n")
  for attempt in range(200)
    sleep 10m
    if !bufexists(terminal) | break | endif
  endfor
  call assert_false(bufexists(terminal))
  call assert_equal(original_tabs, tabpagenr('$'))
endif
''')


class TerminalTests(VimSession):
    def setUp(self):
        super().setUp()
        directory = self.work / 'bin'
        directory.mkdir()
        fake = directory / 'lazygit'
        fake.write_text(f'#!{sys.executable}\n' + '''
import os, sys, tty
tty.setraw(sys.stdin.fileno())
print('READY', flush=True)
key = os.read(sys.stdin.fileno(), 1)
sys.exit(0 if key == b'q' else 7)
''')
        fake.chmod(0o755)
        self.env['PATH'] = str(directory) + os.pathsep + self.env['PATH']

    @staticmethod
    def ready():
        return r'''
let terminal = bufnr('%')
for attempt in range(200)
  call term_wait(terminal, 10)
  if term_getline(terminal, 1) =~# 'READY' | break | endif
endfor
call assert_match('READY', term_getline(terminal, 1))
'''

    @staticmethod
    def closed():
        return r'''
for attempt in range(200)
  sleep 10m
  if !bufexists(terminal) | break | endif
endfor
call assert_false(bufexists(terminal))
'''

    def test_dashboard_lazygit_and_shell_return_without_empty_buffer(self):
        for keys, ready, quit_keys in [(' gg', self.ready(), 'q'), (' ;', '', 'exit\n')]:
            with self.subTest(keys=keys):
                self.terminal_vim(r'''
let origin = win_getid()
let home = bufnr('%')
let buffers = map(getbufinfo(), 'v:val.bufnr')
for repeat in range(2)
''' + f'call feedkeys({quoted(keys)}, "xt")\n' + ready + r'''
let terminal = bufnr('%')
call assert_equal('terminal', &buftype)
call assert_equal([2, 1], [tabpagenr('$'), winnr('$')])
''' + f'call term_sendkeys(terminal, {quoted(quit_keys)})\n' + self.closed() + r'''
call assert_equal(origin, win_getid())
call assert_equal(home, bufnr('%'))
call assert_equal('vimdashboard', &filetype)
call assert_equal([1, 0, 0], [tabpagenr('$'), &showtabline, &laststatus])
call assert_equal(buffers, map(getbufinfo(), 'v:val.bufnr'))
endfor
''')

    def test_unsaved_buffers_layout_cwd_and_reload(self):
        for setup in ["edit draft.txt", 'enew']:
            with self.subTest(setup=setup):
                self.terminal_vim(setup + r'''
call setline(1, ['unsaved', 'second line'])
call cursor(2, 3)
vsplit
let origin = win_getid()
let buffer = bufnr('%')
let windows = map(getwininfo(), 'v:val.winid')
let layout = winlayout()
let listed = map(getbufinfo({'buflisted': 1}), 'v:val.bufnr')
let view = winsaveview()
let directory = getcwd()
call feedkeys(' gg', 'xt')
''' + self.ready() + r'''
call assert_equal(directory, getcwd())
source ''' + str(ROOT / '.vimrc') + r'''
call assert_match('running', term_getstatus(terminal))
call term_sendkeys(terminal, 'q')
''' + self.closed() + r'''
call assert_equal(origin, win_getid())
call assert_equal(buffer, bufnr('%'))
call assert_equal(['unsaved', 'second line'], getline(1, '$'))
call assert_true(&modified)
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
call assert_equal(layout, winlayout())
call assert_equal(view, winsaveview())
call assert_equal(listed, map(getbufinfo({'buflisted': 1}), 'v:val.bufnr'))
''')

    def test_background_exit_preserves_focus_and_independent_terminals(self):
        self.terminal_vim(r'''
let home = win_getid()
VimGit
''' + self.ready() + r'''
let first = terminal
call win_gotoid(home)
VimGit
''' + self.ready() + r'''
let second = terminal
tabnew notes.txt
call setline(1, 'keep this draft')
let editor = win_getid()
let terminal = first
call term_sendkeys(terminal, 'q')
''' + self.closed() + r'''
call assert_equal(editor, win_getid())
call assert_true(bufexists(second))
let terminal = second
call term_sendkeys(terminal, 'x')
''' + self.closed() + r'''
call assert_equal(editor, win_getid())
call assert_equal('keep this draft', getline(1))
call assert_true(&modified)
call assert_equal(2, tabpagenr('$'))
''')

    def test_repurposed_terminal_window_and_closed_origin(self):
        self.terminal_vim(r'''
let home = win_getid()
VimGit
''' + self.ready() + r'''
let editor = win_getid()
edit new-file.txt
call setline(1, 'new content')
call win_gotoid(home)
close
call assert_equal(editor, win_getid())
call term_sendkeys(terminal, 'q')
''' + self.closed() + r'''
call assert_equal(editor, win_getid())
call assert_equal('new content', getline(1))
call assert_true(&modified)
call assert_equal(1, tabpagenr('$'))
''')

    def test_missing_executable_and_immediate_failure(self):
        self.terminal_vim(r'''
let home = bufnr('%')
let buffers = map(getbufinfo(), 'v:val.bufnr')
let $PATH = '/nonexistent-vim-terminal-test'
VimGit
call assert_match('LazyGit requires lazygit in PATH', execute('messages'))
call assert_equal(home, bufnr('%'))
call assert_equal(1, tabpagenr('$'))
VimTerminal /nonexistent-vim-terminal-test/program
let terminal = bufnr('%')
for attempt in range(200)
  sleep 10m
  if tabpagenr('$') == 1 | break | endif
endfor
call assert_equal(home, bufnr('%'))
call assert_equal(1, tabpagenr('$'))
call assert_equal(buffers, map(getbufinfo(), 'v:val.bufnr'))
''')

    def test_modules_load_through_symlink(self):
        config = self.work / 'linked.vimrc'
        config.symlink_to(ROOT / '.vimrc')
        self.terminal_vim(r'''
call assert_match('git.vim', execute('scriptnames'))
call assert_match('terminal.vim', execute('scriptnames'))
VimGit
''' + self.ready() + r'''
call term_sendkeys(terminal, 'q')
''' + self.closed() + r'''
call assert_equal('vimdashboard', &filetype)
''', config=config)

    def test_exit_drains_channel_without_polling(self):
        helper = self.work / 'bin' / 'terminal-stream'
        helper.write_text(f'#!{sys.executable}\n' + r'''
import os, signal, sys, time, tty
from pathlib import Path
signal.signal(signal.SIGHUP, signal.SIG_IGN)
tty.setraw(sys.stdin.fileno())
print('READY', flush=True)
os.read(sys.stdin.fileno(), 1)
if os.fork():
    os._exit(0)
deadline = time.monotonic() + 5
while not Path('release').exists():
    if time.monotonic() > deadline:
        os._exit(2)
    time.sleep(0.005)
os.write(1, b'FINAL OUTPUT\r\n')
os._exit(0)
''')
        helper.chmod(0o755)
        self.terminal_vim('VimTerminal terminal-stream\n' + self.ready() + r'''
let job = term_getjob(terminal)
call assert_equal([], filter(timer_info(), 'string(v:val.callback) =~# "_Finish"'))
let g:terminal_final_output = ''
autocmd BufWipeout <buffer> let g:terminal_final_output = join(getbufline(str2nr(expand('<abuf>')), 1, '$'), "\n")
call term_sendkeys(terminal, 'q')
for attempt in range(200)
  if job_status(job) ==# 'dead' | break | endif
  sleep 10m
endfor
sleep 30m
call assert_true(bufexists(terminal), 'Wait for both process exit and channel closure')
call assert_equal([], filter(timer_info(), 'string(v:val.callback) =~# "_Finish"'))
call assert_equal('dead', job_status(job))
call writefile([], 'release')
''' + self.closed() + r'''
call assert_equal('vimdashboard', &filetype)
call assert_match('FINAL OUTPUT', g:terminal_final_output)
''')

    def test_user_created_empty_buffer_is_preserved(self):
        self.terminal_vim(r'''
enew
let empty_buffer = bufnr('%')
let origin = win_getid()
VimGit
''' + self.ready() + r'''
call term_sendkeys(terminal, 'q')
''' + self.closed() + r'''
call assert_equal(origin, win_getid())
call assert_equal(empty_buffer, bufnr('%'))
call assert_equal('', bufname('%'))
call assert_equal([''], getline(1, '$'))
call assert_equal([empty_buffer], map(getbufinfo({'buflisted': 1}), 'v:val.bufnr'))
''')

    def test_last_terminal_window_exits_vim(self):
        report = self.work / 'terminal-errors'
        leaving = self.work / 'leaving'
        self.terminal_vim(r'''
VimGit
''' + self.ready() + r'''
tabonly
call assert_equal(1, tabpagenr('$'))
''' + f'call writefile(v:errors, {quoted(report)})\n'
            + f'autocmd VimLeavePre * call writefile([], {quoted(leaving)})\n'
            + r'''
call term_sendkeys(terminal, 'q')
sleep 2
call assert_report('The last terminal window should have exited Vim')
''')
        self.assertTrue(leaving.exists())


class SearchTests(VimSession):
    def setUp(self):
        super().setUp()
        self.project = self.work / 'project with spaces'
        self.project.mkdir()
        (self.project / '.git').mkdir()
        (self.project / 'src').mkdir()
        self.session = self.work / 'search session'
        self.session.mkdir()

    def helper(self, mode, *args):
        result = subprocess.run(
            [BASH, str(ROOT / 'search.sh'), mode, *map(str, args)],
            cwd=self.project, env=self.env, capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout

    @staticmethod
    def records(output):
        return [record.decode().split('\t', 3) for record in output.split(b'\0') if record]

    def require_backends(self):
        if not shutil.which('rg') or not (shutil.which('fd') or shutil.which('fdfind')):
            self.skipTest('Requires manually installed rg and fd/fdfind')

    def fake_fzf(self):
        """Exercise the real Vim terminal and helpers without claiming to test fzf UI."""
        self.require_backends()
        directory = self.work / 'bin'
        directory.mkdir()
        path = directory / 'fzf'
        path.write_text(f'#!{sys.executable}\n' + r'''
import os, shlex, subprocess, sys, time
if '--filter=' in sys.argv:
    sys.exit(1)
if os.environ.get('SEARCH_TEST_WAIT'):
    time.sleep(30)
if os.environ.get('SEARCH_TEST_CANCEL'):
    sys.exit(130)
source = os.environ['FZF_DEFAULT_COMMAND']
if '--disabled' in sys.argv:
    source = next(arg.split('change:reload:', 1)[1] for arg in sys.argv if 'change:reload:' in arg)
    source = source.replace('{q}', shlex.quote(os.environ['SEARCH_TEST_QUERY']))
result = subprocess.run(source, shell=True, executable=os.environ['SHELL'], capture_output=True)
if result.returncode:
    sys.stderr.buffer.write(result.stderr)
    sys.exit(2)
records = [item for item in result.stdout.split(b'\0') if item]
needle = os.environ.get('SEARCH_TEST_PICK', '').encode()
records = [item for item in records if needle in item]
if not records:
    sys.exit(1)
sys.stdout.buffer.write(records[0] + b'\0')
''')
        path.chmod(0o755)
        self.env['PATH'] = str(directory) + os.pathsep + self.env['PATH']

    @staticmethod
    def wait_search():
        return r'''
let terminals = filter(getbufinfo(), 'getbufvar(v:val.bufnr, "&buftype") ==# "terminal"')
call assert_equal(1, len(terminals))
let terminal = terminals[0].bufnr
let search_job = term_getjob(terminal)
let temporary = job_info(search_job).cmd[4]
for attempt in range(400)
  sleep 10m
  if !bufexists(terminal) && !isdirectory(temporary) | break | endif
endfor
call assert_false(bufexists(terminal))
call assert_false(isdirectory(temporary))
call assert_equal([], popup_list())
'''

    def test_backend_scope_ignore_case_and_regular_expressions(self):
        self.require_backends()
        for name in ['notes.txt', '.hidden', 'ignored.txt', 'src/main.cpp', '.git/config']:
            (self.project / name).write_text('first\nneedle123\nNeedle456\n')
        (self.project / '.gitignore').write_text('ignored.txt\n')
        files = self.records(self.helper('files', self.session))
        self.assertEqual({item[3] for item in files}, {'notes.txt', 'src/main.cpp'})
        matches = self.records(self.helper('query', self.session, r'needle\d+'))
        self.assertEqual(len(matches), 6)
        self.assertEqual({item[1] for item in matches}, {'2', '3'})
        self.assertTrue(any('.hidden' in item[0] for item in matches))
        self.assertFalse(any('ignored' in item[0] or '.git/' in item[0] for item in matches))
        matches = self.records(self.helper('query', self.session, r'Needle\d+'))
        self.assertEqual(len(matches), 3)
        self.assertEqual({item[1] for item in matches}, {'3'})
        self.assertEqual(self.helper('query', self.session, ''), b'')
        self.assertEqual(self.helper('query', self.session, 'not-present'), b'')
        errors = self.records(self.helper('query', self.session, '['))
        self.assertEqual(errors[0][:3], ['', '0', '0'])
        self.assertIn('error', errors[0][3])
        self.assertEqual(list(self.session.glob('rg.*')), [])

    def test_backend_special_paths_preview_and_safe_queries(self):
        self.require_backends()
        name = "src/中文 :12:3: ' | $(touch injected) %09\t\n.cpp"
        (self.project / name).write_text('before\nxx safe-value\n\x1b]51;bad\x07\n')
        matches = self.records(self.helper('query', self.session, 'safe-value'))
        self.assertEqual(len(matches), 1)
        encoded, line, column, display = matches[0]
        self.assertEqual([line, column], ['2', '4'])
        preview = self.helper('preview', encoded, line, display).decode()
        self.assertIn('>     2 xx safe-value', preview)
        self.assertNotIn('\x1b]51;', preview)
        self.helper('query', self.session, "$(touch injected)|'|`touch injected`")
        self.assertFalse((self.project / 'injected').exists())
        self.assertIn('%2509%09%0A', encoded)
        (self.project / name).write_text(''.join(f'context {index}\n' for index in range(1, 201)))
        preview = self.helper('preview', encoded, '150', display).decode()
        self.assertIn('>   150 context 150', preview)
        self.assertIn('   200 context 200', preview)

    def test_project_roots_and_current_directory_are_independent(self):
        nested = self.project / 'src' / 'nested'
        nested.mkdir()
        (nested / 'Makefile').touch()
        self.vim(r'''
let search_prefix = matchstr(execute('command VimFind'), '<SNR>\d\+_')
let Root = function(search_prefix . 'ProjectRoot')
let original_directory = getcwd()
execute 'edit ' . fnameescape(''' + quoted(nested / 'new.py') + r''')
call assert_equal(''' + quoted(nested) + r''', Root())
execute 'edit ' . fnameescape(''' + quoted(self.project / 'src' / 'main.py') + r''')
call assert_equal(''' + quoted(self.project) + r''', Root())
call assert_equal(original_directory, getcwd())
edit outside.py
call assert_equal(original_directory, Root())
execute 'lcd ' . fnameescape(''' + quoted(self.project / 'src') + r''')
Dashboard
call assert_equal(''' + quoted(self.project) + r''', Root())
''')

    def test_terminal_selection_opens_exact_file_and_preserves_unsaved_buffer(self):
        self.fake_fzf()
        name = "中文 :12:3: ' | $(touch injected) %09\t\n.py"
        target = self.project / 'src' / name
        target.write_text('first\nxx needle\n')
        self.env['SEARCH_TEST_QUERY'] = 'needle'
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(self.project / 'unsaved.py') + r''')
call setline(1, 'keep this')
let original = bufnr('%')
let original_directory = getcwd()
let origin_window = win_getid()
VimSearch
''' + self.wait_search() + r'''
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_equal([2, 4], [line('.'), col('.')])
call assert_equal(origin_window, win_getid())
call assert_equal(original_directory, getcwd())
call assert_equal(['keep this'], getbufline(original, 1, '$'))
call assert_true(getbufvar(original, '&modified'))
''')
        self.assertFalse((self.project / 'injected').exists())

    def test_dashboard_file_selection_and_cancel(self):
        self.fake_fzf()
        target = self.project / 'file with spaces.py'
        target.write_text('hello\n')
        self.terminal_vim(r'''
execute 'cd ' . fnameescape(''' + quoted(self.project) + r''')
let home = bufnr('%')
call feedkeys("\<Space>ff", 'xt')
''' + self.wait_search() + r'''
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_false(bufexists(home))
call assert_equal([1, 1, 2], [&number, &relativenumber, &laststatus])
''')
        self.env['SEARCH_TEST_CANCEL'] = '1'
        self.terminal_vim(r'''
let home = bufnr('%')
call feedkeys("\<Space>fp", 'xt')
''' + self.wait_search() + r'''
call assert_equal(home, bufnr('%'))
call assert_equal('vimdashboard', &filetype)
call assert_equal([0, 0, 0], [&number, &relativenumber, &laststatus])
''')

    def test_popup_resize_reload_and_cleanup(self):
        self.fake_fzf()
        self.env['SEARCH_TEST_WAIT'] = '1'
        self.terminal_vim(r'''
let original_options = [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen]
VimFind
let popup = popup_list()[0]
let terminal = winbufnr(popup)
let search_job = term_getjob(terminal)
let temporary = job_info(search_job).cmd[4]
set columns=60 lines=18
doautocmd VimResized
let dimensions = term_getsize(terminal)
call assert_true(dimensions[0] <= 18 && dimensions[1] <= 60)
call assert_equal(1, winnr('$'))
source ''' + str(ROOT / '.vimrc') + r'''
sleep 100m
call assert_equal([], popup_list())
call assert_false(bufexists(terminal))
call assert_false(isdirectory(temporary))
call assert_notequal('run', job_status(search_job))
call assert_equal('vimdashboard', &filetype)
call assert_equal(original_options, [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen])
''')

    def test_missing_dependencies_only_warn(self):
        self.vim(r'''
let $PATH = '/nonexistent-vim-search-test'
let original = bufnr('%')
VimFind
call assert_match('missing bash, fzf, fd/fdfind', execute('messages'))
VimSearch
call assert_match('rg (ripgrep)', execute('messages'))
call assert_equal(original, bufnr('%'))
call assert_equal([], popup_list())
''')

    def split_config(self):
        config = self.work / 'fallback config'
        config.mkdir()
        for name in ('.vimrc', 'search.sh', 'dashboard.vim', 'tree.vim'):
            shutil.copyfile(ROOT / name, config / name)
        # Simulate a Vim without popup windows while exercising the actual split implementation.
        (config / 'search.vim').write_text((ROOT / 'search.vim').read_text().replace(
            "if exists('*popup_create')", 'if 0'))
        return config / '.vimrc'

    def test_split_fallback_restores_layout_and_missing_history_is_nonfatal(self):
        self.fake_fzf()
        target = self.project / 'target.py'
        target.write_text('target\n')
        config = self.split_config()
        state = self.work / 'not a directory'
        state.touch()
        self.env['XDG_STATE_HOME'] = str(state)
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(self.project / 'origin.py') + r''')
vsplit
let windows = map(getwininfo(), 'v:val.winid')
let origin = win_getid()
VimFind
call assert_equal([], popup_list())
call assert_equal(3, winnr('$'))
''' + self.wait_search() + r'''
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
call assert_equal(origin, win_getid())
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_match('history unavailable', execute('messages'))
let $SEARCH_TEST_CANCEL = '1'
VimFind
''' + self.wait_search() + r'''
call assert_equal(origin, win_getid())
call assert_equal(windows, map(getwininfo(), 'v:val.winid'))
''', config=config)

    def test_query_error_keeps_original_buffer_and_cleans_session(self):
        self.fake_fzf()
        self.env['SEARCH_TEST_QUERY'] = '['
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(self.project / 'original.py') + r''')
let original = bufnr('%')
VimSearch
''' + self.wait_search() + r'''
call assert_equal(original, bufnr('%'))
call assert_match('regex parse error', execute('messages'))
''')

    def keyboard_search(self, command, editing=False, exercise_arrows=False, config=None):
        """Send actual PTY bytes through Vim's key decoder and mappings, not term_sendkeys()."""
        startup = self.work / 'keyboard-startup'
        ready = self.work / 'keyboard-ready'
        closed = self.work / 'keyboard-closed'
        script = self.work / 'keyboard-check.vim'
        for path in (startup, ready, closed):
            path.unlink(missing_ok=True)
        script.write_text(r'''
set nomore
''' + ("enew\nfile unsaved.py\ncall setline(1, 'keep unsaved text')\n" if editing else '') + r'''
let g:keyboard_origin = bufnr('%')
let g:keyboard_window = win_getid()
let g:keyboard_options = [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen]
''' + command + r'''
let g:keyboard_terminal = filter(getbufinfo(), 'getbufvar(v:val.bufnr, "&buftype") ==# "terminal"')[0].bufnr
let g:keyboard_directory = job_info(term_getjob(g:keyboard_terminal)).cmd[4]
function! KeyboardObserve(timer) abort
  if bufexists(g:keyboard_terminal)
    let screen = join(map(range(1, term_getsize(g:keyboard_terminal)[0]), 'term_getline(g:keyboard_terminal, v:val)'), "\n")
    if screen =~# '\(Files\|Live grep\)>'
      call writefile([], ''' + quoted(ready) + r''')
    endif
  elseif !isdirectory(g:keyboard_directory)
    let result = {'same_buffer': bufnr('%') == g:keyboard_origin,
          \ 'same_window': win_getid() == g:keyboard_window, 'popups': popup_list(),
          \ 'original_options': g:keyboard_options,
          \ 'restored_options': [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen],
          \ 'filetype': &filetype, 'modified': &modified, 'line': getline(1)}
    call writefile([json_encode(result)], ''' + quoted(str(closed) + '.tmp') + r''')
    call rename(''' + quoted(str(closed) + '.tmp') + ', ' + quoted(closed) + r''')
    call timer_stop(a:timer)
  endif
endfunction
call timer_start(5, 'KeyboardObserve', {'repeat': -1})
''')
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        process = subprocess.Popen(
            [VIM, '-Nu', str(config or ROOT / '.vimrc'), '-i', 'NONE', '-n',
             '--cmd', f'autocmd VimEnter * call writefile([], {quoted(startup)})'],
            cwd=self.project, env=dict(self.env, TERM='xterm-256color'),
            stdin=slave, stdout=slave, stderr=slave,
        )
        os.close(slave)
        output = bytearray()

        def pump(seconds):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if select.select([master], [], [], min(0.003, max(0, deadline - time.monotonic())))[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        return

        def wait_file(path, timeout=4):
            deadline = time.monotonic() + timeout
            while not path.exists() and time.monotonic() < deadline and process.poll() is None:
                pump(0.005)
            self.assertTrue(path.exists(), repr(bytes(output[-2000:])))

        try:
            wait_file(startup)
            os.write(master, f':source {script}\r'.encode())
            wait_file(ready)
            if exercise_arrows:
                # A split escape sequence must remain an arrow, not cancel the search.
                os.write(master, b'\x1b')
                pump(0.01)
                os.write(master, b'[A\x1b[B\x0a\x0b')
                pump(0.15)
                self.assertFalse(closed.exists(), 'Arrow/Ctrl-j/Ctrl-k closed the search')
            started = time.monotonic()
            os.write(master, b'\x1b')
            wait_file(closed)
            elapsed = time.monotonic() - started
            result = json.loads(closed.read_text())
            os.write(master, b':qa!\r')
            deadline = time.monotonic() + 2
            while process.poll() is None and time.monotonic() < deadline:
                pump(0.01)
            self.assertEqual(process.wait(timeout=1), 0)
            return elapsed, result
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    @unittest.skipUnless(shutil.which('fzf'), 'Real keyboard latency test requires fzf')
    def test_real_keyboard_escape_latency_and_key_sequences(self):
        self.require_backends()
        (self.project / 'sample.py').write_text('needle\n')
        for command in ('VimFind', 'VimSearch'):
            for editing in (False, True):
                with self.subTest(command=command, editing=editing):
                    elapsed, result = self.keyboard_search(command, editing, exercise_arrows=True)
                    self.assertLess(elapsed, 0.2, f'Esc cancellation took {elapsed * 1000:.0f} ms')
                    self.assertTrue(result['same_buffer'])
                    self.assertTrue(result['same_window'])
                    self.assertEqual(result['popups'], [])
                    self.assertEqual(result['original_options'], result['restored_options'])
                    if editing:
                        self.assertEqual(result['line'], 'keep unsaved text')
                        self.assertTrue(result['modified'])
                    else:
                        self.assertEqual(result['filetype'], 'vimdashboard')

    @unittest.skipUnless(shutil.which('fzf'), 'Real keyboard latency test requires fzf')
    def test_real_keyboard_escape_in_split(self):
        self.require_backends()
        (self.project / 'sample.py').write_text('needle\n')
        elapsed, result = self.keyboard_search('VimFind', editing=True,
                                               exercise_arrows=True, config=self.split_config())
        self.assertLess(elapsed, 0.2, f'Esc cancellation took {elapsed * 1000:.0f} ms')
        self.assertTrue(result['same_buffer'])
        self.assertTrue(result['same_window'])
        self.assertEqual(result['original_options'], result['restored_options'])
        self.assertEqual(result['line'], 'keep unsaved text')
        self.assertTrue(result['modified'])

    @staticmethod
    def wait_fzf(prompt):
        return r'''
let terminal = winbufnr(popup_list()[0])
for attempt in range(200)
  call term_wait(terminal, 10)
  if stridx(TerminalScreen(terminal), ''' + quoted(prompt) + r''') >= 0 | break | endif
endfor
call assert_true(stridx(TerminalScreen(terminal), ''' + quoted(prompt) + r''') >= 0)
'''

    @unittest.skipUnless(shutil.which('fzf'), 'Real fzf UI requires manually installed fzf')
    def test_real_fzf_live_reload_selection_and_history(self):
        self.require_backends()
        target = self.project / 'src' / '中文 : file.py'
        target.write_text('before\nxx unique_needle\n')
        self.terminal_vim(r'''
execute 'edit ' . fnameescape(''' + quoted(self.project / 'origin.py') + r''')
VimSearch
''' + self.wait_fzf('Live grep>') + r'''
call term_sendkeys(terminal, 'no_such_match')
sleep 200m
call term_sendkeys(terminal, repeat("\x7f", strlen('no_such_match')) . 'unique_needle')
for attempt in range(200)
  call term_wait(terminal, 10)
  if TerminalScreen(terminal) =~# 'before' && TerminalScreen(terminal) =~# '1/1'
    break
  endif
endfor
call assert_match('1/1', TerminalScreen(terminal))
call assert_match('before', TerminalScreen(terminal))
call term_sendkeys(terminal, "\<C-u>\<C-d>")
call term_sendkeys(terminal, "\<CR>")
''' + self.wait_search() + r'''
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
call assert_equal([2, 4], [line('.'), col('.')])
call assert_true(filereadable($XDG_STATE_HOME . '/vim-lite/search/grep.history'))
''')

    @unittest.skipUnless(shutil.which('fzf'), 'Real fzf UI requires manually installed fzf')
    def test_real_fzf_file_fuzzy_matching_and_cancel(self):
        self.require_backends()
        target = self.project / 'long file name.py'
        target.write_text('preview_only_text\n')
        self.terminal_vim(r'''
execute 'cd ' . fnameescape(''' + quoted(self.project) + r''')
VimFind
''' + self.wait_fzf('Files>') + r'''
call term_sendkeys(terminal, 'lfnp')
for attempt in range(200)
  call term_wait(terminal, 10)
  if TerminalScreen(terminal) =~# '1/1' | break | endif
endfor
call assert_match('1/1', TerminalScreen(terminal))
call assert_notmatch('preview_only_text', TerminalScreen(terminal))
call term_sendkeys(terminal, "\<CR>")
''' + self.wait_search() + r'''
call assert_equal(''' + quoted(target) + r''', expand('%:p'))
let original = bufnr('%')
VimFind
''' + self.wait_fzf('Files>') + r'''
set columns=60 lines=18
doautocmd VimResized
call term_sendkeys(terminal, "\<Esc>")
''' + self.wait_search() + r'''
call assert_equal(original, bufnr('%'))
''')


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vim-lite-install-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.target = self.work / "user with spaces"

    def install(self, *options, env=None, expected=0):
        result = subprocess.run(
            [BASH, str(ROOT / "vim-install.sh"), "--target-dir", str(self.target), *options],
            cwd=self.work, env=env, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_offline_install_backup_and_idempotence(self):
        self.target.mkdir()
        external = self.work / "old vimrc"
        external.write_text('" original\n')
        (self.target / ".vimrc").symlink_to(external)
        colors = self.target / ".vim" / "colors"
        colors.mkdir(parents=True)
        dashboard = self.target / '.vim' / 'dashboard.vim'
        dashboard.write_text('" old dashboard\n')
        modules = [self.target / '.vim' / name for name in ('git.vim', 'terminal.vim', 'tree.vim')]
        for module in modules:
            module.write_text('" old module\n')
        (colors / "unrelated.vim").write_text('" leave alone\n')
        self.install("--config-only")
        self.assertEqual(external.read_text(), '" original\n')
        backups = list(self.target.glob(".vimrc.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue(backups[0].is_symlink())
        self.assertFalse((self.target / ".vimrc").is_symlink())
        self.assertEqual((self.target / ".vimrc").read_bytes(), (ROOT / ".vimrc").read_bytes())
        self.assertEqual(dashboard.read_bytes(), (ROOT / 'dashboard.vim').read_bytes())
        for name in ('search.vim', 'search.sh', 'lsp.vim', 'git.vim', 'terminal.vim', 'tree.vim'):
            self.assertEqual((self.target / '.vim' / name).read_bytes(), (ROOT / name).read_bytes())
        dashboard_backups = list(dashboard.parent.glob('dashboard.vim.bak.*'))
        self.assertEqual(len(dashboard_backups), 1)
        self.assertEqual(dashboard_backups[0].read_text(), '" old dashboard\n')
        module_backups = {module: list(module.parent.glob(module.name + '.bak.*')) for module in modules}
        for backups_for_module in module_backups.values():
            self.assertEqual(len(backups_for_module), 1)
            self.assertEqual(backups_for_module[0].read_text(), '" old module\n')
        for source in (ROOT / "colors").iterdir():
            self.assertEqual((colors / source.name).read_bytes(), source.read_bytes())
        plugin = self.target / '.vim' / 'vendor' / 'vim-lsp'
        for source in (ROOT / 'vendor' / 'vim-lsp').rglob('*'):
            if source.is_file():
                relative = source.relative_to(ROOT / 'vendor' / 'vim-lsp')
                self.assertEqual((plugin / relative).read_bytes(), source.read_bytes())
        result = subprocess.run(
            [VIM, '-Nu', str(self.target / '.vimrc'), '-i', 'NONE', '-n', '-es',
             '-c', 'if get(g:, "colors_name", "") !=# "tokyonight-night" | cquit | endif',
             '-c', 'Dashboard',
             '-c', 'if &filetype !=# "vimdashboard" | cquit | endif',
             '-c', f'if stridx(execute("scriptnames"), {quoted(dashboard)}) < 0 | cquit | endif',
             '-c', 'if !exists(":VimFind") || !exists(":VimSearch") || !exists(":Lexplore") | cquit | endif',
             '-c', 'if !exists(":VimGit") || !exists(":VimTerminal") | cquit | endif',
             '-c', 'if !exists(":VimLspStatus") || !exists(":LspDefinition") | cquit | endif',
             '-c', 'VimConfig',
             '-c', f'if expand("%:p") !=# {quoted(self.target / ".vimrc")} | cquit | endif',
             '-c', 'qa!'], capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.install("--config-only")
        self.assertEqual(list(self.target.glob(".vimrc.bak.*")), backups)
        self.assertEqual(list(dashboard.parent.glob('dashboard.vim.bak.*')), dashboard_backups)
        for module, backups_for_module in module_backups.items():
            self.assertEqual(list(module.parent.glob(module.name + '.bak.*')), backups_for_module)
        self.assertEqual((colors / "unrelated.vim").read_text(), '" leave alone\n')
        self.assertFalse(list(self.target.rglob("*.tmp.*")))
        self.assertFalse(list(plugin.parent.glob('vim-lsp.bak.*')))

    def test_plugin_upgrade_removes_stale_files_and_backs_up_symlink(self):
        self.install('--config-only')
        plugin = self.target / '.vim' / 'vendor' / 'vim-lsp'
        (plugin / 'stale.vim').write_text('old plugin file\n')
        (plugin / 'plugin' / 'lsp.vim').write_text('old client\n')
        unrelated = plugin.parent / 'unrelated-plugin'
        unrelated.mkdir()
        (unrelated / 'keep.vim').write_text('preserved\n')
        self.install('--config-only')
        self.assertFalse((plugin / 'stale.vim').exists())
        backups = list(plugin.parent.glob('vim-lsp.bak.*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'stale.vim').read_text(), 'old plugin file\n')
        self.assertEqual((unrelated / 'keep.vim').read_text(), 'preserved\n')
        external = self.work / 'external-plugin'
        plugin.rename(external)
        plugin.symlink_to(external, target_is_directory=True)
        self.install('--config-only')
        self.assertFalse(plugin.is_symlink())
        link_backups = [path for path in plugin.parent.glob('vim-lsp.bak.*') if path.is_symlink()]
        self.assertEqual(len(link_backups), 1)
        self.assertEqual(link_backups[0].resolve(), external)
        self.assertTrue((external / 'plugin' / 'lsp.vim').is_file())
        self.assertFalse(list(plugin.parent.glob('*.tmp.*')))

    def test_default_skips_package_manager_when_vim_exists(self):
        result = self.install()
        self.assertIn('Vim 已可用', result.stdout)

    def test_rejects_invalid_destination(self):
        (self.target / ".vimrc").mkdir(parents=True)
        self.install("--config-only", expected=1)
        self.assertTrue((self.target / ".vimrc").is_dir())

    def package_environment(self, fail=False):
        shims = self.work / "bin"
        shims.mkdir()
        (shims / "vim").write_text('#!/bin/sh\ntest -f "$VIM_LITE_TEST_READY"\n')
        (shims / "apt-get").write_text('''#!/bin/sh
printf '%s\n' "$*" >> "$VIM_LITE_TEST_LOG"
if [ "${VIM_LITE_TEST_FAIL:-0}" = 1 ]; then exit 42; fi
if [ "$1" = install ]; then touch "$VIM_LITE_TEST_READY"; fi
''')
        for shim in shims.iterdir():
            shim.chmod(0o755)
        env = os.environ.copy()
        env.update({
            "PATH": str(shims) + os.pathsep + env["PATH"],
            "VIM_LITE_TEST_READY": str(self.work / "ready"),
            "VIM_LITE_TEST_LOG": str(self.work / "packages.log"),
            "VIM_LITE_TEST_FAIL": "1" if fail else "0",
        })
        # Match sudo's role without involving the real system when run non-root.
        (shims / "sudo").write_text('#!/bin/sh\nexec "$@"\n')
        (shims / "sudo").chmod(0o755)
        return env

    def test_missing_vim_uses_mock_package_manager(self):
        self.install(env=self.package_environment())
        self.assertEqual((self.work / "packages.log").read_text(), 'update\ninstall -y vim\n')
        self.assertTrue((self.target / ".vimrc").exists())

    def test_package_failure_does_not_install_config(self):
        self.install(env=self.package_environment(fail=True), expected=42)
        self.assertFalse((self.target / ".vimrc").exists())

    def test_config_only_never_calls_package_manager(self):
        self.install("--config-only", env=self.package_environment(fail=True))
        self.assertFalse((self.work / "packages.log").exists())


if __name__ == "__main__":
    if not VIM or not BASH:
        raise SystemExit("Tests require Vim and Bash; no dependencies are downloaded.")
    sys.dont_write_bytecode = True
    from test_lsp import LspTests
    unittest.main(verbosity=2)
