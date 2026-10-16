"""Markdown note workflows: chapter context, document TOCs, folds and auto-save."""

from test_vim import VimSession, quoted


class MarkdownNotesTests(VimSession):
    def test_breadcrumb_tracks_nested_headings_and_ignores_code_comments(self):
        self.vim(r'''
enew
setfiletype markdown
call setline(1, ['', '# A', 'intro', '## B', 'detail', '```', '# fake', '```',
      \ '<!--', '# private', '-->', '## C', 'last'])
call cursor(1, 1)
call VimMarkdownViewRefresh()
call assert_equal('', VimMarkdownBreadcrumb())
call cursor(5, 1)
call assert_match('A › B', VimMarkdownBreadcrumb())
call cursor(10, 1)
call assert_match('A › B', VimMarkdownBreadcrumb())
call cursor(13, 1)
call assert_match('A › C', VimMarkdownBreadcrumb())
let source = bufnr('%')
vnew
setfiletype text
call assert_equal('', VimMarkdownBreadcrumb())
close
call setline(12, '## New')
call VimMarkdownViewRefresh()
call assert_match('A › New', VimMarkdownBreadcrumb())
''')

    def test_toc_depth_duplicate_unicode_anchors_update_remove_and_save(self):
        document = self.work / 'notes.md'
        document.write_text('# Root\n\n## Same\nbody\n## Same\nbody\n### 中文\nbody\n'
                            '#### Deep\nbody\n```\n# fake\n```\n')
        self.vim('edit ' + str(document) + r'''
let original = getline(1, '$')
call cursor(2, 1)
VimMarkdownToc 3
let text = join(getline(1, '$'), "\n")
call assert_match('- \[Root\](#root)', text)
call assert_match('  - \[Same\](#same)', text)
call assert_match('  - \[Same\](#same-1)', text)
call assert_match('    - \[中文\](#中文)', text)
call assert_notmatch('\[Deep\]', text)
call assert_notmatch('\[fake\]', text)
let tick = b:changedtick
VimMarkdownTocUpdate
call assert_equal(tick, b:changedtick)
VimMarkdownTocUpdate 2
call assert_notmatch('\[中文\]', join(getline(1, '$'), "\n"))
call search('^## Same$', 'w')
call setline('.', '## Renamed')
write
call assert_match('\[Renamed\](#renamed)', join(readfile(expand('%')), "\n"))
VimMarkdownTocRemove
call assert_false(search('vim-lite-toc', 'nw') > 0)
call assert_true(search('^#### Deep$', 'nw') > 0)
''')

    def test_toc_does_not_touch_literal_markers_inside_fences(self):
        self.vim(r'''
enew
setfiletype markdown
let source = ['# Root', '', '```html', '<!-- vim-lite-toc start depth=3 -->',
      \ 'literal', '<!-- vim-lite-toc end -->', '```', '', 'anchor']
call setline(1, source)
VimMarkdownTocUpdate
call assert_equal(source, getline(1, '$'))
call cursor(2, 1)
VimMarkdownToc 2
call assert_equal(2, len(filter(getline(1, '$'), 'v:val =~# "vim-lite-toc start"')))
call assert_true(search('^literal$', 'nw') > 0)
''')

    def test_heading_folds_open_current_all_and_level_without_source_changes(self):
        self.vim(r'''
enew
setfiletype markdown
let source = ['# A', 'a', '## B', 'b', '### C', 'c', '# D', 'd']
call setline(1, source)
call cursor(4, 1)
VimMarkdownFold current
call assert_equal(-1, foldclosed(1))
call assert_equal(3, foldclosed(3))
call assert_equal(-1, foldclosed(7))
call cursor(2, 1)
VimMarkdownFold all
call assert_equal(1, foldclosed(1))
call assert_equal(6, foldclosedend(1))
VimMarkdownFold level 1
call assert_equal(-1, foldclosed(1))
call assert_equal(3, foldclosed(4))
VimMarkdownFold open
call assert_equal(-1, foldclosed(4))
call cursor(4, 1)
VimMarkdownFold current
call assert_equal(3, foldclosed(3))
VimMarkdownFold off
call assert_equal(0, &foldenable)
call assert_equal(source, getline(1, '$'))
''')

    def test_auto_save_events_toggle_and_external_changes(self):
        document = self.work / 'autosave.md'
        document.write_text('# Original\n')
        self.vim('edit ' + str(document) + r'''
let g:vimrc_lite_markdown_autosave_delay = 100
let g:save_count = 0
augroup MarkdownSaveProbe
  autocmd!
  autocmd BufWritePost * let g:save_count += 1
augroup END
call setline(1, '# Changed')
doautocmd TextChanged
sleep 150m
call assert_equal(['# Changed'], readfile(expand('%')))
call assert_false(&modified)
call assert_equal(1, g:save_count)
call VimMarkdownAutoSaveNow()
call assert_equal(1, g:save_count)
VimMarkdownAutoSave
call setline(1, '# Pending')
call VimMarkdownAutoSaveNow()
call assert_equal(['# Changed'], readfile(expand('%')))
VimMarkdownAutoSave
call writefile(['# External'], expand('%'))
call VimMarkdownAutoSaveNow()
call assert_equal(['# External'], readfile(expand('%')))
call assert_equal('# Pending', getline(1))
call assert_true(&modified)
write!
call setline(1, '# After manual save')
call VimMarkdownAutoSaveNow()
call assert_equal(['# After manual save'], readfile(expand('%')))
setlocal readonly
call setline(1, '# Read only')
call VimMarkdownAutoSaveNow()
call assert_equal(['# After manual save'], readfile(expand('%')))
''')

    def test_auto_save_updates_owned_toc_and_skips_unnamed_and_other_filetypes(self):
        document = self.work / 'save-toc.md'
        document.write_text('# One\n\nbody\n')
        self.vim('edit ' + str(document) + r'''
call cursor(2, 1)
VimMarkdownToc
call setline(1, '# Two')
call VimMarkdownAutoSaveNow()
call assert_match('\[Two\](#two)', join(readfile(expand('%')), "\n"))
enew
setfiletype markdown
call setline(1, '# Untitled')
call VimMarkdownAutoSaveNow()
call assert_true(&modified)
setlocal filetype=text
call VimMarkdownAutoSaveNow()
call assert_true(&modified)
''')

    def test_first_attach_to_dirty_buffer_does_not_trust_an_already_changed_disk(self):
        document = self.work / 'existing.md'
        document.write_text('# Original\n')
        self.vim('edit ' + str(document) + r'''
unlet b:vimrc_lite_markdown_disk
call setline(1, '# Unsaved local edit')
call writefile(['# External edit'], expand('%'))
call VimMarkdownNotesAttach()
call VimMarkdownAutoSaveNow()
call assert_equal(['# External edit'], readfile(expand('%')))
call assert_equal('# Unsaved local edit', getline(1))
write!
call setline(1, '# Later edit')
call VimMarkdownAutoSaveNow()
call assert_equal(['# Later edit'], readfile(expand('%')))
''')
