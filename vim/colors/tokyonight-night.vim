" TokyoNight Night, exported by folke/tokyonight.nvim.
" Upstream revision: cdc07ac78467a233fd62c493de29a17e0cf2b2b6
" License: Apache-2.0; see LICENSE.tokyonight and README.md.
" Local changes: static xterm-256 colors and optional transparent background.
" 256-color values use nearest RGB distance among xterm colors 16..255.
set background=dark
if exists('syntax_on')
  syntax reset
endif
hi clear
let g:colors_name = "tokyonight-night"

hi ALEErrorSign guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi ALEWarningSign guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi BlinkCmpDoc guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi BlinkCmpDocBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi BlinkCmpGhostText guibg=NONE guifg=#414868 ctermfg=239 ctermbg=NONE
hi BlinkCmpKindCodeium guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi BlinkCmpKindCopilot guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi BlinkCmpKindDefault guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi BlinkCmpKindSupermaven guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi BlinkCmpKindTabNine guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi BlinkCmpLabel guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE
hi BlinkCmpLabelDeprecated gui=strikethrough guibg=NONE guifg=#3b4261 ctermfg=239 ctermbg=NONE cterm=strikethrough
hi BlinkCmpLabelMatch guibg=NONE guifg=#2ac3de ctermfg=38 ctermbg=NONE
hi BlinkCmpMenu guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi BlinkCmpMenuBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi BlinkCmpSignatureHelp guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi BlinkCmpSignatureHelpBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi Bold gui=bold guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE cterm=bold
hi Character guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi ColorColumn guibg=#15161e ctermbg=234
hi Comment gui=italic guibg=NONE guifg=#565f89 ctermfg=60 ctermbg=NONE cterm=italic
hi ComplHint guibg=NONE guifg=#414868 ctermfg=239 ctermbg=NONE
hi Conceal guibg=NONE guifg=#737aa2 ctermfg=67 ctermbg=NONE
hi Constant guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE
hi CopilotAnnotation guibg=NONE guifg=#414868 ctermfg=239 ctermbg=NONE
hi CopilotSuggestion guibg=NONE guifg=#414868 ctermfg=239 ctermbg=NONE
hi Cursor guibg=#c0caf5 guifg=#1a1b26 ctermfg=234 ctermbg=153
hi CursorColumn guibg=#292e42 ctermbg=236
hi CursorIM guibg=#c0caf5 guifg=#1a1b26 ctermfg=234 ctermbg=153
hi CursorLine guibg=#292e42 ctermbg=236
hi CursorLineNr gui=bold guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE cterm=bold
hi Debug guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE
hi DiagnosticError guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi DiagnosticHint guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi DiagnosticInfo guibg=NONE guifg=#0db9d7 ctermfg=38 ctermbg=NONE
hi DiagnosticUnderlineError gui=undercurl guibg=NONE guisp=#db4b4b ctermbg=NONE cterm=undercurl
hi DiagnosticUnderlineHint gui=undercurl guibg=NONE guisp=#1abc9c ctermbg=NONE cterm=undercurl
hi DiagnosticUnderlineInfo gui=undercurl guibg=NONE guisp=#0db9d7 ctermbg=NONE cterm=undercurl
hi DiagnosticUnderlineWarn gui=undercurl guibg=NONE guisp=#e0af68 ctermbg=NONE cterm=undercurl
hi DiagnosticUnnecessary guibg=NONE guifg=#414868 ctermfg=239 ctermbg=NONE
hi DiagnosticVirtualTextError guibg=#2d202a guifg=#db4b4b ctermfg=167 ctermbg=235
hi DiagnosticVirtualTextHint guibg=#1a2b32 guifg=#1abc9c ctermfg=37 ctermbg=235
hi DiagnosticVirtualTextInfo guibg=#192b38 guifg=#0db9d7 ctermfg=38 ctermbg=235
hi DiagnosticVirtualTextWarn guibg=#2e2a2d guifg=#e0af68 ctermfg=179 ctermbg=236
hi DiagnosticWarn guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi DiffAdd guibg=#243e4a ctermbg=237
hi DiffChange guibg=#1f2231 ctermbg=235
hi DiffDelete guibg=#4a272f ctermbg=237
hi DiffText guibg=#394b70 ctermbg=239
hi Directory guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi EndOfBuffer guibg=NONE guifg=#1a1b26 ctermfg=234 ctermbg=NONE
hi Error guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi ErrorMsg guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi FloatBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi FloatTitle guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi FoldColumn guibg=#1a1b26 guifg=#565f89 ctermfg=60 ctermbg=234
hi Folded guibg=#3b4261 guifg=#7aa2f7 ctermfg=111 ctermbg=239
hi Foo guibg=#ff007c guifg=#c0caf5 ctermfg=153 ctermbg=198
hi Function guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi FzfLuaBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi FzfLuaDirPart guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi FzfLuaFzfNormal guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE
hi FzfLuaFzfPointer guibg=NONE guifg=#ff007c ctermfg=198 ctermbg=NONE
hi FzfLuaFzfSeparator guibg=#16161e guifg=#ff9e64 ctermfg=215 ctermbg=234
hi FzfLuaNormal guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi FzfLuaPreviewTitle guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi FzfLuaTitle guibg=#16161e guifg=#ff9e64 ctermfg=215 ctermbg=234
hi GitGutterAdd guibg=NONE guifg=#449dab ctermfg=73 ctermbg=NONE
hi GitGutterAddLineNr guibg=NONE guifg=#449dab ctermfg=73 ctermbg=NONE
hi GitGutterChange guibg=NONE guifg=#6183bb ctermfg=67 ctermbg=NONE
hi GitGutterChangeLineNr guibg=NONE guifg=#6183bb ctermfg=67 ctermbg=NONE
hi GitGutterDelete guibg=NONE guifg=#914c54 ctermfg=95 ctermbg=NONE
hi GitGutterDeleteLineNr guibg=NONE guifg=#914c54 ctermfg=95 ctermbg=NONE
hi GlyphPalette1 guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi GlyphPalette2 guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi GlyphPalette3 guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi GlyphPalette4 guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi GlyphPalette6 guibg=NONE guifg=#73daca ctermfg=80 ctermbg=NONE
hi GlyphPalette7 guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE
hi GlyphPalette9 guibg=NONE guifg=#f7768e ctermfg=210 ctermbg=NONE
hi Identifier guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE
hi IlluminatedWordRead guibg=#3b4261 ctermbg=239
hi IlluminatedWordText guibg=#3b4261 ctermbg=239
hi IlluminatedWordWrite guibg=#3b4261 ctermbg=239
hi IncSearch guibg=#ff9e64 guifg=#15161e ctermfg=234 ctermbg=215
hi Italic gui=italic guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE cterm=italic
hi Keyword gui=italic guibg=NONE guifg=#7dcfff ctermfg=117 ctermbg=NONE cterm=italic
hi LineNr guibg=NONE guifg=#3b4261 ctermfg=239 ctermbg=NONE
hi LineNrAbove guibg=NONE guifg=#3b4261 ctermfg=239 ctermbg=NONE
hi LineNrBelow guibg=NONE guifg=#3b4261 ctermfg=239 ctermbg=NONE
hi LspCodeLens guibg=NONE guifg=#565f89 ctermfg=60 ctermbg=NONE
hi LspInfoBorder guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234
hi LspInlayHint guibg=#1d202d guifg=#545c7e ctermfg=60 ctermbg=235
hi LspReferenceRead guibg=#3b4261 ctermbg=239
hi LspReferenceText guibg=#3b4261 ctermbg=239
hi LspReferenceWrite guibg=#3b4261 ctermbg=239
hi LspSignatureActiveParameter gui=bold guibg=#20253a ctermbg=235 cterm=bold
hi MatchParen gui=bold guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE cterm=bold
hi MiniAnimateCursor gui=nocombine guibg=NONE ctermbg=NONE cterm=nocombine
hi MiniCompletionActiveParameter gui=underline guibg=NONE ctermbg=NONE cterm=underline
hi MiniCursorword guibg=#3b4261 ctermbg=239
hi MiniCursorwordCurrent guibg=#3b4261 ctermbg=239
hi MiniDepsTitleError guibg=#914c54 guifg=#15161e ctermfg=234 ctermbg=95
hi MiniDepsTitleUpdate guibg=#449dab guifg=#15161e ctermfg=234 ctermbg=73
hi MiniDiffSignAdd guibg=NONE guifg=#449dab ctermfg=73 ctermbg=NONE
hi MiniDiffSignChange guibg=NONE guifg=#6183bb ctermfg=67 ctermbg=NONE
hi MiniDiffSignDelete guibg=NONE guifg=#914c54 ctermfg=95 ctermbg=NONE
hi MiniFilesFile guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE
hi MiniFilesTitleFocused gui=bold guibg=#16161e guifg=#27a1b9 ctermfg=37 ctermbg=234 cterm=bold
hi MiniHipatternsFixme gui=bold guibg=#db4b4b guifg=#15161e ctermfg=234 ctermbg=167 cterm=bold
hi MiniHipatternsHack gui=bold guibg=#e0af68 guifg=#15161e ctermfg=234 ctermbg=179 cterm=bold
hi MiniHipatternsNote gui=bold guibg=#1abc9c guifg=#15161e ctermfg=234 ctermbg=37 cterm=bold
hi MiniHipatternsTodo gui=bold guibg=#0db9d7 guifg=#15161e ctermfg=234 ctermbg=38 cterm=bold
hi MiniIconsAzure guibg=NONE guifg=#0db9d7 ctermfg=38 ctermbg=NONE
hi MiniIconsBlue guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi MiniIconsCyan guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi MiniIconsGreen guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi MiniIconsGrey guibg=NONE guifg=#c0caf5 ctermfg=153 ctermbg=NONE
hi MiniIconsOrange guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE
hi MiniIconsPurple guibg=NONE guifg=#9d7cd8 ctermfg=140 ctermbg=NONE
hi MiniIconsRed guibg=NONE guifg=#f7768e ctermfg=210 ctermbg=NONE
hi MiniIconsYellow guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi MiniIndentscopePrefix gui=nocombine guibg=NONE ctermbg=NONE cterm=nocombine
hi MiniIndentscopeSymbol gui=nocombine guibg=NONE guifg=#2ac3de ctermfg=38 ctermbg=NONE cterm=nocombine
hi MiniJump guibg=#ff007c guifg=#ffffff ctermfg=231 ctermbg=198
hi MiniJump2dSpot gui=bold,nocombine guibg=NONE guifg=#ff007c ctermfg=198 ctermbg=NONE cterm=bold,nocombine
hi MiniJump2dSpotAhead gui=nocombine guibg=#16161e guifg=#1abc9c ctermfg=37 ctermbg=234 cterm=nocombine
hi MiniJump2dSpotUnique gui=bold,nocombine guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE cterm=bold,nocombine
hi MiniPickBorderText guibg=#16161e guifg=#1abc9c ctermfg=37 ctermbg=234
hi MiniPickPrompt guibg=#16161e guifg=#0db9d7 ctermfg=38 ctermbg=234
hi MiniStarterCurrent gui=nocombine guibg=NONE ctermbg=NONE cterm=nocombine
hi MiniStarterFooter gui=italic guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE cterm=italic
hi MiniStarterHeader guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi MiniStarterInactive gui=italic guibg=NONE guifg=#565f89 ctermfg=60 ctermbg=NONE cterm=italic
hi MiniStarterItem guibg=#1a1b26 guifg=#c0caf5 ctermfg=153 ctermbg=234
hi MiniStarterItemBullet guibg=NONE guifg=#27a1b9 ctermfg=37 ctermbg=NONE
hi MiniStarterItemPrefix guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi MiniStarterQuery guibg=NONE guifg=#0db9d7 ctermfg=38 ctermbg=NONE
hi MiniStarterSection guibg=NONE guifg=#2ac3de ctermfg=38 ctermbg=NONE
hi MiniStatuslineDevinfo guibg=#3b4261 guifg=#a9b1d6 ctermfg=146 ctermbg=239
hi MiniStatuslineFileinfo guibg=#3b4261 guifg=#a9b1d6 ctermfg=146 ctermbg=239
hi MiniStatuslineFilename guibg=#292e42 guifg=#a9b1d6 ctermfg=146 ctermbg=236
hi MiniStatuslineInactive guibg=#16161e guifg=#7aa2f7 ctermfg=111 ctermbg=234
hi MiniStatuslineModeCommand gui=bold guibg=#e0af68 guifg=#15161e ctermfg=234 ctermbg=179 cterm=bold
hi MiniStatuslineModeInsert gui=bold guibg=#9ece6a guifg=#15161e ctermfg=234 ctermbg=149 cterm=bold
hi MiniStatuslineModeNormal gui=bold guibg=#7aa2f7 guifg=#15161e ctermfg=234 ctermbg=111 cterm=bold
hi MiniStatuslineModeOther gui=bold guibg=#1abc9c guifg=#15161e ctermfg=234 ctermbg=37 cterm=bold
hi MiniStatuslineModeReplace gui=bold guibg=#f7768e guifg=#15161e ctermfg=234 ctermbg=210 cterm=bold
hi MiniStatuslineModeVisual gui=bold guibg=#bb9af7 guifg=#15161e ctermfg=234 ctermbg=141 cterm=bold
hi MiniSurround guibg=#ff9e64 guifg=#15161e ctermfg=234 ctermbg=215
hi MiniTablineCurrent guibg=#3b4261 guifg=#c0caf5 ctermfg=153 ctermbg=239
hi MiniTablineFill guibg=#15161e ctermbg=234
hi MiniTablineHidden guibg=#16161e guifg=#737aa2 ctermfg=67 ctermbg=234
hi MiniTablineModifiedCurrent guibg=#3b4261 guifg=#e0af68 ctermfg=179 ctermbg=239
hi MiniTablineModifiedHidden guibg=#16161e guifg=#a58354 ctermfg=137 ctermbg=234
hi MiniTablineModifiedVisible guibg=#16161e guifg=#e0af68 ctermfg=179 ctermbg=234
hi MiniTablineTabpagesection guibg=#3b4261 guifg=NONE ctermfg=NONE ctermbg=239
hi MiniTablineVisible guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi MiniTestEmphasis gui=bold guibg=NONE ctermbg=NONE cterm=bold
hi MiniTestFail gui=bold guibg=NONE guifg=#f7768e ctermfg=210 ctermbg=NONE cterm=bold
hi MiniTestPass gui=bold guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE cterm=bold
hi MiniTrailspace guibg=#f7768e ctermbg=210
hi ModeMsg gui=bold guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE cterm=bold
hi MoreMsg guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi MsgArea guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi NeogitBranch guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE
hi NeogitDiffAddHighlight guibg=#243e4a guifg=#449dab ctermfg=73 ctermbg=237
hi NeogitDiffContextHighlight guibg=#2b2f44 guifg=#a9b1d6 ctermfg=146 ctermbg=236
hi NeogitDiffDeleteHighlight guibg=#4a272f guifg=#914c54 ctermfg=95 ctermbg=237
hi NeogitHunkHeader guibg=#292e42 guifg=#c0caf5 ctermfg=153 ctermbg=236
hi NeogitHunkHeaderHighlight guibg=#3b4261 guifg=#7aa2f7 ctermfg=111 ctermbg=239
hi NeogitRemote guibg=NONE guifg=#9d7cd8 ctermfg=140 ctermbg=NONE
hi NeotestAdapterName gui=bold guibg=NONE guifg=#9d7cd8 ctermfg=140 ctermbg=NONE cterm=bold
hi NeotestBorder guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NeotestDir guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NeotestExpandMarker guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi NeotestFailed guibg=NONE guifg=#f7768e ctermfg=210 ctermbg=NONE
hi NeotestFile guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE
hi NeotestFocused guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi NeotestIndent guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi NeotestMarked guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NeotestNamespace guibg=NONE guifg=#41a6b5 ctermfg=73 ctermbg=NONE
hi NeotestPassed guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi NeotestRunning guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi NeotestSkipped guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NeotestTarget guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NeotestTest guibg=NONE guifg=#a9b1d6 ctermfg=146 ctermbg=NONE
hi NeotestWinSelect guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi NonText guibg=NONE guifg=#545c7e ctermfg=60 ctermbg=NONE
hi Normal guibg=#1a1b26 guifg=#c0caf5 ctermfg=153 ctermbg=234
hi NormalFloat guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi NormalNC guibg=#1a1b26 guifg=#c0caf5 ctermfg=153 ctermbg=234
hi NormalSB guibg=#16161e guifg=#a9b1d6 ctermfg=146 ctermbg=234
hi Operator guibg=NONE guifg=#89ddff ctermfg=117 ctermbg=NONE
hi Pmenu guibg=#16161e guifg=#c0caf5 ctermfg=153 ctermbg=234
hi PmenuMatch guibg=#16161e guifg=#2ac3de ctermfg=38 ctermbg=234
hi PmenuMatchSel guibg=#343a55 guifg=#2ac3de ctermfg=38 ctermbg=238
hi PmenuSbar guibg=#1f1f29 ctermbg=235
hi PmenuSel guibg=#343a55 ctermbg=238
hi PmenuThumb guibg=#3b4261 ctermbg=239
hi PreProc guibg=NONE guifg=#7dcfff ctermfg=117 ctermbg=NONE
hi Question guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi QuickFixLine gui=bold guibg=#283457 ctermbg=237 cterm=bold
hi Search guibg=#3d59a1 guifg=#c0caf5 ctermfg=153 ctermbg=61
hi SignColumn guibg=#1a1b26 guifg=#3b4261 ctermfg=239 ctermbg=234
hi SignColumnSB guibg=#16161e guifg=#3b4261 ctermfg=239 ctermbg=234
hi Sneak guibg=#bb9af7 guifg=#292e42 ctermfg=236 ctermbg=141
hi SneakScope guibg=#283457 ctermbg=237
hi Special guibg=NONE guifg=#2ac3de ctermfg=38 ctermbg=NONE
hi SpecialKey guibg=NONE guifg=#545c7e ctermfg=60 ctermbg=NONE
hi SpellBad gui=undercurl guibg=NONE guisp=#db4b4b ctermbg=NONE cterm=undercurl
hi SpellCap gui=undercurl guibg=NONE guisp=#e0af68 ctermbg=NONE cterm=undercurl
hi SpellLocal gui=undercurl guibg=NONE guisp=#0db9d7 ctermbg=NONE cterm=undercurl
hi SpellRare gui=undercurl guibg=NONE guisp=#1abc9c ctermbg=NONE cterm=undercurl
hi Statement guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE
hi StatusLine guibg=#16161e guifg=#a9b1d6 ctermfg=146 ctermbg=234
hi StatusLineNC guibg=#16161e guifg=#3b4261 ctermfg=239 ctermbg=234
hi String guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi Substitute guibg=#f7768e guifg=#15161e ctermfg=234 ctermbg=210
hi TabLine guibg=#16161e guifg=#3b4261 ctermfg=239 ctermbg=234
hi TabLineFill guibg=#15161e ctermbg=234
hi TabLineSel guibg=#7aa2f7 guifg=#15161e ctermfg=234 ctermbg=111
hi Title gui=bold guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE cterm=bold
hi Todo guibg=#e0af68 guifg=#1a1b26 ctermfg=234 ctermbg=179
hi Type guibg=NONE guifg=#2ac3de ctermfg=38 ctermbg=NONE
hi Underlined gui=underline guibg=NONE ctermbg=NONE cterm=underline
hi VertSplit guibg=NONE guifg=#15161e ctermfg=234 ctermbg=NONE
hi VimwikiHR guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi VimwikiHeader1 gui=bold guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE cterm=bold
hi VimwikiHeader2 gui=bold guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE cterm=bold
hi VimwikiHeader3 gui=bold guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE cterm=bold
hi VimwikiHeader4 gui=bold guibg=NONE guifg=#1abc9c ctermfg=37 ctermbg=NONE cterm=bold
hi VimwikiHeader5 gui=bold guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE cterm=bold
hi VimwikiHeader6 gui=bold guibg=NONE guifg=#9d7cd8 ctermfg=140 ctermbg=NONE cterm=bold
hi VimwikiHeader7 gui=bold guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE cterm=bold
hi VimwikiHeader8 gui=bold guibg=NONE guifg=#f7768e ctermfg=210 ctermbg=NONE cterm=bold
hi VimwikiHeaderChar guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi VimwikiLink guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi VimwikiList guibg=NONE guifg=#ff9e64 ctermfg=215 ctermbg=NONE
hi VimwikiMarkers guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi VimwikiTag guibg=NONE guifg=#9ece6a ctermfg=149 ctermbg=NONE
hi Visual guibg=#283457 ctermbg=237
hi VisualNOS guibg=#283457 ctermbg=237
hi WarningMsg guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi Whitespace guibg=NONE guifg=#3b4261 ctermfg=239 ctermbg=NONE
hi WildMenu guibg=#283457 ctermbg=237
hi WinSeparator gui=bold guibg=NONE guifg=#15161e ctermfg=234 ctermbg=NONE cterm=bold
hi debugBreakpoint guibg=#192b38 guifg=#0db9d7 ctermfg=38 ctermbg=235
hi debugPC guibg=#16161e ctermbg=234
hi diffAdded guibg=#243e4a guifg=#449dab ctermfg=73 ctermbg=237
hi diffChanged guibg=#1f2231 guifg=#6183bb ctermfg=67 ctermbg=235
hi diffFile guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi diffIndexLine guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE
hi diffLine guibg=NONE guifg=#565f89 ctermfg=60 ctermbg=NONE
hi diffNewFile guibg=#243e4a guifg=#2ac3de ctermfg=38 ctermbg=237
hi diffOldFile guibg=#4a272f guifg=#2ac3de ctermfg=38 ctermbg=237
hi diffRemoved guibg=#4a272f guifg=#914c54 ctermfg=95 ctermbg=237
hi healthError guibg=NONE guifg=#db4b4b ctermfg=167 ctermbg=NONE
hi healthSuccess guibg=NONE guifg=#73daca ctermfg=80 ctermbg=NONE
hi healthWarning guibg=NONE guifg=#e0af68 ctermfg=179 ctermbg=NONE
hi helpCommand guibg=#414868 guifg=#7aa2f7 ctermfg=111 ctermbg=239
hi helpExample guibg=NONE guifg=#565f89 ctermfg=60 ctermbg=NONE
hi htmlH1 gui=bold guibg=NONE guifg=#bb9af7 ctermfg=141 ctermbg=NONE cterm=bold
hi htmlH2 gui=bold guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE cterm=bold
hi illuminatedCurWord guibg=#3b4261 ctermbg=239
hi illuminatedWord guibg=#3b4261 ctermbg=239
hi lCursor guibg=#c0caf5 guifg=#1a1b26 ctermfg=234 ctermbg=153
hi qfFileName guibg=NONE guifg=#7aa2f7 ctermfg=111 ctermbg=NONE
hi qfLineNr guibg=NONE guifg=#737aa2 ctermfg=67 ctermbg=NONE
hi! link CurSearch IncSearch
hi! link Delimiter Special
hi! link FzfLuaCursor IncSearch
hi! link FzfLuaFilePart FzfLuaFzfNormal
hi! link FzfLuaFzfCursorLine Visual
hi! link FzfLuaHeaderText Title
hi! link FzfLuaPath Directory
hi! link LspKindColor Special
hi! link LspKindEvent Special
hi! link LspKindFile Normal
hi! link LspKindFolder Directory
hi! link LspKindSnippet Conceal
hi! link MiniAnimateNormalFloat NormalFloat
hi! link MiniClueBorder FloatBorder
hi! link MiniClueDescSingle NormalFloat
hi! link MiniClueTitle FloatTitle
hi! link MiniDepsChangeAdded diffAdded
hi! link MiniDepsChangeRemoved diffRemoved
hi! link MiniDepsHint DiagnosticHint
hi! link MiniDepsInfo DiagnosticInfo
hi! link MiniDepsMsgBreaking DiagnosticWarn
hi! link MiniDepsPlaceholder Comment
hi! link MiniDepsTitle Title
hi! link MiniDepsTitleSame Comment
hi! link MiniDiffOverAdd DiffAdd
hi! link MiniDiffOverChange DiffText
hi! link MiniDiffOverContext DiffChange
hi! link MiniDiffOverDelete DiffDelete
hi! link MiniFilesBorder FloatBorder
hi! link MiniFilesCursorLine CursorLine
hi! link MiniFilesDirectory Directory
hi! link MiniFilesNormal NormalFloat
hi! link MiniFilesTitle FloatTitle
hi! link MiniJump2dDim Comment
hi! link MiniMapNormal NormalFloat
hi! link MiniMapSymbolCount Special
hi! link MiniMapSymbolLine Title
hi! link MiniNotifyBorder FloatBorder
hi! link MiniNotifyNormal NormalFloat
hi! link MiniNotifyTitle FloatTitle
hi! link MiniOperatorsExchangeFrom IncSearch
hi! link MiniPickBorder FloatBorder
hi! link MiniPickIconDirectory Directory
hi! link MiniPickMatchCurrent CursorLine
hi! link MiniPickMatchMarked Visual
hi! link MiniPickNormal NormalFloat
hi! link MiniPickPreviewLine CursorLine
hi! link MiniPickPreviewRegion IncSearch
hi! link WinBar StatusLine
hi! link WinBarNC StatusLineNC

" 默认沿用个人配置的透明背景；设为 0 可恢复原版深色背景。
if get(g:, 'vimrc_lite_transparent', 1)
  highlight Normal guibg=NONE ctermbg=NONE
  highlight NormalNC guibg=NONE ctermbg=NONE
  highlight EndOfBuffer guibg=NONE ctermbg=NONE
endif
