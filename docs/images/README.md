# README 图片

这些图片用当前生产代码的原生视图和独立演示数据生成，不是从用户文库截取的实机画面，也不是手绘的界面模型。

| 文件 | 内容 | 来源 |
|---|---|---|
| `app-icon.png` | 应用图标 | 原样复制自 `Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png` |
| `library.png` | 文集、标签、列表和元数据检查器 | `NativeLibraryView`、`PaperDetailView` 等生产组件；32 条合成演示文献 |
| `import-preview.png` | BibTeX 导入选择和重复项提示 | 生产 `ImportPreviewView`；不执行导入 |
| `templates.png` | 元数据与标注模板编辑区 | 生产 `SettingsView`；演示模板页 |

## 重新生成

```sh
scripts/render-readme-images.sh
```

需要本机可用的 Xcode 或 Command Line Tools、macOS SDK 和图形会话。脚本使用唯一的临时 `.app` 偏好域、临时 JSON 文库和模块缓存；退出后清除临时目录。它不启动正式 PaperManager，不读取个人文库，不发起元数据查询。

输出为 2×、浅色、不透明 PNG。自定义输出目录可设置 `PAPERMANAGER_DOCUMENTATION_OUTPUT`。

## 呈现边界

图片展示原生组件内容，不包含主应用窗口的标题栏和工具栏。离屏缓存不能完整表达实时背景材质；侧栏省略选中强调，主列表仍保留文献选择和检查器内容。模板页比正式设置窗口更高，便于展示两个编辑区。

这些图片用于项目介绍，不用于逐像素回归验收。演示文献的标题、作者、年份、标识符和摘要都是合成内容。各图尺寸、数据隔离方法、生成器及生产源指纹见 [manifest.json](manifest.json)。
