# Markdown · TokyoNight

打开 `example.md`，按 `Space m p` 查看浏览器实时预览；未保存的编辑也会更新。
浏览器预览需要 Python 3，不需要 pip、Node 或联网。桌面环境用 `xdg-open` 打开；
SSH 或无桌面环境显示完整 URL，可通过 SSH 转发 URL 中的本地端口访问。

| 按键 | 操作 |
| --- | --- |
| `Space m p` / `Space m s` | 打开预览 / 停止服务 |
| `Space m o` | 标题目录；Enter 跳转，q 关闭 |
| `Space m r` | 原生阅读 / 源码视图 |
| `Space m f` | 专注写作 |
| `Space m x` | 勾选任务或为列表添加任务框，支持选区 |
| `Space m t` | 中文表格对齐 |
| `Space m i` | 插入模板；也可 `:VimMarkdownInsert code python` |
| `Space m l` | 打开光标下的行内链接或标题锚点 |
| `Space m h` | 操作提示 |
| `[h` / `]h` | 上一个 / 下一个标题 |
| 选区 `Space m b` / `m i` / `m c` | 粗体 / 斜体 / 行内代码 |

Enter 续写列表与引用，空列表项再按 Enter 结束。代码块中保持普通换行。
原生阅读支持表格圆角边框与中文自动对齐、彩色标题和提示块、代码语言卡片、链接／图片
徽标、注释隐藏，以及未完成／完成／进行中／阻塞任务状态。完成项文字变暗并加删除线。
光标行与选区显示源码；插入时暂时撤下装饰。状态栏 `[MD:read]` / `[MD:source]` 显示当前
文档模式，同文档的分屏同步。完整表格排版需要 Vim 虚拟文本，Vim 8 保留基本符号与颜色。
浏览器支持代码高亮、任务、表格、删除线、图片、提示块和 KaTeX 公式。
顶部可切换自由阅读、折叠目录、打印或保存为 PDF；代码块可复制。
原始 HTML 按文字显示；Mermaid 流程图、甘特图及 PlantUML 围栏在本地渲染。
本地图片限定在项目根目录内，浏览器里的本地文档链接请在 Vim 中打开。
`:VimMarkdownPreview!` 仅显示 URL。退出 Vim、关闭源 buffer 或重载配置时会停止服务。

可在 `~/.vim/settings.vim` 自定义：

```vim
let g:vimrc_lite_markdown_render = 1
let g:vimrc_lite_markdown_lists = 1
let g:vimrc_lite_markdown_debounce = 150
let g:vimrc_lite_markdown_browser = ['firefox', '--new-tab']
```

新增笔记功能：

- `Space m v`：粘贴图片到当前文档旁的 `imgs/`；`Space m V` 强制浏览器通道，适合 SSH。
  浏览器显示「等待中」后，点击粘贴图片或 Ctrl-v，引用自动写回原位置。
- `:VimMarkdownImageSize 60% center`：当前行图片的宽度和居中；像素、left/right 也可用。
- 状态栏显示当前章节路径；`Space m c` 生成文内目录，`Space m u` 更新，默认保存时更新。
  `:VimMarkdownToc 2` 限制到两级，`:VimMarkdownTocRemove` 删除生成的目录。
- `Space m z` 折叠／展开当前章节，`Space m Z` 折叠全部；
  `:VimMarkdownFold level 2` 展开到两级，`open` 展开全部，`off` 关闭。
- 输入 `link`、`code`、`title`、`4x4tb` 后按 Tab 展开，Tab／Shift-Tab 填写占位符，支持嵌套。
  `mk`／`dm` 插入公式，数学区域中 `ff`、`sqrt`、`sum`、`int`、`matrix`、`alpha`、`;a` 等
  配合 Tab 使用。`A1` 和 `x/` 自动转换为下标与分数，普通文字、代码和注释不转换。
- Markdown 默认自动保存，空闲 1500 ms、退出插入、切换文件及失焦时触发，`Space m a`
  开关当前文档。未命名和只读文件不保存，外部修改不会被自动覆盖。
- Mermaid 离线绘图；PlantUML 需要本地 Java，没有 Graphviz 时使用内置 Smetana。

完整配置与个人片段格式见上级 README；可打开 `notes-example.md` 练习这些功能。

设计参考及离线资源许可证见 [vendor/SOURCE.md](vendor/SOURCE.md)。
