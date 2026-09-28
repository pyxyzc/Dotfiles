"""Clipboard output is complete, normalized and isolated from the real terminal."""

import unittest

from clipboard_latency import benchmark
from test_vim import ROOT, VimSession, quoted


class ClipboardTests(VimSession):
    def test_encoder_normalizes_crlf_and_blank_output_lines(self):
        tools = self.work / 'tools'
        tools.mkdir()
        encoder = tools / 'base64'
        encoder.write_text("#!/bin/sh\nprintf 'Y\\r\\n\\r\\nW\\r\\nJj\\r\\n'\n")
        encoder.chmod(0o755)
        self.vim(r'''
let clipboard = matchstr(execute('command VimCopyContent'), '<SNR>\d\+_')
let saved_path = $PATH
let $PATH = ''' + quoted(tools) + r'''
try
  call assert_equal("\e]52;c;YWJj\x07", call(function(clipboard . 'Osc52'), ['abc']))
finally
  let $PATH = saved_path
endtry
''')

    def test_encoder_failure_preserves_register_and_reports_error(self):
        tools = self.work / 'tools'
        tools.mkdir()
        encoder = tools / 'base64'
        encoder.write_text("#!/bin/sh\nprintf 'YWJj\\n'\nexit 7\n")
        encoder.chmod(0o755)
        self.vim(r'''
let clipboard = matchstr(execute('command VimCopyContent'), '<SNR>\d\+_')
let saved_path = $PATH
let $PATH = ''' + quoted(tools) + r'''
try
  let g:vimrc_lite_osc52 = 1
  call call(function(clipboard . 'Copy'), ['abc', 'v'])
  call assert_equal('abc', getreg('"'))
  call assert_match('base64 failed; content remains in the Vim register', execute('messages'))
finally
  let $PATH = saved_path
endtry
''')

    def test_empty_text_encodes_empty_osc_payload(self):
        self.vim(r'''
let clipboard = matchstr(execute('command VimCopyContent'), '<SNR>\d\+_')
call assert_equal("\e]52;c;\x07", call(function(clipboard . 'Osc52'), ['']))
''')


class ClipboardPtyTests(unittest.TestCase):
    def test_multiple_large_frames_arrive_complete(self):
        result = benchmark(ROOT / '.vimrc', lines=5000, rounds=3)
        self.assertEqual(115000, result['payload_bytes'])
        self.assertEqual(3, result['validated_frames'])
