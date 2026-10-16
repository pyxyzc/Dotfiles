" Markdown 交互片段；固定版本 vim-vsnip 提供占位符、镜像及嵌套跳转。
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:math = {'ff': '\\frac{${1:分子}}{${2:分母}}$0',
      \ 'frac': '\\frac{${1:分子}}{${2:分母}}$0', 'sqrt': '\\sqrt{${1:x}}$0',
      \ 'sum': '\\sum_{${1:i=1}}^{${2:n}} ${3:a_i}$0',
      \ 'int': '\\int_{${1:a}}^{${2:b}} ${3:f(x)}\\,d${4:x}$0',
      \ 'lim': '\\lim_{${1:x \\to 0}} ${2:f(x)}$0',
      \ 'sub': '${1:x}_{${2:i}}$0', 'sup': '${1:x}^{${2:2}}$0',
      \ 'vec': '\\vec{${1:v}}$0', 'lr': '\\left(${1:x}\\right)$0',
      \ 'matrix': '\\begin{${1:pmatrix}}' . "\n" . '${2:a} & ${3:b} \\\\'
      \ . "\n" . '${4:c} & ${5:d}' . "\n" . '\\end{$1}$0'}
for s:name in ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'theta', 'lambda', 'mu',
      \ 'pi', 'rho', 'sigma', 'tau', 'phi', 'psi', 'omega', 'Gamma', 'Delta', 'Theta',
      \ 'Lambda', 'Sigma', 'Phi', 'Psi', 'Omega', 'infty', 'partial', 'nabla', 'times',
      \ 'cdot', 'leq', 'geq', 'neq', 'approx', 'to']
  let s:math[s:name] = '\\' . s:name . '$0'
endfor
let s:greek = {';a': 'alpha', ';b': 'beta', ';g': 'gamma', ';d': 'delta', ';e': 'epsilon',
      \ ';t': 'theta', ';l': 'lambda', ';m': 'mu', ';p': 'pi', ';s': 'sigma', ';f': 'phi',
      \ ';o': 'omega'}
for [s:key, s:name] in items(s:greek)
  let s:math[s:key] = '\\' . s:name . '$0'
endfor

function! s:Load() abort
  let directory = s:root . '/vendor/vim-vsnip'
  if !filereadable(directory . '/plugin/vsnip.vim')
    return 0
  endif
  if index(split(&runtimepath, ','), directory) < 0
    let &runtimepath .= ',' . escape(directory, ',')
  endif
  if !exists('g:loaded_vsnip')
    let g:vsnip_extra_mapping = get(g:, 'vsnip_extra_mapping', 0)
    execute 'source ' . fnameescape(directory . '/plugin/vsnip.vim')
  endif
  let directory = s:root . '/markdown/snippets'
  if index(g:vsnip_snippet_dirs, directory) < 0
    call add(g:vsnip_snippet_dirs, directory)
  endif
  return 1
endfunction

" 逐行状态只在光标前的文本改变时重算；同一行输入复用前文状态。
function! s:Scan(text, state) abort
  let state = copy(a:state)
  let state.literal = 0
  let marker = matchstr(a:text, '^ \{0,3}\zs\%(`\{3,}\|\~\{3,}\)')
  if !empty(state.fence)
    if !empty(marker) && marker[0] ==# state.fence[0] && strlen(marker) >= strlen(state.fence)
          \ && a:text =~# '^ \{0,3}' . escape(marker, '~') . '\s*$'
      let state.fence = ''
    endif
    return state
  elseif !state.comment && !empty(marker)
    let state.fence = marker
    return state
  endif
  let text = a:text
  let offset = 0
  let inline = 0
  while offset < strlen(text)
    if state.comment
      let ending = match(text, '-->', offset)
      if ending < 0
        return state
      endif
      let state.comment = 0
      let offset = ending + 3
      continue
    endif
    let char = strpart(text, offset, 1)
    if strpart(text, offset, 4) ==# '<!--'
      let state.comment = 1
      let offset += 4
    elseif char ==# '`'
      let ticks = matchstr(strpart(text, offset), '^`\+')
      let ending = match(text, '\%(`\)\@<!' . ticks . '\%(`\)\@!', offset + strlen(ticks))
      let state.literal = ending < 0
      let offset = ending < 0 ? strlen(text) : ending + strlen(ticks)
    elseif strpart(text, offset, 2) ==# '$$' && !inline
      let state.display = state.display == 2 ? 0 : 2
      let offset += 2
    elseif char ==# '$' && !state.display
      let inline = !inline
      let offset += 1
    elseif char ==# '\'
      let pair = strpart(text, offset, 2)
      if pair ==# '\['
        let state.display = 3
      elseif pair ==# '\]'
        let state.display = 0
      elseif pair ==# '\('
        let inline = 1
      elseif pair ==# '\)'
        let inline = 0
      endif
      let offset += 2
    else
      let offset += 1
    endif
  endwhile
  let state.inline = inline
  return state
endfunction

function! VimMarkdownMathContext() abort
  if &filetype !=# 'markdown' || &buftype !=# ''
    return 0
  endif
  let prefix = line('.') > 1 ? getline(1, line('.') - 1) : []
  let cached = get(b:, 'vimrc_lite_markdown_math_base', {})
  if get(cached, 'prefix', v:null) !=# prefix
    let state = {'display': 0, 'inline': 0, 'comment': 0, 'fence': ''}
    let yaml = !empty(prefix) && prefix[0] ==# '---'
    for index in range(len(prefix))
      if yaml
        if index > 0 && prefix[index] =~# '^\%(---\|\.\.\.\)\s*$'
          let yaml = 0
        endif
        continue
      endif
      let state = s:Scan(prefix[index], state)
    endfor
    let cached = {'prefix': prefix, 'state': state, 'yaml': yaml}
    let b:vimrc_lite_markdown_math_base = cached
  endif
  let text = strpart(getline('.'), 0, col('.') - (mode(1) =~# '^[is]' ? 1 : 0))
  let state = s:Scan(text, cached.state)
  let indented = text =~# '^\%( \{4}\|\t\)' && !cached.state.display && !state.display
  let b:vimrc_lite_markdown_snippet_blocked = cached.yaml || !empty(state.fence)
        \ || state.comment || state.literal || indented
  return !cached.yaml && empty(state.fence) && !state.comment && !state.literal
        \ && (state.display || state.inline) && !indented
endfunction

function! s:Before() abort
  return strpart(getline('.'), 0, col('.') - (mode(1) =~# '^[is]' ? 1 : 0))
endfunction

function! s:Table(prefix) abort
  let dimensions = matchlist(a:prefix, '^\(\d\+\)[xX]\(\d\+\)tb$')
  if empty(dimensions)
    let dimensions = matchlist(a:prefix, '^\(\d\)\(\d\)tb$')
  endif
  if empty(dimensions)
    return ''
  endif
  let columns = str2nr(dimensions[1])
  let rows = str2nr(dimensions[2])
  if columns < 1 || rows < 1 || columns * (rows + 1) > 400
    return ''
  endif
  let result = []
  let field = 1
  for row in range(rows + 1)
    let cells = []
    for column in range(columns)
      call add(cells, '${' . field . (row == 0 ? ':标题' : ':') . '}')
      let field += 1
    endfor
    call add(result, '| ' . join(cells, ' ' . '|' . ' ') . ' |')
    if row == 0
      call add(result, '| ' . join(repeat(['---'], columns), ' ' . '|' . ' ') . ' |')
    endif
  endfor
  return join(result, "\n") . '$0'
endfunction

function! s:Candidate() abort
  let math = VimMarkdownMathContext()
  if get(b:, 'vimrc_lite_markdown_snippet_blocked', 0)
    return []
  endif
  let before = s:Before()
  let token = matchstr(before, '\%(^\|\s\)\zs\d\+[xX]\=\d\+tb$')
  if !empty(token)
    let table = s:Table(token)
    if !empty(table)
      return [token, table]
    endif
  endif
  if math
    let token = matchstr(before, '[;A-Za-z]\+$')
    if has_key(s:math, token) && (before ==# token
          \ || strpart(before, strlen(before) - strlen(token) - 1, 1) !~# '[A-Za-z\\]')
      return [token, s:math[token]]
    endif
  endif
  return []
endfunction

function! VimMarkdownSnippetExpand() abort
  let candidate = s:Candidate()
  if !empty(candidate)
    call vsnip#anonymous(candidate[1], {'prefix': candidate[0],
          \ 'position': {'line': line('.') - 1, 'character': strchars(s:Before())}})
  elseif !get(b:, 'vimrc_lite_markdown_snippet_blocked', 0) && vsnip#expandable()
    call vsnip#expand()
  endif
endfunction

function! VimMarkdownSnippetTab(direction) abort
  let candidate = a:direction > 0 ? s:Candidate() : []
  let expand = a:direction > 0 && !get(b:, 'vimrc_lite_markdown_snippet_blocked', 0)
        \ && (!empty(candidate) || vsnip#expandable())
  if pumvisible()
    if expand && complete_info(['selected']).selected < 0
      return "\<C-e>\<Plug>(vim-lite-markdown-expand)"
    endif
    return a:direction > 0 ? "\<C-n>" : "\<C-p>"
  endif
  if expand
    return "\<Plug>(vim-lite-markdown-expand)"
  endif
  if vsnip#jumpable(a:direction)
    return a:direction > 0 ? "\<Plug>(vsnip-jump-next)" : "\<Plug>(vsnip-jump-prev)"
  endif
  return a:direction > 0 ? "\<Tab>" : "\<S-Tab>"
endfunction

function! s:Auto() abort
  if &filetype !=# 'markdown' || mode(1) !~# '^i' || &paste
        \ || !get(g:, 'vimrc_lite_markdown_math_auto', 1)
    return
  endif
  let before = s:Before()
  if before !~# '\d$\|/$' || !VimMarkdownMathContext()
    return
  endif
  let numerator = ''
  if before =~# '/$'
    let source = strpart(before, 0, strlen(before) - 1)
    if source =~# ')$'
      let balance = 1
      let position = strlen(source) - 2
      while position >= 0 && balance
        let char = strpart(source, position, 1)
        let balance += char ==# ')' ? 1 : char ==# '(' ? -1 : 0
        let position -= 1
      endwhile
      if !balance
        let numerator = strpart(source, position + 1)
      endif
    else
      let numerator = matchstr(source,
            \ '\%(\\[A-Za-z]\+\|[A-Za-z0-9]\+\)\%([_^]\%({[^{}]*}\|\d\+\)\)*$')
    endif
    if !empty(numerator)
      let value = numerator[0] ==# '(' ? strpart(numerator, 1, strlen(numerator) - 2) : numerator
      call vsnip#anonymous('\\frac{' . escape(value, '\$}') . '}{${1}}$0',
            \ {'prefix': numerator . '/'})
    endif
  else
    let subscript = matchstr(before, '\%(^\|[^A-Za-z\\]\)\zs[A-Za-z]\d\+$')
    let numbered = matchstr(before, '[A-Za-z]_\d\{2,}$')
    let extended = matchstr(before, '[A-Za-z]_{\d\+}\d\+$')
    if !empty(subscript) || !empty(numbered) || !empty(extended)
      let original = !empty(subscript) ? subscript : !empty(numbered) ? numbered : extended
      let digits = substitute(original, '\D', '', 'g')
      let replacement = original[0] . (strlen(digits) == 1 ? '_' . digits : '_{' . digits . '}')
      let column = col('.')
      undojoin
      call setline('.', strpart(getline('.'), 0, strlen(before) - strlen(original))
            \ . replacement . strpart(getline('.'), strlen(before)))
      call cursor(line('.'), column + strlen(replacement) - strlen(original))
    endif
  endif
endfunction

function! VimMarkdownSnippetsAttach() abort
  if !get(g:, 'vimrc_lite_markdown_snippets', 1) || !s:Load()
    return
  endif
  imap <silent><buffer> <Tab> <Ignore><Plug>(vim-lite-markdown-tab)
  smap <silent><buffer> <Tab> <Ignore><Plug>(vim-lite-markdown-tab)
  imap <silent><buffer> <S-Tab> <Ignore><Plug>(vim-lite-markdown-backtab)
  smap <silent><buffer> <S-Tab> <Ignore><Plug>(vim-lite-markdown-backtab)
  imap <silent><expr><buffer> <Plug>(vim-lite-markdown-tab) VimMarkdownSnippetTab(1)
  smap <silent><expr><buffer> <Plug>(vim-lite-markdown-tab) VimMarkdownSnippetTab(1)
  imap <silent><expr><buffer> <Plug>(vim-lite-markdown-backtab) VimMarkdownSnippetTab(-1)
  smap <silent><expr><buffer> <Plug>(vim-lite-markdown-backtab) VimMarkdownSnippetTab(-1)
  inoremap <silent><buffer> <Plug>(vim-lite-markdown-expand)
        \ <Esc>:<C-u>call VimMarkdownSnippetExpand()<CR>
  snoremap <silent><buffer> <Plug>(vim-lite-markdown-expand)
        \ <Esc>:call VimMarkdownSnippetExpand()<CR>
endfunction

augroup vimrc_lite_markdown_snippets
  autocmd!
  autocmd TextChangedI * call s:Auto()
augroup END
