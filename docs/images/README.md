# README 图片

README 当前展示的三张界面图片是用户于 2026-11-02 提供的 macOS 实机截图，直接复制原始 PNG，未裁剪、重绘或修改图片内容。应用图标来自正式图标资源。

## 当前使用的实机截图

| 文件 | 内容 | 原始文件 |
|---|---|---|
| `screenshots/library.png` | 主文库窗口、文献列表、元数据与 PDF 预览 | `2026-11-02_100601@2x.png` |
| `screenshots/add-paper.png` | 添加文献菜单：文件导入、标识符查询与手动录入 | `2026-11-02_100821@2x.png` |
| `screenshots/settings.png` | 通用设置：语言、外观、默认 PDF 阅读器与文件库 | `2026-11-02_100700@2x.png` |

截图反映拍摄时的应用界面与文库状态。它们不是下述脚本生成的图片，也不包含在旧的 `manifest.json` 生成记录中。

## 图标与历史组件渲染图

以下文件继续保留，用于说明此前的组件渲染与文档生成流程；三张历史界面图已不用于 README 的主图和界面预览。

| 文件 | 内容 | 来源 |
|---|---|---|
| `app-icon.png` | 「折页」米灰版正式图标 | 与 `Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png` 一致；[母版与导出方式](../../App/IconSource/README.md) |
| `library.png` | 文集、标签、列表和元数据检查器 | `NativeLibraryView`、`PaperDetailView` 等生产组件；32 条合成演示文献 |
| `import-preview.png` | BibTeX 导入选择和重复项提示 | 生产 `ImportPreviewView`；不执行导入 |
| `templates.png` | 元数据与标注模板编辑区 | 生产 `SettingsView`；演示模板页 |

## 重新生成图标与历史渲染图

图标由正式母版导出：

```sh
scripts/render-app-icon.sh
```

历史的 `library.png`、`import-preview.png`、`templates.png` 使用独立的文档渲染器：

```sh
scripts/render-readme-images.sh
```

需要本机可用的 Xcode 或 Command Line Tools、macOS SDK 和图形会话。脚本使用唯一的临时 `.app` 偏好域、临时 JSON 文库和模块缓存；退出后清除临时目录。它不启动正式 PaperManager，不读取个人文库，不发起元数据查询。

输出为 2×、浅色、不透明 PNG。自定义输出目录可设置 `PAPERMANAGER_DOCUMENTATION_OUTPUT`。该脚本不会更新 `screenshots/` 中的实机截图。

## 历史渲染图的呈现边界

图片展示原生组件内容，不包含主应用窗口的标题栏和工具栏。离屏缓存不能完整表达实时背景材质；侧栏省略选中强调，主列表仍保留文献选择和检查器内容。模板页比正式设置窗口更高，便于展示两个编辑区。

这些历史渲染图用于项目介绍，不用于逐像素回归验收。演示文献的标题、作者、年份、标识符和摘要都是合成内容。它们的尺寸、数据隔离方法、生成器及生产源指纹见 [manifest.json](manifest.json)；这些记录与合成数据说明不适用于 `screenshots/` 中的实机截图。
