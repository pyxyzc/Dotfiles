"""Persistent line pins follow edits without altering files or native search."""

import hashlib
import json
import subprocess
import unittest

from test_vim import ROOT, VIM, VimSession, quoted


SUPPORTED = subprocess.run(
    [VIM, '-Nu', 'NONE', '-i', 'NONE', '-n', '-es', '-c',
     'if v:version < 802 || !has("textprop") || !exists("*listener_add") | cquit | endif',
     '-c', 'qa!'], capture_output=True,
).returncode == 0

HELPERS = r'''
function! RefreshPins() abort
  call listener_flush()
  doautocmd vimrc_lite_pins TextChanged
endfunction
function! PinLines() abort
  call RefreshPins()
  let props = prop_list(1, {'types': ['VimrcLitePinAnchor'], 'end_lnum': -1})
  return uniq(sort(map(props, 'v:val.lnum'), 'n'))
endfunction
function! PinMatches(window) abort
  return filter(getmatches(a:window), 'v:val.group ==# "VimrcLitePin"')
endfunction
'''


@unittest.skipUnless(SUPPORTED, 'Pins require Vim 8.2/9 with +textprop/listeners')
class PinTests(VimSession):
    def setUp(self):
        super().setUp()
        self.env['HOME'] = str(self.work)
        (self.work / '.git').mkdir()
        self.source = self.work / 'pins 中文.txt'
        self.source.write_text('first\n  second\nthird\nlast\n')

    def state_path(self, root=None):
        digest = hashlib.sha256(str(root or self.work).encode()).hexdigest()
        return self.work / 'state/vim-lite/pins' / (digest + '.json')

    def open_source(self):
        return (HELPERS + 'execute "edit " . fnameescape(' + quoted(self.source)
                + ')\ncall cursor(1, 1)\n')

    def state(self):
        return json.loads(self.state_path().read_text())

    def test_navigation_wrap_counts_single_pin_and_native_editor_state(self):
        self.vim(self.open_source() + r'''
nnoremap ]j :VimPinNext<CR>
nnoremap [j :VimPinPrev<CR>
''' + 'source ' + str(ROOT / '.vimrc') + r'''
call assert_equal('', maparg(']j', 'n'))
call assert_equal('', maparg('[j', 'n'))
let @/ = 'native search'
let @" = 'native yank'
call cursor(2, 4)
let initial = winsaveview()
VimPinNext
call assert_equal(initial, winsaveview(), 'no pins: no movement')
VimPinToggle
VimPinNext
VimPinPrev
call assert_equal(initial, winsaveview(), 'already on sole pin: preserve column/view')
call cursor(4, 1)
VimPinNext
call assert_equal([2, 3], [line('.'), col('.')])
4VimPinToggle
1VimPinToggle
call cursor(1, 1)
call feedkeys(']p', 'xt')
call assert_equal(2, line('.'))
call feedkeys(']p]p', 'xt')
call assert_equal(1, line('.'))
call feedkeys('[p', 'xt')
call assert_equal(4, line('.'))
call feedkeys('3]p', 'xt')
call assert_equal(4, line('.'))
call feedkeys('2[p', 'xt')
call assert_equal(1, line('.'))
call assert_equal('native search', @/)
call assert_equal('native yank', @")
call assert_false(&modified)
call assert_equal(['first', '  second', 'third', 'last'], getline(1, '$'))
setlocal foldmethod=manual
2,3fold
call cursor(1, 1)
VimPinNext
call assert_equal(-1, foldclosed(2))
''')

    def test_visual_ranges_toggle_mixed_pins_and_clear_shortcuts(self):
        self.vim(self.open_source() + r'''
2VimPinToggle
call feedkeys('ggVjj pp', 'xt')
call assert_equal([1, 3], PinLines(), 'each selected row toggles independently')
call cursor(1, 1)
call feedkeys(' pc', 'xt')
call assert_equal([3], PinLines())
call feedkeys('ggvjl pp', 'xt')
call assert_equal([1, 2, 3], PinLines(), 'character selection pins touched rows')
call feedkeys('gg' . "\<C-v>" . 'jj pp', 'xt')
call assert_equal([], PinLines(), 'block selection also toggles whole rows')
call feedkeys(' pp', 'xt')
call assert_equal([line('.')], PinLines())
call feedkeys(' pf', 'xt')
call assert_equal([], PinLines())
''')

    def test_insert_delete_replace_and_undo_redo_track_original_rows(self):
        self.vim(self.open_source() + r'''
2VimPinToggle
4VimPinToggle
call append(1, 'inserted')
call assert_equal([3, 5], PinLines())
call setline(3, 'replacement 中文')
call assert_equal([3, 5], PinLines(), 'setline preserves the same-row pin')
call setbufline(bufnr('%'), 3, 'another replacement')
call assert_equal([3, 5], PinLines(), 'setbufline also preserves the pin')
call feedkeys('ggdd', 'xt')
call assert_equal([2, 4], PinLines())
call feedkeys('2Gdd', 'xt')
call assert_equal([3], PinLines(), 'deleted row loses its pin')
call feedkeys('u', 'xt')
call assert_equal([2, 4], PinLines(), 'undo restores deleted row and its pin')
call feedkeys("\<C-r>", 'xt')
call assert_equal([3], PinLines())
''')

    def test_explicit_clear_is_not_resurrected_by_undo(self):
        self.vim(self.open_source() + r'''
2VimPinToggle
call feedkeys('ggOabove' . "\<Esc>", 'xt')
call assert_equal([3], PinLines())
call cursor(3, 1)
VimPinClear
call feedkeys('u', 'xt')
call assert_equal([], PinLines())
2VimPinToggle
call feedkeys('ggOagain' . "\<Esc>", 'xt')
call assert_equal([3], PinLines())
VimPinClearFile
call feedkeys('u', 'xt')
call assert_equal([], PinLines())
''')

    def test_last_line_deletion_and_empty_text_replacement(self):
        self.vim(self.open_source() + r'''
1,$delete _
call setline(1, 'only row')
write
VimPinToggle
call feedkeys('dd', 'xt')
call assert_equal([], PinLines(), 'deleting the sole row removes its pin')
call feedkeys('u', 'xt')
call assert_equal([1], PinLines())
call setline(1, '')
call assert_equal([1], PinLines(), 'replacing text with empty text keeps the row')
VimPinClearFile
call setline(1, ['a', 'b', 'c'])
write
1VimPinToggle
3VimPinToggle
call feedkeys('ggdG', 'xt')
call assert_equal([], PinLines(), 'deleting all rows removes all pins')
call feedkeys('u', 'xt')
call assert_equal([1, 3], PinLines())
''')

    def test_persistence_immediate_toggles_save_and_discarded_edits(self):
        self.vim(self.open_source() + '2VimPinToggle\n')
        self.assertEqual([2], [r['line'] for r in self.state()['files'][str(self.source)]])
        self.assertEqual(0o600, self.state_path().stat().st_mode & 0o777)
        self.vim(self.open_source() + r'''
call assert_equal([2], PinLines())
call append(1, 'saved addition')
write
call assert_equal([3], PinLines())
''')
        self.vim(self.open_source() + r'''
call assert_equal([3], PinLines())
call append(1, 'discard this addition')
call assert_equal([4], PinLines())
edit!
call assert_equal([3], PinLines())
call append(1, 'also discard')
call assert_equal([4], PinLines())
''')
        self.vim(self.open_source() + r'''
call assert_equal([3], PinLines())
VimPinClearFile
''')
        self.vim(self.open_source() + 'call assert_equal([], PinLines())\n')

    def test_deleted_saved_pin_returns_on_undo_and_save(self):
        self.vim(self.open_source() + r'''
2VimPinToggle
call feedkeys('2Gdd', 'xt')
write
call assert_equal([], PinLines())
call feedkeys('u', 'xt')
call assert_equal([2], PinLines())
write
''')
        self.vim(self.open_source() + 'call assert_equal([2], PinLines())\n')

    def test_external_edits_relocate_and_ambiguous_records_stay_pending(self):
        self.vim(self.open_source() + '2VimPinToggle\n')
        self.source.write_text('external\nfirst\n  second\nthird\nlast\n')
        self.vim(self.open_source() + 'call assert_equal([3], PinLines())\n')
        self.source.write_text('x\n  second\ny\n  second\nz\n')
        self.vim(self.open_source() + r'''
call assert_equal([], PinLines(), 'ambiguous identical rows are not guessed')
call assert_match('await reliable relocation', execute('messages'))
write
''')
        self.assertEqual(1, len(self.state()['files'][str(self.source)]))
        self.source.write_text('new first\nfirst\n  second\nthird\nlast\n')
        self.vim(self.open_source() + 'call assert_equal([3], PinLines())\n')

    def test_duplicate_lines_use_context_and_pending_can_be_cleared(self):
        self.source.write_text('a\nrepeat\nb\nc\nrepeat\nd\n')
        self.vim(self.open_source() + '2VimPinToggle\n')
        self.source.write_text('added\na\nrepeat\nb\nc\nrepeat\nd\n')
        self.vim(self.open_source() + 'call assert_equal([3], PinLines())\n')
        self.source.write_text('completely changed\n')
        self.vim(self.open_source() + 'call assert_equal([], PinLines())\nVimPinClearFile\n')
        self.assertNotIn(str(self.source), self.state()['files'])

    def test_named_new_file_and_unsaved_new_lines_remain_recoverable(self):
        new_file = self.work / 'new file.txt'
        self.vim(HELPERS + 'execute "edit " . fnameescape(' + quoted(new_file) + r''')
call setline(1, ['new first', 'new pinned'])
2VimPinToggle
write
''')
        self.vim(HELPERS + 'execute "edit " . fnameescape(' + quoted(new_file) + r''')
call assert_equal([2], PinLines())
call append(2, 'unsaved pinned')
3VimPinToggle
''')
        self.vim(HELPERS + 'execute "edit " . fnameescape(' + quoted(new_file) + r''')
call assert_equal([2], PinLines(), 'discarded new row stays pending')
call append(2, 'unsaved pinned')
write
edit!
call assert_equal([2, 3], PinLines())
''')

    def test_project_clear_includes_hidden_unopened_pending_and_preserves_other_project(self):
        second = self.work / 'second.txt'
        unopened = self.work / 'unopened.txt'
        other = self.work / 'other'
        other.mkdir()
        (other / '.git').mkdir()
        foreign = other / 'foreign.txt'
        for path in (second, unopened, foreign):
            path.write_text('line\n')
        script = self.open_source() + '2VimPinToggle\n'
        for path in (second, unopened, foreign):
            script += 'execute "edit " . fnameescape(' + quoted(path) + ')\nVimPinToggle\n'
        self.vim(script)
        unopened.write_text('unlocatable\n')
        self.vim(self.open_source() + r'''
let original = bufnr('%')
''' + 'execute "edit " . fnameescape(' + quoted(second) + r''')
call assert_equal([1], PinLines())
call feedkeys(' pa', 'xt')
call assert_equal([], PinLines())
execute 'buffer ' . original
call assert_equal([], PinLines(), 'clear includes hidden loaded buffer')
''')
        self.assertEqual({}, self.state()['files'])
        self.vim(HELPERS + 'execute "edit " . fnameescape(' + quoted(unopened) + r''')
call assert_equal([], PinLines())
''' + 'execute "edit " . fnameescape(' + quoted(foreign) + r''')
call assert_equal([1], PinLines(), 'other project remains pinned')
''')

    def test_empty_long_unicode_tab_lines_and_split_reload_highlights(self):
        self.vim(self.open_source() + r'''
call setline(1, ["\t中文 pin  ", '', repeat('x', 20000), 'other'])
write
1,3VimPinToggle
call assert_equal([1, 2, 3], PinLines())
let matches = PinMatches(win_getid())
call assert_equal([1, 1, strlen(getline(1))], matches[0].pos1)
call assert_equal([3, 1, 20000], matches[0].pos2)
call assert_equal(-1, matches[0].priority, 'search has higher priority than pins')
let custom = matchadd('ErrorMsg', 'other')
split
call assert_equal(1, len(PinMatches(win_getid())))
let upper = win_getid()
wincmd p
call assert_equal(1, len(PinMatches(win_getid())))
''' + 'source ' + str(ROOT / '.vimrc') + r'''
''' + 'source ' + str(ROOT / '.vimrc') + r'''
colorscheme tokyonight-night
call assert_equal([1, 2, 3], PinLines())
call assert_equal(1, len(PinMatches(upper)))
call assert_equal(1, len(PinMatches(win_getid())))
call assert_equal('#2de2c2', synIDattr(hlID('VimrcLitePin'), 'bg', 'gui'))
call assert_equal('#ff6bcb', synIDattr(hlID('Visual'), 'bg', 'gui'))
call assert_equal('#e0af68', synIDattr(hlID('Search'), 'bg', 'gui'))
call assert_equal('#ff9e64', synIDattr(hlID('IncSearch'), 'bg', 'gui'))
call assert_equal('#f7768e', synIDattr(hlID('CurSearch'), 'bg', 'gui'))
call assert_equal('43', synIDattr(hlID('VimrcLitePin'), 'bg', 'cterm'))
call assert_equal('206', synIDattr(hlID('Visual'), 'bg', 'cterm'))
VimPinClearFile
call assert_equal([], PinMatches(upper))
call assert_equal([], PinMatches(win_getid()))
call assert_true(!empty(filter(getmatches(), 'v:val.id == custom')))
enew
call assert_equal([], PinMatches(win_getid()))
VimPinToggle
call assert_match('save unnamed buffers first', execute('messages'))
''')

    def test_rendered_text_search_and_visual_priority_in_both_color_modes(self):
        for truecolor in (0, 1):
            with self.subTest(truecolor=truecolor):
                self.terminal_vim(self.open_source() + r'''
setlocal nocursorline nonumber norelativenumber
call setline(1, ["\t中文 code  ", 'needle code', 'ordinary', 'last'])
write
VimPinClearFile
1,2VimPinToggle
call cursor(4, 1)
redraw!
let first = screenpos(win_getid(), 1, 1)
let second = screenpos(win_getid(), 2, 1)
let ordinary = screenpos(win_getid(), 3, 1)
let pin = screenattr(first.row, first.col)
let normal = screenattr(ordinary.row, ordinary.col)
call assert_notequal(normal, pin, 'pin visibly highlights text')
for offset in range(strdisplaywidth(getline(1)))
  call assert_equal(pin, screenattr(first.row, first.col + offset),
        \ 'indent, wide text and trailing spaces are all pinned')
endfor
call assert_equal(normal, screenattr(first.row,
      \ first.col + strdisplaywidth(getline(1))), 'right-side padding is not pinned')
call feedkeys('/needle' . "\<CR>", 'xt')
redraw!
call assert_notequal(pin, screenattr(second.row, second.col), 'search overrides pin')
call assert_equal(pin, screenattr(second.row, second.col + 8),
      \ 'remaining code stays pinned during search')
call cursor(1, 1)
call feedkeys('v', 'xt')
redraw!
call assert_notequal(pin, screenattr(first.row, first.col), 'Visual overrides pin')
call feedkeys("\<Esc>", 'xt')
redraw!
call assert_equal(pin, screenattr(first.row, first.col), 'pin returns after Visual')
call cursor(1, 1)
VimPinClear
redraw!
call assert_equal(normal, screenattr(first.row, first.col), 'clear removes background')
''', before=['let g:vimrc_lite_truecolor = ' + str(truecolor)])

    def test_corrupt_state_preserved_and_write_failure_keeps_memory_pin(self):
        self.state_path().parent.mkdir(parents=True)
        original = '{invalid JSON\n'
        self.state_path().write_text(original)
        self.vim(self.open_source() + r'''
VimPinToggle
call assert_equal([1], PinLines())
call assert_match('original state preserved', execute('messages'))
call assert_match('changes remain in memory', execute('messages'))
''')
        self.assertEqual(original, self.state_path().read_text())
        self.state_path().unlink()
        self.state_path().parent.rmdir()
        self.state_path().parent.write_text('block state directory')
        self.vim(self.open_source() + r'''
VimPinToggle
call assert_equal([1], PinLines())
call assert_match('could not save pins', execute('messages'))
''')

    def test_buffer_rename_moves_persistent_pins(self):
        renamed = self.work / 'renamed 中文.txt'
        self.vim(self.open_source() + r'''
2VimPinToggle
''' + 'execute "saveas " . fnameescape(' + quoted(renamed) + r''')
call assert_equal([2], PinLines())
''')
        self.assertNotIn(str(self.source), self.state()['files'])
        self.vim(HELPERS + 'execute "edit " . fnameescape(' + quoted(renamed) + r''')
call assert_equal([2], PinLines())
''')


class PinCompatibilityTests(VimSession):
    def test_missing_capabilities_leave_startup_and_commands_usable(self):
        config = self.work / 'fallback.vim'
        source = (ROOT / 'pins.vim').read_text().replace('v:version >= 802', '0')
        config.write_text('set nocompatible\n' + source)
        self.vim(r'''
call assert_equal('', v:errmsg)
VimPinToggle
VimPinClear
VimPinClearFile
VimPinClearProject
VimPinNext
VimPinPrev
call assert_match('requires Vim 8.2/9', execute('messages'))
call assert_equal('', v:errmsg)
''', config=config)


if __name__ == '__main__':
    unittest.main(verbosity=2)
