# TokyoNight Night（离线 Vim 版本）

来源：<https://github.com/folke/tokyonight.nvim> 的
`extras/vim/colors/tokyonight-night.vim`。

固定版本：`cdc07ac78467a233fd62c493de29a17e0cf2b2b6`。
主题及其衍生修改采用 Apache-2.0，完整许可见 `LICENSE.tokyonight`。
安装和使用不需要访问来源网站，也不依赖 Neovim、Lua 或插件管理器。

本地修改：

- 为原有 GUI 色值添加静态 xterm-256 色值，按 RGB 距离选择 16～255 号颜色；同步文字样式。
- 加载时设置深色背景并重置语法颜色。
- 默认透明背景，可在载入配置前设置 `g:vimrc_lite_transparent = 0` 恢复原版背景。

文件包含上游导出的插件高亮组；这些只是颜色定义，不会安装或加载任何插件。
