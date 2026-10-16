"""Real input regression checks for native mapping resolution and prefix hints."""

import unittest

from test_vim import ROOT, VimSession, quoted
from which_key_latency import KeySession, menu_shown


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
        self.assertIn('SPC', state['popup_title'])
        self.assertIn('Buffer', '\n'.join(state['popup_lines']))
        self.assertEqual(state['windows'], 1)
        session.action('u', lambda state: menu_shown(state, '<Space>u'))
        state = session.state
        self.assertIn('a', '\n'.join(state['popup_lines']))
        self.assertNotIn('Buffer', '\n'.join(state['popup_lines']))
        session.action('a', lambda state: state['hits'] == 1 and not state['keys']['pending'])
        self.assertEqual(session.state['keys']['popup'], 0)
        self.assertEqual(session.state['keys']['timer'], -1)

    def test_bottom_panel_stays_open_and_reuses_window_when_group_changes(self):
        session = self.session(delay=25, timeoutlen=120, columns=180, rows=40)
        original = session.state['timeout']
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        popup = session.state['keys']['popup']
        position = session.state['popup_position']
        self.assertEqual(position['col'], 1)
        self.assertEqual(position['width'], 180)
        self.assertEqual(position['line'] + position['height'] - 1, 39)
        self.assertIn('→', '\n'.join(session.state['popup_lines']))
        session.pump(.6)
        self.assertEqual(session.state['keys']['popup'], popup)
        self.assertEqual(session.state['col'], 1)
        self.assertEqual(session.state['keys']['timer'], -1)
        self.assertEqual(session.state['keys']['escape_timer'], -1)
        start = len(session.history)
        output_start = len(session.screen)
        session.action('b', lambda state: menu_shown(state, '<Space>b'))
        session.pump(.3)
        for key in ['line', 'col', 'width', 'height', 'core_width', 'core_height']:
            self.assertEqual(session.state['popup_position'][key], position[key], key)
        self.assertTrue(all(state['keys']['popup'] == popup for _, state in session.history[start:]))
        self.assertIn('新建 buffer', '\n'.join(session.state['popup_lines']))
        self.assertNotIn(b'\x1b[2J', session.screen[output_start:])
        session.action(b'\x1b', lambda state: not state['keys']['pending'])
        self.assertEqual(session.state['timeout'], original)
        self.assertFalse(session.state['keys']['held'])

    def test_fragmented_function_key_keeps_the_same_panel_visible(self):
        session = self.session(delay=25, timeoutlen=100)
        session.command('nnoremap <Space><F6>a :let g:key_hits += 1<CR>')
        session.command('VimWhichKeyRefresh')
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        popup = session.state['keys']['popup']
        session.send(b'\x1b')
        session.pump(.008)
        self.assertEqual(session.state['keys']['popup'], popup)
        session.action(b'[17~', lambda state: menu_shown(state, '<Space><F6>'))
        self.assertEqual(session.state['keys']['popup'], popup)
        session.pump(.25)
        session.action('a', lambda state: state['hits'] == 1 and not state['keys']['held'])
        self.assertEqual(session.state['timeout'], [1, 100, 1, 30])

    def test_sticky_count_register_dispatch_and_narrow_panel_paging(self):
        session = self.session(delay=25, timeoutlen=100, columns=36, rows=10)
        original = session.state['timeout']
        session.action('5"a ', lambda state: menu_shown(state, '<Space>'))
        popup = session.state['keys']['popup']
        first = session.state['popup_lines'][2:-2]
        session.action(b'\x04', lambda state: state['popup_lines'][2:-2] != first)
        self.assertEqual(session.state['keys']['popup'], popup)
        session.action(b'\x15', lambda state: state['popup_lines'][2:-2] == first)
        session.pump(.25)
        session.action('ua', lambda state: state['hits'] == 5 and not state['keys']['pending'])
        self.assertEqual(session.state['register'], 'a')
        self.assertEqual(session.state['timeout'], original)

    def test_panel_resize_and_timeout_cleanup_on_disable_reload_and_close(self):
        session = self.session(delay=25, timeoutlen=100)
        original = session.state['timeout']
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        popup = session.state['keys']['popup']
        session.resize(160, 40)
        session.wait(lambda state: state['popup_position'].get('width') == 160)
        self.assertEqual(session.state['keys']['popup'], popup)
        session.action(b'\x1b', lambda state: not state['keys']['pending'])
        session.command('call timer_start(100, {timer -> execute("VimWhichKeyDisable")})')
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        session.wait(lambda state: not state['keys']['enabled'] and not state['keys']['held'])
        self.assertEqual(session.state['timeout'], original)
        session.send(b'\x1b')
        session.pump(.1)
        session.command('VimWhichKeyEnable')
        session.command('call timer_start(100, {timer -> execute("source ' + str(ROOT / '.vimrc') + '")})')
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        session.wait(lambda state: not state['keys']['held'])
        self.assertEqual(session.state['timeout'], original)
        session.send(b'\x1b')
        session.pump(.1)
        session.command('call timer_start(100, {timer -> popup_close(VimWhichKeyStatus().popup)})')
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        session.wait(lambda state: not state['keys']['held'])
        self.assertEqual(session.state['timeout'], original)

    def test_native_timeout_before_popup_and_user_paging_mapping(self):
        session = self.session(delay=200, timeoutlen=60)
        session.send(' ')
        session.pump(.13)
        self.assertEqual(session.state['col'], 2)
        self.assertFalse(session.state['keys']['pending'])
        self.assertFalse(session.state['keys']['held'])
        self.assertFalse(any(state['keys']['popup'] for _, state in session.history))
        session.command('set timeoutlen=1000')
        session.command('nnoremap <Space><C-d> :let g:key_hits += 1<CR>')
        session.command('VimWhichKeyRefresh')
        session.action(' ', lambda state: menu_shown(state, '<Space>'))
        session.action(b'\x04', lambda state: state['hits'] == 1)
        self.assertEqual(session.state['timeout'][0], 1)

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
        popup = session.state['keys']['popup']
        session.pump(.35)
        self.assertEqual(session.state['keys']['popup'], popup)
        self.assertTrue(session.state['keys']['held'])
        self.assertEqual(session.state['col'], 1)
        session.action(b'\x1b', lambda state: not state['keys']['pending'])
        self.assertEqual(session.state['timeout'], [1, 100, 1, 30])
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
        session.wait(lambda state: menu_shown(state, '<Space><C-F6>'))
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
        session.action(' u', lambda state: menu_shown(state, '<Space>u'))
        self.assertIn('局部动作', '\n'.join(session.state['popup_lines']))
        session.action('a', lambda state: state['hits'] == 10)
        session.command('enew')
        session.action(' ua', lambda state: state['hits'] == 11)
        session.command('buffer #')
        session.action(' ua', lambda state: state['hits'] == 21)
        session.command('setfiletype markdown')
        session.action(' m', lambda state: menu_shown(state, '<Space>m'))
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
        session.wait(lambda state: menu_shown(state, '<Space>u'))
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
        session.action(b'\x1b[17~', lambda state: menu_shown(state, '<F6>'))
        session.action('中', lambda state: menu_shown(state, '<F6>中'))
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
