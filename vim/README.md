# 离线极简 Vim

面向 Linux 上的完整 Vim 8/9，主要用于 Python、C/C++。配置与 TokyoNight Night
主题全部在本目录，无插件管理器、第三方插件、语言服务器或自动下载。
主题默认透明背景，不需要特殊字体。

`.vimrc` 保留基础设置、通用功能和快捷键；`dashboard.vim` 管理首页，
`search.vim` 和 `search.sh` 连接 Vim 内置终端与 fd/ripgrep/fzf，均由配置显式加载。

## 安装

将整个 `vim/` 目录复制到目标机器，然后以目标用户身份运行：

```bash
# Vim 已可用时直接安装配置；否则通过系统包管理器安装 Vim。
bash ~/Dotfiles/vim/vim-install.sh

# 完全离线：仅复制配置和主题，不检查或安装系统软件。
bash ~/Dotfiles/vim/vim-install.sh --config-only
```

默认安装到当前用户目录：

```text
~/.vimrc
~/.vim/dashboard.vim
~/.vim/search.vim
~/.vim/search.sh
~/.vim/colors/tokyonight-night.vim
~/.vim/colors/LICENSE.tokyonight
~/.vim/colors/README.md
```

系统软件支持 apt-get、dnf、yum、apk、pacman、zypper。仅此步骤可能联网和调用
`sudo`，不要用 `sudo` 执行整个脚本，否则会安装到 root 的用户目录。
缺失 Vim 且机器断网时，需要先用系统的离线软件包安装 Vim，或使用 `--config-only`。
有 Vim 但版本过旧、缺少必要功能时，也会尝试系统软件安装，并再次检查。

文件查找需要 `fd`（或 `fdfind`）和 `fzf`；文本搜索需要 `rg` 和 `fzf`。
fzf 以 **0.44.1 及以上版本**为兼容基线；Vim 需要 `+terminal` 和 `+timers`。
安装脚本只提示缺失的搜索工具，不会安装或下载它们；`--config-only` 不检查依赖。
请自行安装，例如 Debian/Ubuntu：

```bash
sudo apt install fd-find ripgrep fzf
```

其他发行版安装对应的 fd、ripgrep、fzf 软件包，并确认命令位于 `PATH`。
不需要建立 `fd` 到 `fdfind` 的链接，也不需要安装 fzf.vim、bat 或 Python。

已有同名文件先改名为 `原文件.bak.时间戳.进程号`；符号链接会备份链接本身，
不会改写它指向的文件。内容相同的普通文件跳过，不重复备份。其他主题和旧插件
文件保留在原处；此配置清空 `packpath` 并关闭 `plugin` 脚本的自动加载，
所以已有的插件包不会自动加载。运行时只保留 Vim 自带目录和本地主题所在目录。
回退时将相应备份复制回原路径即可。安装不修改 Neovim、shell 或 tmux 配置。

```bash
# 安装到指定用户目录，也便于试装。
bash ~/Dotfiles/vim/vim-install.sh --config-only --target-dir /tmp/vim-demo

# 不安装，直接试用仓库中的配置和主题。
vim -u ~/Dotfiles/vim/.vimrc

# 真彩色显示不正常时使用 256 色。
vim --cmd 'let g:vimrc_lite_truecolor = 0' -u ~/Dotfiles/vim/.vimrc

# 使用 TokyoNight 自带的深色背景。
vim --cmd 'let g:vimrc_lite_transparent = 0' -u ~/Dotfiles/vim/.vimrc
```

以下可选变量均在加载 vimrc 前设置；也可直接将赋值放在自己的 vimrc 顶部：

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `g:vimrc_lite_truecolor` | `1` | 使用真彩色；设为 `0` 使用主题的静态 256 色 |
| `g:vimrc_lite_transparent` | `1` | 背景透明；设为 `0` 恢复原版背景 |
| `g:vimrc_lite_osc52` | 检测 SSH 环境 | 是否为显式复制发送 OSC 52；可手动设为 `0` 或 `1` |
| `g:vimrc_lite_dashboard` | `1` | 无参数交互启动时显示首页；设为 `0` 关闭自动显示 |

## 首页

直接运行 `vim`，首页只显示一句居中的 slogan：
`Les annees heureuses sont des annees perdues.`
文字使用斜体，沿用正文颜色，无菜单、图标、下划线、背景高亮或页脚，也不注册首页专用按键。
斜体显示需要终端和字体支持。
可通过原有 `<leader>ff`、`<leader>fp` 搜索，或用 `<leader>bn` 新建文件。

用 `:Dashboard` 可手动回到首页，已打开文件及未保存内容会保留。
关闭自动首页后，该命令仍可使用：

```bash
vim --cmd 'let g:vimrc_lite_dashboard = 0'
```

指定文件、目录、管道输入、会话（`-S`）或启动命令（`-c`、`+cmd`）时，
以及 Ex／批处理模式下，不自动显示首页。`--cmd` 仍可用于预设配置变量。
首页不进入普通 buffer 列表；离开后恢复编辑界面，关闭最后一个文件仍退出 Vim。
窗口缩放时自动调整居中和留白；窄窗口使用原生横向滚动查看完整文字。

## 快捷键

`<leader>` 是空格；表中未特别说明的按键用于普通模式。`H/L` 就是 `Shift-h/l`。

| 按键 | 功能 |
| --- | --- |
| `Ctrl-s` | 保存全部文件，支持普通、插入、可视模式 |
| `Ctrl-w` | 关闭当前 buffer；未保存时选择保存、放弃或取消 |
| `H/L`、`Alt-o/i` | 上一个／下一个 buffer |
| `<leader>bn` | 新建空 buffer |
| `<leader>bp` | 列出 buffer，然后输入编号或名称；支持 Tab 补全 |
| `<leader>1`～`9` | 跳到按 buffer 编号排序的第 1～9 个已列出 buffer |
| `<leader>bP` / `bC` | 复制文件绝对路径／全文 |
| `<leader>bD` | 清空全文；可视模式下删除选区，保留复制寄存器 |
| `<leader>bw` | 删除行尾空白，保留视图和搜索记录，可撤销 |
| `tn` / `tj` / `tk` / `to` | 新建／上一个／下一个／只留当前标签页 |
| `<leader>aN` / `an` | 在新标签页打开当前 buffer／新建空标签页 |
| `<leader>ah` / `al` / `ao` | 标签页左移／右移／只留当前 |
| `Ctrl-h/j/k/l`、`Alt-h/j/k/l` | 聚焦左／下／上／右侧 Vim 窗口 |
| `Ctrl-Up/Down` | 窗口高度减小／增大 2 行 |
| `Ctrl-Left/Right` | 窗口宽度减小／增大 2 列 |
| `<leader>v` / `e` | 垂直分屏／开关左侧内置文件浏览器 |
| `<leader>ff` | fd/fdfind 枚举文件，fzf 即时模糊筛选 |
| `<leader>fp` | ripgrep 实时正则搜索，预览并跳转到匹配位置 |
| `<leader>fo` | 从 Vim 保存的最近文件记录中输入编号选择 |
| `<leader>fh` | 清除本次搜索高亮 |
| `[q` / `]q` | 上一个／下一个 quickfix 结果 |
| `<leader>xQ` / `xL` | 开关 quickfix／location list |
| `<leader>;` | 新标签页打开内置终端，使用 Vim 的 `shell` 设置 |
| 终端内双 `Esc` | 进入终端普通模式；按 `i` 返回输入 |
| `<leader>nh` / `q` | 查看消息历史／退出当前窗口，未保存时提示 |
| `<leader>gg` | 在新标签页的内置终端中打开 LazyGit，退出后自动关闭该标签页 |
| 可视模式 `<` / `>` | 调整缩进后保留选区 |
| 帮助或 quickfix 窗口内 `q` | 关闭辅助窗口 |

`Ctrl-w` 已用于关闭 buffer，原生窗口前缀被替换。窗口移动映射不会递归触发
关闭；其他操作可用 `:split`、`:wincmd =` 等命令。关闭 buffer 时保留分屏；
最后一个已列出的普通 buffer 关闭时退出 Vim。运行中的终端必须先退出 shell，
不会因这个快捷键直接杀死进程。

若终端拦截 `Ctrl-s` 导致暂停，可按 `Ctrl-q` 恢复，使用 `:wall` 保存。
如需启用该键，可自行在 shell 中运行 `stty -ixon`；安装脚本不修改流控。
Alt、Ctrl-方向键的传递取决于终端和 tmux 设置。

LazyGit 使用当前 Vim 工作目录；从项目目录启动 Vim，按空格后再按 `gg` 即可。
需要系统已有 `lazygit` 且 Vim 支持 `+terminal`，缺失时只提示，不自动下载。
LazyGit 内使用它自己的按键，通常按 `q` 退出；不需要任何 Vim Git 插件。

## Python / C++ 工作流

- Python/C/C++/CUDA 使用 4 空格缩进，Makefile 保留 Tab。
- Python 按缩进折叠，C/C++/CUDA 按 Vim 语法折叠，打开文件时全部展开。
  保留 `za/zA`、`zo/zO`、`zc/zC`、`zR/zM`、`zr/zm` 等原生操作。
- 插入模式用 `Ctrl-n/p` 补全当前及已加载 buffer 中的词和现有 tags，
  用 `Ctrl-x Ctrl-f` 补全路径。这些不提供 LSP 语义补全。
- 原生 `%` 匹配括号，`i{`/`a{` 等选择括号内容；不模拟函数、类、循环的结构文本对象。
- 已有 tags 文件时使用 `Ctrl-]` 和 `Ctrl-t`；配置不自动生成索引。
- 构建使用项目自己的命令或 `:make`，不默认指定 C++ 标准或自动运行代码。

## 文件和文本搜索

搜索从当前文件目录向上找最近的 `.git`、`_darcs`、`.hg`、`.bzr`、`.svn`、
`Makefile`、`package.json` 或 `pom.xml`；首页和无文件 buffer 从当前工作目录开始。
找不到标记时使用当前工作目录。仅搜索进程切换目录，Vim 的 `:pwd` 保持不变。

- `ff`：优先用 `fd`，否则使用 `fdfind`；默认排除隐藏文件，遵守 ignore 规则。
  fzf 按文件路径进行智能大小写的模糊筛选，不启用 fzf 扩展查询语法；默认不显示预览。
- `fp`：直接输入 **ripgrep 正则**，约 100 ms 防抖后刷新结果。小写查询忽略大小写，
  包含大写则区分大小写。包含隐藏文件、排除 `.git`，遵守 ignore 规则；搜索所有文本
  文件，不再限于 Python/C++，也不再询问 glob。空查询不扫描文件。
- `.gitignore`、`.ignore` 等由 fd/rg 按各自的原生规则处理；不再硬编码排除 `build`
  等目录，需要排除的生成文件应写入项目 ignore 文件。搜索读取磁盘内容。

fzf 在居中终端弹窗中运行，宽约 90%、高约 80%，沿用 TokyoNight 配色与透明设置。
不支持终端弹窗的 Vim 使用底部分屏；缺少必要功能或程序时提示，不使用旧同步搜索。
`fp` 宽屏右侧显示带行号的上下文，窄屏自动改为上下布局，命中行带标记和颜色。

| 搜索界面按键 | 功能 |
| --- | --- |
| 直接输入 | 模糊筛选文件／刷新文本搜索 |
| `Ctrl-j/k`、方向键 | 下一个／上一个结果 |
| `Ctrl-n/p` | 下一条／上一条查询历史 |
| `Ctrl-u/d` | `fp` 预览上翻／下翻半页 |
| `Enter` | 在原窗口打开文件；文本搜索定位到行、列 |
| `Esc`、`Ctrl-c` | 取消并返回原窗口 |

这里采用 fzf 的单一输入模式，没有 Telescope 的普通／插入模式切换。
搜索期间将终端按键序列的等待上限设为 30 ms；确认单次 `Esc` 后直接发送取消指令，
避免 Vim 与 fzf 叠加等待。搜索结束或配置重载时恢复原设置，普通映射的等待时间不变。
无匹配时保持空列表；无效正则显示错误，可以继续编辑查询。取消搜索不丢弃未保存内容，
也不清空原有 quickfix。结果直接打开文件，不自动写入 quickfix。
文件名及查询中的空格、中文、引号和 shell 特殊字符会作为数据处理。

两类查询分别保存在 `${XDG_STATE_HOME:-~/.local/state}/vim-lite/search/`，各保留 100 条。
历史目录不可写时仍可搜索，但不保存历史。搜索界面隔离 `FZF_DEFAULT_OPTS`、
`FZF_DEFAULT_COMMAND` 和 ripgrep 用户配置文件，以保持按键、数据格式和搜索规则一致；
不修改当前 shell 的环境设置。

## 其他边界

最近文件来自 viminfo，当前会话新开的文件不一定立即进入该列表。
窗口导航限于 Vim 内部，不跨 tmux 窗格。没有 LSP、DAP、Git hunk、Flash、
Tree-sitter、浮动 shell 或项目替换界面；普通文本替换可用 Vim 自带 `:%s`。

## SSH 剪贴板

`<leader>bP` 和 `<leader>bC` 总会写入 Vim 未命名寄存器，可直接用 `p` 粘贴。
检测到 `SSH_TTY` 或 `SSH_CONNECTION` 时，还会借助系统已有的 `base64`
向当前终端发送 OSC 52。无 SSH 时，如果 Vim 支持系统剪贴板，则同步到 `+` 寄存器。
普通 `y` 和删除操作不触发自定义远程复制。

OSC 52 要求本地终端允许应用写入剪贴板；tmux 内还需要 `set -g set-clipboard on`
及相应终端剪贴板能力。本 Dotfiles 的 tmux 配置已有该选项。机器缺少 `base64`、
没有可写终端或编码失败时，只保留内部复制并提示，不会安装依赖。
终端可能拒绝 OSC 52 或限制长度；“已发送”不表示本地已接收，也不会读取远程剪贴板确认。
实际效果请在 SSH/tmux 中复制中文、多行文本，再在本地应用粘贴验证。

## 验证

```bash
# 测试只使用 Python 标准库，配置运行时不依赖 Python。
python3 ~/Dotfiles/vim/tests/test_vim.py
```

测试在临时目录执行，覆盖配置、主题、首页启动与交互、buffer、搜索、复制及安装脚本。
fd/rg 数据规则使用真实程序验证；终端生命周期另有模拟 fzf 的测试。真实按键测试通过
PTY 测量单次 Esc 的退出延迟，并验证方向键和设置恢复。真实 fzf 交互测试
需要已安装 fzf，缺少时明确跳过。软件包安装使用模拟命令，不实际安装系统软件或联网。
本机实测 Vim 9.1；Vim 8 采用传统 Vimscript 和特性检查，但未在独立 Vim 8 上实测。
缺少 `+terminal` 的 Vim 不注册终端快捷键；没有 `+clipboard` 也可使用内部复制和 OSC 52。
