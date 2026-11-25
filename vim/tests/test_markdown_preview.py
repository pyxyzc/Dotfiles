"""Offline preview assets, actual HTTP server, browser and Vim lifecycle."""

import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from test_vim import ROOT, VimSession, quoted
from test_markdown import WAIT


class PreviewTests(VimSession):
    def server(self):
        process = subprocess.Popen([sys.executable, str(ROOT / 'markdown/preview.py')],
                                   cwd=self.work, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, bufsize=1)
        self.addCleanup(self.close_server, process)
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'server did not start')
        url = json.loads(process.stdout.readline())['url']
        return process, url

    @staticmethod
    def close_server(process):
        if process.poll() is None:
            process.stdin.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()
        process.stderr.close()

    def update(self, process, text, **fields):
        payload = {'text': text, 'name': 'sample.md',
                   'root': str(self.work), 'path': str(self.work / 'sample.md'), **fields}
        process.stdin.write(json.dumps(payload) + '\n')
        process.stdin.flush()
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'missing update acknowledgement')
        self.assertIn('ack', json.loads(process.stdout.readline()))

    def test_pinned_assets_are_complete_and_unchanged(self):
        manifest = json.loads((ROOT / 'markdown/vendor/manifest.json').read_text())
        for name, expected in manifest[-1]['files'].items():
            with self.subTest(name=name):
                data = (ROOT / 'markdown/vendor' / name).read_bytes()
                self.assertEqual(expected, hashlib.sha256(data).hexdigest())

    def test_http_state_assets_images_and_path_boundaries(self):
        process, url = self.server()
        (self.work / 'image.png').write_bytes(b'png bytes')
        outside = self.work.parent / (self.work.name + '-outside.png')
        outside.write_bytes(b'outside')
        self.addCleanup(outside.unlink)
        (self.work / 'escape.png').symlink_to(outside)
        self.update(process, '# 中文\n\n$E=mc^2$', line=3)
        with urlopen(url + 'state', timeout=3) as response:
            state = json.load(response)
            self.assertEqual('# 中文\n\n$E=mc^2$', state['text'])
            self.assertEqual(3, state['line'])
            self.assertIn("script-src 'self'", response.headers['Content-Security-Policy'])
        with urlopen(url + 'state?document=' + str(state['document']), timeout=3) as response:
            self.assertNotIn('text', json.load(response))
        with urlopen(url + 'state?revision=' + str(state['revision']), timeout=3) as response:
            self.assertEqual(204, response.status)
        with urlopen(url + 'media/image.png', timeout=3) as response:
            self.assertEqual(b'png bytes', response.read())
        for route in ['media/escape.png', '../', 'vendor/SOURCE.md']:
            with self.subTest(route=route), self.assertRaises(HTTPError):
                urlopen(url + route, timeout=3)
        with self.assertRaises(HTTPError):
            urlopen(Request(url, headers={'Host': 'example.com'}), timeout=3)
        for asset in ['preview.js', 'preview.css', 'vendor/markdown-it.min.js']:
            with urlopen(url + asset, timeout=3) as response:
                self.assertEqual(200, response.status)
                self.assertGreater(len(response.read()), 100)

    def test_vim_unsaved_updates_stop_and_reload(self):
        fetch = self.work / 'fetch.py'
        fetch.write_text('import sys\nfrom urllib.request import urlopen\n'
                         'print(urlopen(sys.argv[1]+"state", timeout=2).read().decode())\n')
        self.vim(WAIT + r'''
function! FetchState(url) abort
  return json_decode(system('python3 ' . shellescape(''' + quoted(fetch) + r''')
        \ . ' ' . shellescape(a:url)))
endfunction
new sample.md
call setline(1, ['# 未保存', '', '- [ ] task'])
call WaitMd()
call assert_false(exists('*VimMarkdownPreviewStart'))
VimMarkdownPreview!
for attempt in range(200)
  sleep 5m
  if exists('g:vimrc_lite_markdown_preview_url')
    break
  endif
endfor
call assert_true(exists('g:vimrc_lite_markdown_preview_url'))
let url = g:vimrc_lite_markdown_preview_url
sleep 50m
let state = FetchState(url)
call assert_equal("# 未保存\n\n- [ ] task", state.text)
let revision = state.revision
normal! j
sleep 300m
let state = FetchState(url)
call assert_equal(revision, state.revision)
call setline(1, '# 新内容')
doautocmd TextChanged
new other.txt
sleep 350m
let state = FetchState(url)
call assert_match('新内容', state.text)
call assert_equal(2, state.line)
close
VimMarkdownStop
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
VimMarkdownPreview!
sleep 100m
setlocal filetype=text
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
setlocal filetype=markdown
call WaitMd()
VimMarkdownPreview!
sleep 100m
execute 'source ' . fnameescape(''' + quoted(ROOT / '.vimrc') + r''')
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
call WaitMd()
VimMarkdownPreview!
sleep 100m
bwipeout!
call assert_false(exists('g:vimrc_lite_markdown_preview_url'))
''')

    @unittest.skipUnless(os.environ.get('VIM_MARKDOWN_BROWSER_TEST') == '1',
                         'set VIM_MARKDOWN_BROWSER_TEST=1 to run real Chrome')
    def test_real_chrome_renders_offline_math_tables_code_and_tasks(self):
        chrome = os.environ.get('VIM_MARKDOWN_CHROME') or shutil.which('google-chrome')
        self.assertTrue(chrome, 'Chrome executable is required')
        process, url = self.server()
        self.update(process, '# 中文标题\n\n- [x] done\n\n> [!NOTE]\n> hello\n\n'
                    '| 名称 | value |\n| --- | --- |\n| 中文 | x |\n\n'
                    '```python\nprint("hello")\n```\n\n$E=mc^2$\n\n<script>alert(1)</script>')
        screenshot = self.work / 'preview.png'
        result = subprocess.run([chrome, '--headless', '--no-sandbox', '--disable-gpu',
                                 '--disable-dev-shm-usage', '--no-first-run',
                                 '--no-default-browser-check', '--window-size=1280,900',
                                 '--virtual-time-budget=3000', '--screenshot=' + str(screenshot),
                                 '--dump-dom', url], capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr[-2000:])
        for snippet in ['id="中文标题"', 'class="katex"', '<table ', 'task-list-item',
                        'hljs-', 'callout-note', '&lt;script&gt;alert(1)&lt;/script&gt;']:
            self.assertIn(snippet, result.stdout)
        destination = os.environ.get('VIM_MARKDOWN_SCREENSHOT')
        if destination:
            shutil.copyfile(screenshot, destination)

    @unittest.skipUnless(os.environ.get('VIM_MARKDOWN_BROWSER_TEST') == '1',
                         'set VIM_MARKDOWN_BROWSER_TEST=1 to run real Chrome')
    def test_real_chrome_refreshes_after_a_later_unsaved_snapshot(self):
        chrome = os.environ.get('VIM_MARKDOWN_CHROME') or shutil.which('google-chrome')
        self.assertTrue(chrome, 'Chrome executable is required')
        path = ROOT / 'markdown/preview.py'
        namespace = {'__name__': 'markdown_preview_test', '__file__': str(path)}
        exec(compile(path.read_text(), str(path), 'exec'), namespace)
        received = threading.Event()

        class TrackingHandler(namespace['PreviewHandler']):
            def do_GET(self):
                super().do_GET()
                if '/state?' in self.path:
                    received.set()

        server = namespace['PreviewServer']()
        server.RequestHandlerClass = TrackingHandler
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        payload = {'text': '# 旧标题', 'name': 'draft.md',
                   'path': str(self.work / 'draft.md'), 'root': str(self.work)}
        server.update(payload)
        url = f'http://127.0.0.1:{server.server_port}/{server.token}/'
        process = subprocess.Popen([chrome, '--headless', '--no-sandbox', '--disable-gpu',
                                    '--disable-dev-shm-usage', '--no-first-run',
                                    '--no-default-browser-check', '--virtual-time-budget=3000',
                                    '--dump-dom', url], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(received.wait(5), 'browser did not fetch the initial snapshot')
            server.update({**payload, 'text': '# 更新后\n\n$E=mc^2$\n\n第二段'})
            output, error = process.communicate(timeout=20)
            self.assertEqual(0, process.returncode, error[-2000:])
            self.assertIn('id="更新后"', output)
            self.assertIn('第二段', output)
            self.assertIn('class="katex"', output)
            self.assertNotIn('旧标题', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
