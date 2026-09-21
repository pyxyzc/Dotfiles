# dotfiles

面向 Linux 的个人配置集合，每个子目录独立安装、互不耦合。Vim 配置不使用插件
管理器，tmux 通过 TPM 管理插件。

| 目录 | 内容 | 安装入口 |
| --- | --- | --- |
| `vim/` | 离线极简 Vim 8/9 配置（Python、C/C++），随配置保存主题与固定版本 LSP 客户端 | `bash vim/vim-install.sh` |
| `tmux/` | tmux 配置、TokyoNight 状态栏与 TPM 插件 | `bash tmux/tmux-install.sh` |
| `lazygit/` | 固定版本的 LazyGit 二进制 | `bash lazygit/lazygit-install.sh` |
| `network/` | 代理、镜像与常用 shell 别名配置 | `bash network/proxy.sh` |

## 安装

以目标用户身份运行对应脚本，不要用 `sudo` 执行整个脚本（只有系统软件安装会按需
调用 `sudo`）。这三个安装脚本都支持 `--help`；`vim-install.sh` 与 `tmux-install.sh`
还提供 `--config-only`，仅复制配置、不检查依赖也不联网。

```bash
bash vim/vim-install.sh
bash tmux/tmux-install.sh
bash lazygit/lazygit-install.sh
```

Vim 配置的完整说明、快捷键、LSP 与搜索行为见 [vim/README.md](vim/README.md)。
安装脚本会先备份再替换，内容或版本一致时跳过，可重复运行。

## 网络安全

`network/proxy.sh` 会把代理与镜像设置写入 `~/.curlrc`、`~/.wgetrc`、`~/.bashrc`，
并**全局关闭 TLS 证书校验**（curl `insecure`、wget `check-certificate = off`、
git `http.sslVerify false`）。这会使 HTTPS 连接不再验证服务器身份，存在中间人攻击
风险，只应在自控的代理或镜像环境中使用。脚本运行结束时会打印相应警告；不再需要
代理时，请移除上述文件中的受管块及 git 全局 `sslVerify` 设置。

## 测试

离线回归测试只使用 Python 标准库：

```bash
python3 vim/tests/test_vim.py          # Vim 配置、LSP 与 vim-install
python3 vim/tests/test_installers.py   # tmux、lazygit 安装脚本（模拟命令）
python3 vim/tests/test_vim_style.py    # Vimscript 代码风格
python3 vim/tests/test_lsp.py          # 仅 LSP（已包含在 test_vim.py 中）
```

## 许可证

除第三方组件外，本仓库以 GPLv3 发布，见 [LICENSE](LICENSE)。`vim/colors/` 与
`vim/vendor/` 下的主题和插件保留各自许可证。
