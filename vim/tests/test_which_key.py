"""Real input regression checks for native mapping resolution and prefix hints."""

import unittest

from test_vim import ROOT, VimSession, quoted
from which_key_latency import KeySession


class WhichKeyTests(unittest.TestCase):
    def session(self, **options):
        session = KeySession(**options)
        self.addCleanup(session.close)
        return session

    def test_delayed_root_subgroup_and_native_dispatch(self):
        session = self.session(delay=120)
        session.send(' ')
        session.pump(.04)
        self.assertEqual(session.state['keys']['popup'], 0)
        state = session.wait(lambda state: state['keys']['popup'] > 0)
        self.assertIn('<Space>', state['popup_title'])
        self.assertIn('Buffer', '\n'.join(state['popup_lines']))
        self.assertEqual(state['windows'], 1)
        session.action('u', lambda state: '<Space>u' in state['popup_title'])
        state = session.state
        self.assertIn('a', '\n'.join(state['popup_lines']))
        self.assertNotIn('Buffer', '\n'.join(state['popup_lines']))
        session.action('a', lambda state: state['hits'] == 1 and not state['keys']['pending'])
        self.assertEqual(session.state['keys']['popup'], 0)
        self.assertEqual(session.state['keys']['timer'], -1)

    def test_fast_paths_no_flash_counts_registers_expr_remap_and_plug(self):
        session = self.session(delay=150)
        session.action('3"a ua', lambda state: state['hits'] == 3)
        self.assertEqual(session.state['register'], 'a')
        session.send('2 ')
        session.pump(.02)
        session.action('ua', lambda state: state['hits'] == 5)
        session.action(' ur', lambda state: state['hits'] == 6)
        session.action(' uv', lambda state: state['hits'] == 7)
        col = session.state['col']
        session.action(' ue', lambda state: state['expression'] == 1 and state['col'] == col + 1)
        self.assertFalse(any(state['keys']['popup'] for _, state in session.history))

    def test_visible_visual_selection_escape_and_following_input(self):
        session = self.session(delay=30)
        session.action('vll', lambda state: state['mode'] == 'v' and state['col'] == 3)
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        self.assertIn('选区', session.state['popup_title'])
        session.action('ua', lambda state: state['lines'][0].startswith('ONE')
                       and state['mode'] == 'n' and not state['keys']['pending'])
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.action(b'\x1b', lambda state: not state['keys']['pending'])
        self.assertEqual(session.state['col'], 1)
        session.action('l', lambda state: state['col'] == 2)
        self.assertEqual(session.state['keys']['popup'], 0)

    def test_native_timeout_unknown_key_and_no_timeout(self):
        session = self.session(delay=20, timeoutlen=100)
        session.command('call cursor(1, 1)')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        state = session.wait(lambda state: not state['keys']['pending'])
        self.assertEqual(state['col'], 2)
        session.command('call cursor(1, 1)')
        session.send(' ')
        session.pump(.01)
        session.action('l', lambda state: state['col'] == 3 and not state['keys']['pending'])
        session.command('set notimeout')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.pump(.15)
        self.assertTrue(session.state['keys']['pending'])
        session.action('ua', lambda state: state['hits'] == 1)

    def test_fragmented_terminal_keys_and_user_escape_mapping(self):
        session = self.session(delay=25)
        session.command('nnoremap <Space><Down> :let g:key_hits += 10<CR>')
        session.command('nnoremap <Space><C-F6>a :let g:key_hits += 100<CR>')
        session.command('VimWhichKeyRefresh')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.send(b'\x1b')
        session.pump(.008)
        self.assertTrue(session.state['keys']['pending'])
        session.action(b'[B', lambda state: state['hits'] == 10)
        session.command(r'call feedkeys(" \<C-F6>", "t")')
        session.wait(lambda state: '<C-F6>' in state['popup_title'])
        session.action('a', lambda state: state['hits'] == 110)
        session.command('nnoremap <Space><Esc> :let g:key_hits += 1<CR>')
        session.command('VimWhichKeyRefresh')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.action(b'\x1b', lambda state: state['hits'] == 111)
        self.assertEqual(session.state['keys']['escape_timer'], -1)

    def test_buffer_local_override_labels_and_refresh(self):
        session = self.session(delay=25)
        session.command("nnoremap <buffer> <Space>ua :let g:key_hits += 10<CR>")
        session.command("let g:vimrc_lite_which_key_labels = {'<Space>ua': '局部动作'}")
        session.command('VimWhichKeyRefresh')
        session.action(' u', lambda state: '<Space>u' in state['popup_title'])
        self.assertIn('局部动作', '\n'.join(session.state['popup_lines']))
        session.action('a', lambda state: state['hits'] == 10)
        session.command('enew')
        session.action(' ua', lambda state: state['hits'] == 11)
        session.command('buffer #')
        session.action(' ua', lambda state: state['hits'] == 21)
        session.command('setfiletype markdown')
        session.action(' m', lambda state: '<Space>m' in state['popup_title'])
        self.assertIn('Markdown', '\n'.join(session.state['popup_lines']))
        session.action(b'\x1b', lambda state: not state['keys']['pending'])

    def test_disable_reload_manual_and_external_popup_close(self):
        session = self.session(delay=30)
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.action(b'\x1b', lambda state: not state['keys']['pending'])
        session.command('VimWhichKeyDisable')
        session.action(' ua', lambda state: state['hits'] == 1)
        self.assertFalse(session.state['keys']['enabled'])
        session.command('VimWhichKeyEnable')
        session.command('source ' + str(ROOT / '.vimrc'))
        session.command('VimWhichKey <leader>u')
        session.wait(lambda state: '<Space>u' in state['popup_title'])
        session.action('a', lambda state: state['hits'] == 2)
        session.command('call timer_start(80, {timer -> popup_clear()})')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.wait(lambda state: state['keys']['popup'] == 0 and state['keys']['pending'])
        session.action('ua', lambda state: state['hits'] == 3)
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.action(b'\x03', lambda state: not state['keys']['pending'])

    def test_macro_record_replay_and_dot(self):
        session = self.session(delay=30)
        session.command('nunmap q')
        session.action('qa ua', lambda state: state['hits'] == 1)
        session.send(' ')
        session.pump(.07)
        self.assertEqual(session.state['keys']['popup'], 0)
        session.action('uaq', lambda state: state['hits'] == 2)
        session.action('3@a', lambda state: state['hits'] == 8)
        session.command("nnoremap <Space>ud x")
        session.command('VimWhichKeyRefresh')
        session.action(' ud', lambda state: state['lines'][0].startswith('ne '))
        session.action('.', lambda state: state['lines'][0].startswith('e '))
        self.assertFalse(any(state['keys']['popup'] for _, state in session.history))

    def test_custom_special_unicode_trigger_and_narrow_screen(self):
        session = self.session(delay=25, before=[
            "let g:vimrc_lite_which_key_triggers = ['<leader>', '<F6>']"])
        session.command('nnoremap <F6>中a :let g:key_hits += 1<CR>')
        session.command('VimWhichKeyRefresh')
        session.action(b'\x1b[17~', lambda state: '<F6>' in state['popup_title'])
        session.action('中', lambda state: '中' in state['popup_title'])
        session.action('a', lambda state: state['hits'] == 1)
        session.command('set columns=24 lines=10')
        session.action(' ', lambda state: state['keys']['popup'] > 0)
        session.action(b'\x1b', lambda state: not state['keys']['pending'])


class WhichKeyConfigurationTests(VimSession):
    def test_exact_prefix_user_mapping_is_preserved_and_idle_has_no_timer(self):
        personal = self.work / 'maps.vim'
        personal.write_text('nnoremap <nowait> <Space>b :let g:user_prefix = 1<CR>\n'
                            'nnoremap <Space>bzza :let g:long_prefix = 1<CR>\n')
        self.vim(r'''
VimWhichKeyRefresh
call assert_match('g:user_prefix', maparg(' b', 'n'))
call assert_equal('', maparg(' bz', 'n'))
call feedkeys(' b', 'xt')
call assert_equal(1, g:user_prefix)
call assert_match('Prefix(', maparg(' ', 'n'))
let original = [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen]
call assert_equal(0, VimWhichKeyStatus().pending)
call assert_equal(-1, VimWhichKeyStatus().timer)
VimWhichKeyDisable
call assert_equal('', maparg(' ', 'n'))
call assert_match('g:user_prefix', maparg(' b', 'n'))
VimWhichKeyEnable
call assert_match('Prefix(', maparg(' ', 'n'))
call assert_equal(original, [&timeout, &timeoutlen, &ttimeout, &ttimeoutlen])
VimKeys
call assert_equal(0, search('Prefix(', 'nw'))
''', before=['let g:vimrc_lite_mappings_file = ' + quoted(personal)])

    def test_feature_fallback_without_popup_and_installation(self):
        config = self.work / 'fallback'
        config.mkdir()
        for source in ROOT.glob('*.vim'):
            (config / source.name).symlink_to(source)
        (config / '.vimrc').write_text((ROOT / '.vimrc').read_text())
        module = config / 'which-key.vim'
        module.unlink()
        module.write_text((ROOT / 'which-key.vim').read_text().replace(
            "let s:supported = exists('*popup_create')", 'let s:supported = 0'))
        self.vim(r'''
call assert_false(VimWhichKeyStatus().supported)
call assert_equal('', maparg(' ', 'n'))
VimWhichKey
call assert_true(search('查找文件', 'nw') > 0)
''', config=config / '.vimrc')


if __name__ == '__main__':
    unittest.main(verbosity=2)
