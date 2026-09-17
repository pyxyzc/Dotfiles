# 随配置保存的 vim-lsp

- 上游：https://github.com/prabirshrestha/vim-lsp
- 固定提交：`bbffa60cb08a6a2d67e2086a89699ab00a084fe9`
- 源码归档：https://codeload.github.com/prabirshrestha/vim-lsp/tar.gz/bbffa60cb08a6a2d67e2086a89699ab00a084fe9
- 本次下载归档的 SHA-256：`e7e0456fad60c39c72874d24891a28dff73734140b2bf8461436cbd4ad2b3956`
- 原样收录：`autoload/`、`plugin/`、`ftplugin/`、`syntax/`、`doc/`、`README.md`、`LICENSE`、`LICENSE-THIRD-PARTY`。
- 适配代码位于上两级的 `lsp.vim`；本目录不修改上游实现。

## 人工升级

1. 确定新的完整提交号，下载该提交的源码归档并检查上游变更和许可证。
2. 整体替换上面列出的目录及文件，避免保留旧提交中已删除的文件；不要加入 `.git`、上游 CI 或测试工具依赖。
3. 更新本文件的提交号、归档地址、校验值及收录范围。
4. 从仓库根目录运行 `python3 vim/tests/test_vim.py`，并用真实 Pyright、clangd 验证跳转与补全。
5. 将源码快照和适配变更一起提交。安装脚本仅复制此快照，不访问上游。

回退源码时恢复此前的整个快照及对应适配配置；回退安装时恢复安装脚本生成的插件目录和配置文件备份。
