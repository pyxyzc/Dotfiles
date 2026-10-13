" 后台 Vim 只做文件属性查询；每批输出 JSON，不加载用户配置或插件。
set nocompatible encoding=utf-8
try
  let request = json_decode(join(readfile(argv(0)), "\n"))
  let &wildignore = request.wildignore
  let &suffixes = request.suffixes
  let patterns = map(copy(request.ignore), '[v:val =~# "/$", glob2regpat(v:val)]')
  for [directory, files] in items(request.files)
    if empty(files)
      let base = directory =~# '/$' ? directory : directory . '/'
      if request.backend ==# 'readdir'
        let files = map(['.', '..'] + readdir(directory), 'base . v:val')
      else
        let base = fnameescape(base)
        let files = glob(base . '*', 0, 1, 1) + glob(base . '.*', 0, 1, 1)
      endif
    endif
    let entries = []
    let offset = strlen(directory)
    let suffixes = {'link': '@', 'socket': '=', 'fifo': '|', 'dir': '/'}
    for filename in files
      let kind = getftype(filename)
      let suffix = has_key(suffixes, kind) ? suffixes[kind] : executable(filename) ? '*' : ''
      let name = substitute(strpart(filename, offset), '^[/\\]', '', '')
      let hidden = 0
      for pattern in patterns
        let candidate = pattern[0] && kind ==# 'dir' ? name . '/' : name
        if candidate =~# pattern[1]
          let hidden = 1
          break
        endif
      endfor
      if hidden
        continue
      endif
      call add(entries, name . suffix)
      if len(entries) >= 256
        call writefile([json_encode({'directory': directory, 'entries': entries})],
              \ '/dev/stdout', 'a')
        let entries = []
      endif
    endfor
    call writefile([json_encode({'directory': directory, 'entries': entries})], '/dev/stdout', 'a')
  endfor
  call writefile([json_encode({'done': 1})], '/dev/stdout', 'a')
catch
  call writefile([v:exception . ' at ' . v:throwpoint], '/dev/stderr', 'a')
  cquit
endtry
qa!
