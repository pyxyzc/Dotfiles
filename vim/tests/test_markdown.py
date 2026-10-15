"""Markdown editor workflows, private preview transport and real browser rendering."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from test_vim import ROOT, VimSession, quoted


class MarkdownTests(VimSession):
    def test_reading_view_and_buffer_local_keys(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['# Heading', '- [ ] todo', '- [x] done', '```', '# literal', '```', ''])
call assert_equal(2, &l:conceallevel)
call assert_equal(2, &l:shiftwidth)
call assert_true(&l:wrap && &l:linebreak && &l:breakindent)
call assert_equal(0, &l:textwidth)
call assert_equal(1, maparg(' mp', 'n', 0, 1).buffer)
call cursor(7, 1)
call assert_equal('▎', synconcealed(1, 1)[1])
call assert_equal('□', synconcealed(2, 3)[1])
call assert_equal('✓', synconcealed(3, 3)[1])
call assert_equal(0, synconcealed(5, 1)[0])
call assert_match('markdownCode', synIDattr(synID(5, 1, 1), 'name'))
call assert_equal('#7aa2f7', synIDattr(hlID('markdownH1'), 'fg', 'gui'))
call assert_equal('#bb9af7', synIDattr(hlID('markdownH2'), 'fg', 'gui'))
VimMarkdownRender
call assert_equal(0, &l:conceallevel)
VimMarkdownRender
call assert_equal(2, &l:conceallevel)
setfiletype python
setlocal filetype=python
doautocmd FileType python
call assert_equal('', maparg(' mp', 'n'))
call assert_equal('', maparg('j', 'n'))
''')

    def test_navigation_ignores_yaml_code_and_longer_fences(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['---', '# metadata', '---', '# One', '````', '# code', '```',
      \ '# still code', '`````', '## Two', '', 'Setext', '------', '    # indented'])
call cursor(1, 1)
normal ]h
call assert_equal(4, line('.'))
normal ]h
call assert_equal(10, line('.'))
normal ]h
call assert_equal(12, line('.'))
normal 2[h
call assert_equal(4, line('.'))
call assert_equal('# One', getline('.'))
''')

    def test_lists_continue_exit_reset_tasks_and_preserve_code(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, '- [x] shipped')
call feedkeys("A\<CR>next\<Esc>", 'xt')
call assert_equal(['- [x] shipped', '- [ ] next'], getline(1, '$'))
%delete _
call setline(1, '9) item')
call feedkeys("A\<CR>next\<Esc>", 'xt')
call assert_equal(['9) item', '10) next'], getline(1, '$'))
%delete _
call setline(1, '  > - item')
call feedkeys("A\<CR>next\<Esc>", 'xt')
call assert_equal(['  > - item', '  > - next'], getline(1, '$'))
%delete _
call setline(1, '- [ ] ')
call feedkeys("A\<CR>text\<Esc>", 'xt')
call assert_equal(['', 'text'], getline(1, '$'))
%delete _
call setline(1, ['```', '- code', '```'])
call cursor(2, 1)
call feedkeys("A\<CR>plain\<Esc>", 'xt')
call assert_equal(['```', '- code', 'plain', '```'], getline(1, '$'))
''')

    def test_tasks_range_is_one_undo_and_does_not_edit_code(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['- first', '- [ ] second', 'plain', '```', '- [ ] code', '```'])
call feedkeys("A \<BS>\<Esc>", 'xt')
let original = getline(1, '$')
1,6VimMarkdownTask
call assert_equal(['- [ ] first', '- [x] second', 'plain', '```', '- [ ] code', '```'],
      \ getline(1, '$'))
undo
call assert_equal(original, getline(1, '$'))
setlocal readonly
1,6VimMarkdownTask
call assert_equal(original, getline(1, '$'))
''')

    def test_table_unicode_escape_codespan_and_idempotence(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['| 项目 | Value |', '| :--- | ---: |', '| 中文 | ``a|b`` |',
      \ '| x\|y | z |'])
call cursor(3, 2)
VimMarkdownTable
let first = getline(1, '$')
call assert_equal('| 中文 | ``a|b`` |', first[2])
call assert_equal('| x\|y | z       |', first[3])
call assert_equal(strdisplaywidth(first[0]), strdisplaywidth(first[2]))
let tick = b:changedtick
VimMarkdownTable
call assert_equal(first, getline(1, '$'))
call assert_equal(tick, b:changedtick)
''')

    def test_outline_refresh_and_jump_preserve_source(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['# First', '', '## 第二章'])
let source = bufnr('%')
let sourcewin = win_getid()
VimMarkdownOutline
call assert_equal('nofile', &buftype)
call assert_equal(5, line('$'))
let outlinewin = win_getid()
call win_gotoid(sourcewin)
enew
setfiletype python
call setline(1, 'unsaved Python')
call win_gotoid(outlinewin)
call cursor(5, 1)
call feedkeys("\<CR>", 'xt')
call assert_equal(source, bufnr('%'))
call assert_equal(3, line('.'))
call setline(3, '## 新标题')
doautocmd TextChanged
sleep 200m
VimMarkdownOutline
call assert_match('新标题', getline(5))
normal q
call assert_equal(source, bufnr('%'))
call assert_equal(['# First', '', '## 新标题'], getline(1, '$'))
''')

    def test_focus_restores_on_buffer_change_and_reload(self):
        self.vim(r'''
enew
setfiletype markdown
setlocal number relativenumber signcolumn=auto colorcolumn=80 cursorline
VimMarkdownFocus
call assert_false(&l:number || &l:relativenumber || &l:cursorline)
call assert_equal('no', &l:signcolumn)
VimMarkdownFocus
call assert_true(&l:number && &l:relativenumber && &l:cursorline)
call assert_equal('80', &l:colorcolumn)
VimMarkdownFocus
enew
setfiletype python
call assert_false(exists('w:vimrc_lite_markdown_focus'))
call assert_true(&l:number)
''')

    def test_reload_closes_outline_and_preview_and_keeps_keys_working(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, '# Document')
let source = bufnr('%')
VimMarkdownOutline
let outline = bufnr('%')
normal q
VimMarkdownPreview!
let deadline = reltime()
while !exists('g:vimrc_lite_markdown_preview_url') && reltimefloat(reltime(deadline)) < 3
  sleep 10m
endwhile
call assert_true(exists('g:vimrc_lite_markdown_preview_url'))
VimMarkdownFocus
''' + 'execute "source " . fnameescape(' + quoted(ROOT / '.vimrc') + ')' + r'''
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
call assert_false(exists('w:vimrc_lite_markdown_focus'))
call assert_true(&l:number)
call assert_equal(2, &l:conceallevel)
call assert_equal(source, bufnr('%'))
call assert_equal(':VimMarkdownPreview<CR>', maparg(' mp', 'n'))
VimMarkdownOutline
call assert_equal(4, line('$'))
normal q
''')

    def test_offline_installed_module_previews_without_repo_runtime(self):
        target = self.work / 'installed home'
        result = subprocess.run(['bash', str(ROOT / 'vim-install.sh'), '--config-only',
                                 '--target-dir', str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.vim(r'''
enew
setfiletype markdown
call setline(1, '# Installed')
VimMarkdownPreview!
let deadline = reltime()
while !exists('g:vimrc_lite_markdown_preview_url') && reltimefloat(reltime(deadline)) < 3
  sleep 10m
endwhile
call assert_true(exists('g:vimrc_lite_markdown_preview_url'))
let scripts = execute('scriptnames')
''' + f"call assert_match(escape({quoted(target / '.vim/markdown.vim')}, '\\'), scripts)\n"
             + r'''
call assert_equal('▎', synconcealed(1, 1)[1])
VimMarkdownStop
''', config=target / '.vimrc', before=['let g:vimrc_lite_local_config = 0'])

    def test_templates_and_multibyte_visual_format(self):
        self.vim(r'''
enew
setfiletype markdown
VimMarkdownInsert code python
call assert_equal(['```python', '', '```'], getline(1, '$'))
call assert_equal(2, line('.'))
%delete _
call setline(1, '中文 text')
normal! gg0vl
call feedkeys(" mb", 'xt')
call assert_equal('**中文** text', getline(1))
call assert_equal(['code', 'table', 'link', 'image', 'note', 'math'],
      \ getcompletion('VimMarkdownInsert ', 'cmdline'))
''')

    def test_native_fenced_languages_highlight_and_protect_tasks(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['```python', 'def hello():', '  return 42', '- [ ] literal', '```'])
call assert_equal('pythonStatement', synIDattr(synID(2, 1, 1), 'name'))
let original = getline(1, '$')
1,5VimMarkdownTask
call assert_equal(original, getline(1, '$'))
call cursor(4, 1)
call feedkeys("A\<CR>plain\<Esc>", 'xt')
call assert_equal('plain', getline(5))
call assert_equal([], get(g:, 'markdown_fenced_languages', []))
call assert_equal('', v:errmsg)
%delete _
call setline(1, ['~~~bash', '- [ ] literal', '~~~~', '- [ ] task', ''])
setlocal syntax=markdown
call assert_true(index(map(synstack(2, 1), 'synIDattr(v:val, "name")'),
      \ 'VimMarkdownCode_sh') >= 0)
2VimMarkdownTask
call assert_equal('- [ ] literal', getline(2))
4VimMarkdownTask
call assert_equal('- [x] task', getline(4))
call assert_equal('', v:errmsg)
''')

    def test_link_opens_filename_with_spaces_and_anchor(self):
        linked = self.work / '中文 document.md'
        linked.write_text('# Destination\n')
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['# 中文 标题', '[jump](#%E4%B8%AD%E6%96%87-标题)',
      \ '[file](%E4%B8%AD%E6%96%87%20document.md)'])
call cursor(2, 3)
VimMarkdownLink
call assert_equal(1, line('.'))
call cursor(3, 3)
VimMarkdownLink
call assert_equal('中文 document.md', expand('%:t'))
call assert_equal('# Destination', getline(1))
''')

    def test_vim_streams_unsaved_updates_switches_source_and_stops(self):
        fetch = self.work / 'fetch.py'
        report = self.work / 'state.json'
        fetch.write_text('import sys, urllib.request\n'
                         'data=urllib.request.urlopen(sys.argv[1]+"state").read()\n'
                         'open(sys.argv[2],"wb").write(data)\n')
        self.vim(r'''
enew
setfiletype markdown
call setline(1, '# unsaved')
VimMarkdownPreview!
let deadline = reltime()
while !exists('g:vimrc_lite_markdown_preview_url') && reltimefloat(reltime(deadline)) < 3
  sleep 10m
endwhile
call assert_true(exists('g:vimrc_lite_markdown_preview_url'))
let url = g:vimrc_lite_markdown_preview_url
''' + f"call system('python3 ' . shellescape({quoted(fetch)}) . ' ' . shellescape(url)"
                        f" . ' ' . shellescape({quoted(report)}))\n"
             + f"let state = json_decode(join(readfile({quoted(report)}), \"\\n\"))\n"
             + r'''
call assert_equal('# unsaved', state.text)
call setline(1, '# changed without saving')
doautocmd TextChanged
sleep 200m
''' + f"call system('python3 ' . shellescape({quoted(fetch)}) . ' ' . shellescape(url)"
                        f" . ' ' . shellescape({quoted(report)}))\n"
             + f"call assert_equal('# changed without saving', "
               f"json_decode(join(readfile({quoted(report)}), \"\\n\")).text)\n"
             + r'''
enew
setfiletype markdown
call setline(1, '# another buffer')
VimMarkdownPreview!
call assert_equal(url, g:vimrc_lite_markdown_preview_url)
''' + f"call system('python3 ' . shellescape({quoted(fetch)}) . ' ' . shellescape(url)"
                        f" . ' ' . shellescape({quoted(report)}))\n"
             + f"call assert_equal('# another buffer', "
               f"json_decode(join(readfile({quoted(report)}), \"\\n\")).text)\n"
             + r'''
VimMarkdownStop
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
sleep 100m
''' + f"call system('python3 ' . shellescape({quoted(fetch)}) . ' ' . shellescape(url)"
                        f" . ' ' . shellescape({quoted(report)}) . ' 2>/dev/null')\n"
             + r'''
call assert_notequal(0, v:shell_error)
''')


class PreviewTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vim-markdown-preview-')
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.process = subprocess.Popen([sys.executable, '-B', str(ROOT / 'markdown/preview.py')],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop)
        self.url = json.loads(self.process.stdout.readline())['url']

    def stop(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=4)
        self.process.stdout.close()
        self.process.stderr.close()

    def update(self, text, name='draft.md', line=1):
        payload = {'text': text, 'root': str(self.work), 'path': str(self.work / name),
                   'name': name, 'line': line}
        self.process.stdin.write(json.dumps(payload) + '\n')
        self.process.stdin.flush()
        for _ in range(100):
            state = json.load(urlopen(self.url + 'state'))
            if state['text'] == text:
                return state
            time.sleep(.01)
        self.fail('preview update timed out')

    def test_private_routes_images_traversal_symlinks_and_incremental_updates(self):
        self.work.joinpath('image.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
        self.work.joinpath('secret.txt').write_text('secret')
        self.work.joinpath('escape.svg').symlink_to('/etc/passwd')
        state = self.update('# Draft\n\n未保存')
        response = urlopen(self.url + 'media/image.svg')
        self.assertIn('image/svg+xml', response.headers['Content-Type'])
        self.assertIn("script-src 'self'", response.headers['Content-Security-Policy'])
        for path in ['media/secret.txt', 'media/escape.svg', 'media/../secret.txt',
                     '../preview.py', 'preview.py']:
            with self.assertRaises(HTTPError):
                urlopen(self.url + path)
        with self.assertRaises(HTTPError):
            urlopen(Request(self.url + 'state', headers={'Host': 'evil.example'}))
        self.assertEqual(urlopen(self.url + f"state?revision={state['revision']}").status, 204)
        incremental = json.load(urlopen(self.url + f"state?document={state['document']}"))
        self.assertNotIn('text', incremental)
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=3), 0)

    def test_vendored_integrity_and_font_references(self):
        vendor = ROOT / 'markdown/vendor'
        manifest = json.loads((vendor / 'manifest.json').read_text())
        for name, digest in manifest[-1]['files'].items():
            self.assertEqual(hashlib.sha256((vendor / name).read_bytes()).hexdigest(), digest, name)
        import re
        for font in re.findall(r'url\((fonts/[^)]+)\)', (vendor / 'katex.min.css').read_text()):
            self.assertTrue((vendor / font).is_file(), font)


@unittest.skipUnless(os.environ.get('VIM_MARKDOWN_BROWSER_TEST'),
                     'set VIM_MARKDOWN_BROWSER_TEST=1 and install playwright to test Chrome')
class PreviewBrowserTests(PreviewTransportTests):
    def test_browser_render_live_changes_controls_scroll_and_mobile(self):
        from playwright.sync_api import sync_playwright
        text = (ROOT / 'markdown/example.md').read_text()
        text += '\n![local](image.svg)\n\n<script>window.pwned=true</script>\n'
        self.work.joinpath('image.svg').write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" width="30" height="30"><rect width="30" height="30" fill="#7aa2f7"/></svg>')
        self.update(text)
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=os.environ.get('VIM_MARKDOWN_CHROME', '/opt/google/chrome/chrome'),
                headless=True, args=['--no-sandbox'])
            context = browser.new_context(viewport={'width': 1440, 'height': 1000},
                                          permissions=['clipboard-read', 'clipboard-write'])
            page = context.new_page()
            errors, external = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: external.append(request.url)
                    if not request.url.startswith(self.url) and not request.url.startswith('data:') else None)
            page.goto(self.url)
            page.wait_for_selector('h1')
            self.assertEqual(page.locator('h1').inner_text(), '把想法，写成文档')
            self.assertEqual(page.locator('.task-list-item').count(), 3)
            self.assertEqual(page.locator('.callout').count(), 2)
            self.assertEqual(page.locator('.katex').count(), 2)
            self.assertGreater(page.locator('.hljs-keyword').count(), 0)
            self.assertEqual(page.locator('#outline a').count(), 6)
            page.wait_for_function('document.querySelector("img").naturalWidth === 30')
            self.assertFalse(page.evaluate('Boolean(window.pwned)'))
            page.locator('.copy-code').click()
            self.assertEqual(page.evaluate('navigator.clipboard.readText()'),
                             page.locator('pre code').inner_text())
            page.locator('#follow').click()
            self.assertEqual(page.locator('#follow').get_attribute('aria-pressed'), 'false')
            page.locator('#outline a').last.click()
            self.assertGreater(page.evaluate('window.scrollY'), 100)
            self.update(text + '\n## Live update\n\n新的段落', line=70)
            page.wait_for_selector('#live-update')
            page.locator('#follow').click()
            page.wait_for_timeout(300)
            self.assertGreater(page.evaluate('window.scrollY'), 100)
            page.locator('#follow').click()
            page.evaluate('window.scrollTo(0, 0)')
            page.screenshot(path=os.environ.get('VIM_MARKDOWN_SCREENSHOT', '/tmp/vim-markdown-preview.png'), full_page=True)
            page.set_viewport_size({'width': 390, 'height': 844})
            page.locator('#outline-toggle').click()
            self.assertTrue(page.locator('#sidebar').is_visible())
            page.locator('#outline-toggle').click()
            self.assertFalse(page.locator('#sidebar').is_visible())
            self.assertEqual(page.evaluate('document.documentElement.scrollWidth'), 390)
            page.emulate_media(media='print')
            self.assertFalse(page.locator('.toolbar').is_visible())
            pdf = self.work / 'preview.pdf'
            page.pdf(path=str(pdf), format='A4', print_background=True)
            self.assertTrue(pdf.read_bytes().startswith(b'%PDF'))
            self.assertGreater(pdf.stat().st_size, 1000)
            self.assertEqual(external, [])
            self.assertEqual(errors, [])
            browser.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
