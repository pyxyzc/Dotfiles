#!/usr/bin/env python3
"""Offline regression checks; all writes stay in temporary directories."""

import base64
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import struct
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
VIM = shutil.which("vim")
BASH = shutil.which("bash")


def quoted(value):
    return "'" + str(value).replace("'", "''") + "'"


class VimTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vim-lite-tests-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

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
        for setting in before or []:
            command += ["--cmd", setting]
        result = subprocess.run(
            command + ["-S", str(script)], cwd=self.work,
            stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=20, start_new_session=True,
        )
        errors = report.read_text() if report.exists() else ""
        self.assertEqual(result.returncode, 0, errors + result.stdout + result.stderr)
        self.assertEqual(errors, "")
        return result

    def terminal_vim(self, body, args=(), before=(), stdin=None):
        """Send checks after VimEnter, so startup is not bypassed by -S/-c."""
        ready = self.work / 'ready'
        report = self.work / 'terminal-errors'
        for path in (ready, report):
            path.unlink(missing_ok=True)
        script = self.work / 'terminal-check.vim'
        script.write_text(
            'set nomore\ntry\n' + body + '\ncatch\n'
            "call add(v:errors, v:exception . ' at ' . v:throwpoint)\nendtry\n"
            f'call writefile(v:errors, {quoted(report)})\n'
            'if !empty(v:errors) | cquit | endif\nqa!\n', encoding='utf-8',
        )
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
        env = os.environ.copy()
        env['TERM'] = 'xterm-256color'
        command = [VIM, '-Nu', str(ROOT / '.vimrc'), '-i', 'NONE', '-n',
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
                             (report.read_text() if report.exists() else '') + repr(output[-2000:]))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
        self.assertEqual(report.read_text(), '')
        return output

    def test_dashboard_terminal_startup_and_new_file(self):
        output = self.terminal_vim(r'''
call assert_equal('vimdashboard', &filetype)
call assert_equal(['nofile', 'wipe', 0, 0, 0], [&buftype, &bufhidden, &buflisted, &swapfile, &modifiable])
call assert_equal([0, 0, 0, 0], [&number, &relativenumber, &laststatus, &cursorline])
let content = map(filter(getline(1, '$'), '!empty(v:val)'), 'substitute(v:val, "^ *", "", "")')
call assert_equal(['Les annees heureuses sont des annees perdues.'], content)
call assert_equal(0, synID(line('$'), 1, 1))
let slogan = synID(line('$'), match(getline('$'), '\S') + 1, 1)
call assert_equal('VimDashboardSlogan', synIDattr(slogan, 'name'))
for mode in ['gui', 'cterm']
  call assert_equal('1', synIDattr(slogan, 'italic', mode))
  call assert_equal('', synIDattr(slogan, 'bg', mode))
  call assert_equal('', synIDattr(slogan, 'reverse', mode))
  call assert_equal('', synIDattr(slogan, 'underline', mode))
endfor
for key in ['f', 'n', 'e', 'r', 't', 'c', 'q', 'j', 'k', "\<Down>", "\<Up>", "\<CR>"]
  call assert_false(get(maparg(key, 'n', 0, 1), 'buffer', 0), key)
endfor
let home = bufnr('%')
call feedkeys("\<Space>bnihello\<Esc>", 'xt')
call assert_equal('hello', getline(1))
call assert_equal('', &buftype)
call assert_false(bufexists(home))
call assert_equal([1, 1, 2, 1], [&number, &relativenumber, &laststatus, &cursorline])
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
let settings = [&number, &relativenumber, &foldcolumn, &signcolumn, &list, &wrap, &fillchars]
Dashboard
let home = bufnr('%')
call assert_equal(0, &laststatus)
Dashboard
call assert_equal(home, bufnr('%'))
call assert_true(bufexists(original))
call assert_equal(['keep this'], getbufline(original, 1, '$'))
call assert_true(getbufvar(original, '&modified'))
vsplit
call assert_equal(1, &laststatus)
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
colorscheme tokyonight-night
call assert_equal('1', synIDattr(synID(line('$'), match(getline('$'), '\S') + 1, 1), 'italic', 'gui'))
call feedkeys("\<Space>bnitext\<Esc>", 'xt')
call assert_equal('text', getline(1))
call assert_equal([1, 1, 2], [&number, &relativenumber, &laststatus])
''')

    def test_startup_and_theme(self):
        self.vim(r'''
call assert_equal('tokyonight-night', g:colors_name)
call assert_equal('', &packpath)
call assert_equal($VIMRUNTIME, split(&runtimepath, ',')[0])
call assert_equal(2, len(split(&runtimepath, ',')))
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

    def test_literal_search_paths_filters_and_lists(self):
        needle = r"needle/a\b|x"
        (self.work / "src with spaces").mkdir()
        filename = self.work / "src with spaces" / "中文 | file.cpp"
        filename.write_text("first\n" + needle + "\n")
        (self.work / "build").mkdir()
        (self.work / "build" / "ignored.cpp").write_text(needle)
        (self.work / "notes.txt").write_text(needle)
        self.vim("let needle = " + quoted(needle) + r'''
call Call('Grep', [needle, ''])
let results = getqflist()
call assert_equal(1, len(results))
call assert_equal(2, results[0].lnum)
call assert_match('中文 | file.cpp$', bufname(results[0].bufnr))
call assert_true(getqflist({'winid': 0}).winid > 0)
call Call('ToggleList', [0])
call assert_equal(0, getqflist({'winid': 0}).winid)
call Call('ToggleList', [0])
call assert_true(getqflist({'winid': 0}).winid > 0)
cclose
call Call('Grep', [needle, 'src with spaces/*.cpp'])
call assert_equal(1, len(getqflist()))
call Call('Grep', [needle, 'notes.txt'])
call assert_equal('notes.txt', bufname(getqflist()[0].bufnr))
call Call('Grep', ['not present', ''])
call assert_equal([], getqflist())
call assert_equal(0, getqflist({'winid': 0}).winid)
call Call('Grep', [needle, 'missing/*.py'])
call assert_equal([], getqflist())
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
  for attempt in range(20)
    call term_wait(terminal, 50)
    if term_getstatus(terminal) !~# 'running' | break | endif
  endfor
  call assert_notmatch('running', term_getstatus(terminal))
  bwipeout!
endif
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
        (colors / "unrelated.vim").write_text('" leave alone\n')
        self.install("--config-only")
        self.assertEqual(external.read_text(), '" original\n')
        backups = list(self.target.glob(".vimrc.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue(backups[0].is_symlink())
        self.assertFalse((self.target / ".vimrc").is_symlink())
        self.assertEqual((self.target / ".vimrc").read_bytes(), (ROOT / ".vimrc").read_bytes())
        self.assertEqual(dashboard.read_bytes(), (ROOT / 'dashboard.vim').read_bytes())
        dashboard_backups = list(dashboard.parent.glob('dashboard.vim.bak.*'))
        self.assertEqual(len(dashboard_backups), 1)
        self.assertEqual(dashboard_backups[0].read_text(), '" old dashboard\n')
        for source in (ROOT / "colors").iterdir():
            self.assertEqual((colors / source.name).read_bytes(), source.read_bytes())
        result = subprocess.run(
            [VIM, '-Nu', str(self.target / '.vimrc'), '-i', 'NONE', '-n', '-es',
             '-c', 'if get(g:, "colors_name", "") !=# "tokyonight-night" | cquit | endif',
             '-c', 'Dashboard',
             '-c', 'if &filetype !=# "vimdashboard" | cquit | endif',
             '-c', f'if stridx(execute("scriptnames"), {quoted(dashboard)}) < 0 | cquit | endif',
             '-c', 'VimConfig',
             '-c', f'if expand("%:p") !=# {quoted(self.target / ".vimrc")} | cquit | endif',
             '-c', 'qa!'], capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.install("--config-only")
        self.assertEqual(list(self.target.glob(".vimrc.bak.*")), backups)
        self.assertEqual(list(dashboard.parent.glob('dashboard.vim.bak.*')), dashboard_backups)
        self.assertEqual((colors / "unrelated.vim").read_text(), '" leave alone\n')
        self.assertFalse(list(self.target.rglob("*.tmp.*")))

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
    unittest.main(verbosity=2)
