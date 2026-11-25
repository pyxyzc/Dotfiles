# Markdown 写作示例

这份文档可以直接编辑。标题、代码和任务保持清楚的层次，正文保留稳定的源码布局。
长段落使用软换行；普通 j / k 按屏幕行移动，3j / 3k 按文件行移动。

## 列表与任务

- 在本行末尾按 Enter 延续列表。
  - 子列表保持缩进。
- [ ] Space m x 切换任务。
- [x] 新任务始终从未完成状态开始。

1. 有序列表自动续号。
2. 空条目再按 Enter 退出。

> [!NOTE]
> 引用也可以续写；浏览器预览将它显示为提示块。

## 代码与表格

```python
# 代码块内的 Markdown 标记是字面量。
tasks = ['- [ ] one', '# heading']
print('中文与 English')
```

将光标放进表格，按 Space m t 显式对齐；窗口缩放不会改动表格。

| 名称 | 数值 | 表达式 |
| :--- | ---: | :---: |
| 中文 | 42 | `a|b` |
| English | 7 | a\|b |

## 导航与插入

用 [h / ]h 跳标题，Space m o 打开目录。Space m c 插入或更新文内目录。
用 Space m z 手动折叠当前章节，Space m f 进入专注模式。

[跳到数学章节](#数学与图片)

## 数学与图片

用 `:VimMarkdownInsert math` 插入公式模板，Tab 保留原有行为。

$$
E = mc^2,\qquad \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
$$

图片使用普通 Markdown 路径，例如 `![描述](imgs/image.png)`。
Space m p 显式打开离线预览，Space m s 停止；SSH 下使用 :VimMarkdownPreview! 查看地址。
