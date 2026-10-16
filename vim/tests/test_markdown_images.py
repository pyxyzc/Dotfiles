"""Image clipboard/import and SSH browser upload insert at the original source anchor."""

import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_vim import ROOT, VimSession, quoted


PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXpUAAAAASUVORK5CYII=')
spec = importlib.util.spec_from_file_location('markdown_images', ROOT / 'markdown/images.py')
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


class MarkdownImageTests(VimSession):
    def test_windows_wsl_provider_reads_png_through_sta_powershell(self):
        def executable(name):
            return '/windows/powershell.exe' if name == 'powershell.exe' else None
        with patch.object(images.shutil, 'which', side_effect=executable), \
                patch.object(images.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, stdout=base64.b64encode(PNG))
            self.assertEqual(images.clipboard_image(), PNG)
            arguments = run.call_args.args[0]
            self.assertIn('-STA', arguments)
            self.assertIn('[System.Windows.Forms.Clipboard]::GetImage()', arguments[-1])

    def test_helper_saves_beside_document_with_no_overwrite_or_directory_escape(self):
        directory = self.work / 'notes'
        directory.mkdir()
        first = images.save_image(PNG, directory, name='screenshot')
        second = images.save_image(PNG, directory, name='screenshot')
        self.assertEqual(first['relative'], 'imgs/screenshot.png')
        self.assertEqual(second['relative'], 'imgs/screenshot-1.png')
        self.assertEqual(Path(first['path']).read_bytes(), PNG)
        for folder in ['../outside', str(self.work / 'outside')]:
            with self.assertRaises(ValueError):
                images.save_image(PNG, directory, folder)
        (directory / 'escape').symlink_to(self.work, target_is_directory=True)
        with self.assertRaises(ValueError):
            images.save_image(PNG, directory, 'escape')
        with self.assertRaises(ValueError):
            images.save_image(b'not an image', directory)

    def test_vim_image_import_keeps_png_bytes_and_supports_width_alignment(self):
        document = self.work / 'notes' / 'page.md'
        document.parent.mkdir()
        document.write_text('\nanchor\n')
        image = self.work / 'source.png'
        image.write_bytes(PNG)
        self.vim('edit ' + str(document) + '\ncall cursor(1,1)\nVimMarkdownImage ' + str(image) + r'''
for attempt in range(100)
  if getline(1) =~# '!\['
    break
  endif
  sleep 10m
endfor
call assert_match('!\[.*\](imgs/.*\.png)', getline(1))
call assert_equal(1, len(glob(expand('%:p:h') . '/imgs/*.png', 0, 1)))
VimMarkdownImageSize 60% center
call assert_match('{width=60% align=center}$', getline(1))
call assert_equal([], filter(prop_list(1), 'get(v:val, "type", "") ==# "VimMarkdownImageAnchor"'))
''')
        self.assertEqual(next((document.parent / 'imgs').glob('*.png')).read_bytes(), PNG)

    def test_clipboard_job_tracks_source_position_during_edits(self):
        document = self.work / 'clipboard.md'
        document.write_text('target\n')
        provider = self.work / 'clipboard.py'
        provider.write_text('import sys,time\ntime.sleep(.08)\nsys.stdout.buffer.write(' + repr(PNG) + ')\n')
        self.vim('edit ' + str(document) + '\nlet g:vimrc_lite_markdown_image_command = ['
                 + quoted(sys.executable) + ', ' + quoted(provider) + r''']
VimMarkdownImage
call append(0, 'new line')
for attempt in range(100)
  if getline(2) =~# '!\['
    break
  endif
  sleep 10m
endfor
call assert_equal('new line', getline(1))
call assert_match('!\[.*\](imgs/.*\.png)target', getline(2))
''')

    def test_ssh_preview_upload_writes_imgs_and_inserts_back_into_vim(self):
        document = self.work / 'remote.md'
        document.write_text('\nanchor\n')
        uploader = self.work / 'upload.py'
        uploader.write_text(r'''
import json,sys,time
from urllib.request import Request,urlopen
base=sys.argv[1]
for attempt in range(100):
    state=json.load(urlopen(base+'state'))
    if state.get('image_request'):break
    time.sleep(.01)
request=state['image_request']['id']
data=''' + repr(PNG) + r'''
result=json.load(urlopen(Request(base+'image?request='+str(request),data=data,
                                headers={'Content-Type':'image/png'})))
print(result['relative'])
''')
        self.vim('edit ' + str(document) + r'''
call cursor(1, 1)
VimMarkdownImage!
for attempt in range(100)
  if exists('g:vimrc_lite_markdown_preview_url')
    break
  endif
  sleep 10m
endfor
call append(0, 'edit during browser paste')
let result = system(''' + quoted(sys.executable) + r''' . ' ' . shellescape(''' + quoted(uploader)
                 + r''') . ' ' . shellescape(g:vimrc_lite_markdown_preview_url))
call assert_equal(0, v:shell_error, result)
for attempt in range(100)
  if getline(2) =~# '!\['
    break
  endif
  sleep 10m
endfor
call assert_equal('edit during browser paste', getline(1))
call assert_match('!\[.*\](imgs/.*\.png)', getline(2))
VimMarkdownStop
''')
        self.assertEqual(next((self.work / 'imgs').glob('*.png')).read_bytes(), PNG)
