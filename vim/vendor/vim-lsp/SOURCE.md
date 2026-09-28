# 随配置保存的 vim-lsp

- 上游：https://github.com/prabirshrestha/vim-lsp
- 固定提交：`bbffa60cb08a6a2d67e2086a89699ab00a084fe9`
- 源码归档：https://codeload.github.com/prabirshrestha/vim-lsp/tar.gz/bbffa60cb08a6a2d67e2086a89699ab00a084fe9
- 本次下载归档的 SHA-256：`e7e0456fad60c39c72874d24891a28dff73734140b2bf8461436cbd4ad2b3956`
- 收录范围：`autoload/`、`plugin/`、`ftplugin/`、`syntax/`、`doc/`、`README.md`、`LICENSE`、`LICENSE-THIRD-PARTY`。
- 上述 SHA-256 对应原始上游归档；当前快照额外包含下列本地补丁，不再宣称完全原样。
- 服务器配置适配位于上两级的 `lsp.vim`；上游许可证及未列出的源码保持不变。

## 本地补丁：UTF-16 边界转换（2026-09-28）

本配置沿用 LSP 默认 UTF-16 位置编码，不协商 UTF-8 或 UTF-32。
上游用码点索引处理部分协议位置，导致非 BMP 字符后的请求、同步、跳转及文本编辑错位。
依据 [LSP Position / PositionEncodingKind](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#position)，
在以下边界统一转换，内部 diff 算法仍使用码点索引：

- 新增 `autoload/lsp/utils/utf16.vim`：UTF-16 长度、字节位置和切片。优先原生
  `strutf16len(..., 1)` / `byteidxcomp(..., ..., 1)`，旧 Vim 按码点回退；组合字符分别计数。
- `autoload/lsp/utils/position.vim`、`autoload/lsp/utils.vim`：双向位置转换及空文件处理。
- `autoload/lsp/utils/diff.vim`：增量变更的 start/end/rangeLength 转为 UTF-16；
  原生按整行生成 diff 的路径无需字符偏移转换。
- `autoload/lsp/utils/text_edit.vim`：按 UTF-16 范围替换文本并恢复光标。
- `autoload/lsp/omni.vim`、`autoload/lsp/ui/vim/completion.vim`：补全范围、追加编辑、
  简单 snippet 的 Unicode 及跨行光标位置。

`tests/test_lsp.py` 覆盖上述默认启用路径、UTF-16 单元边界、组合音标、变体选择符、
零宽连接符、补充平面组合字符、空文件及回退算法；安装回归逐文件核对整个快照。
`tests/lsp_latency.py --unicode` 使用真实 clangd/Pyright 检查未保存内容及响应时间。
回退算法已在独立 Vim 8.2.5172 完整回归及 Vim 8.0.1394 Unicode 专项中运行。
早期 Vim 8 缺少 `str2list()` 时，按最多 128 个码点分批解码，保留组合字符；
字节位置转换整批跳过已确认范围，仅逐字符处理末批，不扫描位置之后的长行尾部。
`tests/utf16_latency.py` 提供长行转换基准及原逐字符扫描的 `--reference` 对照。
Vim 8.0 的补全附加编辑已由下述候选标记补丁修复，不能由这些专项推断整个客户端兼容。
配置关闭的语义 token、
signature-help 等上游可选功能不属于本补丁的已验证范围。

## 本地补丁：回退 diff 延迟（2026-09-28）

`autoload/lsp/utils/diff.vim` 的非原生 diff 路径增加相同内容快速返回，按 256 行块跳过
公共行，并用原生字符串切片的二分比较查找公共字符前后缀，避免逐字符 `strgetchar`
反复从行首解码形成平方级开销。UTF-16 协议转换、细粒度变更和完整文档内容不变。

`tests/test_lsp_diff.py` 通过千组随机 Unicode 编辑、EOF 和块边界重建文档并核对
rangeLength，且确认输入未被修改。`tests/test_lsp.py` 在临时客户端副本中禁用监听器
和原生 diff，验证实际协议同步；这些专项也已在独立 Vim 8.0.1394 上通过。
`tests/lsp_diff_latency.py` 记录回退算法成本。本机正常启用监听器，因此不能把回退路径
的提速数字当作默认 LSP 请求的端到端提速。

## 本地补丁：早期 Vim 8 补全元数据（2026-09-28）

8.0.1493 之前没有补全项 `user_data`，上游因此默认关闭补全附加编辑。
`autoload/lsp/omni.vim` 为这类版本保留内部元数据，在实际显示的候选副本上添加
`[LSP 服务器:编号]` 菜单标记，再根据标记和 word/abbr/kind/info 精确找回选中项；
同名候选也能选择不同附加编辑。原内部候选不被删除元数据，支持后续筛选或重绘。
支持原生 `user_data` 的版本不使用这些菜单标记。

配置入口 `lsp.vim` 因此默认启用 `g:lsp_text_edit_enabled`，但保留用户显式的 `0`。
`tests/test_lsp.py` 在真实 Vim 8.0.1394 以及强制旧版分支的新版 Vim 上验证：
Unicode 附加编辑、两个同名候选、取消、禁用编辑、错误候选身份与协议 snippet 展开。
小项目真实 clangd/Pyright 验收另外通过，不把模拟服务等同于所有语言服务器行为。

## 人工升级

1. 确定新的完整提交号，下载该提交的源码归档并检查上游变更和许可证。
2. 整体替换上面列出的目录及文件，避免保留旧提交中已删除的文件；不要加入 `.git`、上游 CI 或测试工具依赖。
3. 对照本地补丁清单重新应用仍需保留的修复；若上游已修复，先验证等价性再删除本地补丁。
   更新本文件的提交号、归档地址、校验值、收录范围及补丁清单。
4. 在 `vim/` 目录运行 `PYTHONPATH=tests python3 -m unittest test_vim test_tree test_completion test_clipboard test_edit test_matchparen test_lsp test_lsp_diff test_vim_style`，
   再运行 `python3 tests/lsp_latency.py --rounds 5 --unicode` 验证真实 Pyright、clangd。
5. 将源码快照和适配变更一起提交。安装脚本仅复制此快照，不访问上游。

回退源码时恢复此前的整个快照及对应适配配置；回退安装时恢复安装脚本生成的插件目录和配置文件备份。
