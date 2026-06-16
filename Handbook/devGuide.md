# 任务：开发一款 macOS 原生 SwiftUI 论文管理器 PaperManager

你是一名资深 macOS SwiftUI 工程师。请为我从零开发一款 macOS 原生论文管理器，暂定名为 **PaperManager**。它类似 Zotero，但产品理念完全不同：**不采用 Zotero 式数据库托管文献，不把 PDF 复制进应用私有库，不接管用户的文件系统，也不内置沉重 PDF 阅读器**。它应该像一个轻量、优雅、原生的 macOS 文献管理中枢，帮助用户管理本地文件夹里的 PDF、补全文献元信息、提取标注、整理标签、导出 Markdown / BibTeX，并与用户已有的 PDF 阅读器和笔记工作流协作。

请使用 **Swift + SwiftUI + AppKit bridge** 开发，目标平台为 **macOS 14 Sonoma 或更高版本**。不要使用 Electron、React Native、Flutter、Tauri 或任何网页壳方案。

---

## 一、产品定位

PaperManager 是一款面向 macOS 用户的轻量论文管理器。

核心原则：

1. **原生 macOS 应用**
   - 使用 SwiftUI 构建主界面。
   - 必要时使用 AppKit / PDFKit / QuickLook bridge。
   - 界面、菜单、快捷键、拖拽、侧边栏、表格、右键菜单都要符合 macOS 原生习惯。

2. **文件夹优先，而不是数据库优先**
   - 用户的 PDF 文件始终保存在 Finder 中的普通文件夹。
   - 应用不能把 PDF 强制复制进 App Sandbox 内部。
   - 应用只保存 PDF 的安全访问链接 / bookmark data / file URL。
   - 用户可以在 Finder 中自由查看、移动、备份、同步自己的 PDF 文件夹。

3. **轻量中枢，而不是大而全平台**
   - 不内置复杂 PDF 阅读器。
   - 阅读交给用户喜欢的 PDF 应用，例如 Preview、PDF Expert、Skim、Adobe Acrobat 等。
   - PaperManager 负责：
     - 管理文献元数据；
     - 连接 PDF 文件；
     - 提取 PDF 标注；
     - 组织 Collections / Tags；
     - 导入导出 BibTeX；
     - 导出 Markdown / TextBundle；
     - 调用 Quick Look 快速预览；
     - 与 Apple Shortcuts / Clipboard / Finder 协作。

4. **开放数据**
   - 用户的数据不能被锁死。
   - 支持导出 BibTeX。
   - 支持导出 Markdown。
   - 支持复制元数据到剪贴板。
   - 本地元数据应使用清晰、可迁移的结构保存。
   - 优先考虑 JSON / SQLite + 文件 URL 的轻量方案，但绝不能把 PDF 本体塞进数据库。

---

## 二、技术栈要求

请使用以下技术：

- Swift 5.9+
- SwiftUI
- AppKit bridge
- PDFKit
- QuickLook
- UniformTypeIdentifiers
- Combine / Observation
- Swift Concurrency: async / await
- FileManager
- URL bookmark data for security-scoped file access
- Codable
- SQLite 或 SwiftData 二选一用于保存元数据，但不得保存 PDF 二进制内容

建议项目结构：

```text
PaperManager/
  PaperManagerApp.swift

  Models/
    Paper.swift
    Author.swift
    Collection.swift
    Tag.swift
    PaperAnnotation.swift
    Attachment.swift
    AppSettings.swift

  Services/
    LibraryStore.swift
    FileAccessService.swift
    PDFImportService.swift
    PDFMetadataExtractor.swift
    DOIExtractor.swift
    MetadataLookupService.swift
    CrossrefService.swift
    ArxivService.swift
    BibTeXParser.swift
    BibTeXExporter.swift
    AnnotationExtractor.swift
    MarkdownExportService.swift
    TextBundleExportService.swift
    TemplateRenderer.swift
    QuickLookService.swift
    FinderService.swift

  ViewModels/
    LibraryViewModel.swift
    PaperListViewModel.swift
    PaperDetailViewModel.swift
    ImportViewModel.swift
    SettingsViewModel.swift

  Views/
    MainWindow/
      MainWindowView.swift
      SidebarView.swift
      PaperTableView.swift
      InspectorView.swift
    Detail/
      MetadataInspectorView.swift
      AnnotationInspectorView.swift
    Import/
      ImportPDFView.swift
      ImportDOIView.swift
      ImportBibTeXView.swift
    Settings/
      SettingsView.swift
      GeneralSettingsView.swift
      TemplateSettingsView.swift
    Components/
      RatingView.swift
      TagChipView.swift
      EmptyStateView.swift
      SearchFieldView.swift

  Resources/
    DefaultMetadataTemplate.md
    DefaultAnnotationTemplate.md
```

---

## 三、核心数据模型

请先设计清晰的数据模型。

### Paper

每篇论文至少包含：

```swift
struct Paper: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var authors: [Author]
    var year: Int?
    var source: String?          // 期刊 / 会议 / arXiv / 预印本来源
    var doi: String?
    var arxivID: String?
    var abstract: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var paperType: String?
    var citeKey: String?
    var rating: Int
    var notes: String

    var attachment: Attachment?
    var collections: [UUID]
    var tags: [UUID]

    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
}
```

### Attachment

```swift
struct Attachment: Identifiable, Codable, Hashable {
    var id: UUID
    var fileURL: URL?
    var bookmarkData: Data?
    var originalFileName: String
    var fileSize: Int64?
    var addedAt: Date
    var missing: Bool
}
```

### Tag

```swift
struct Tag: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var colorHex: String?
}
```

### Collection

```swift
struct Collection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var createdAt: Date
}
```

### PaperAnnotation

```swift
struct PaperAnnotation: Identifiable, Codable, Hashable {
    var id: UUID
    var paperID: UUID
    var type: AnnotationType
    var pageIndex: Int
    var pageLabel: String?
    var text: String?
    var comment: String?
    var colorHex: String?
    var bounds: CGRectCodable?
    var imageFileURL: URL?
    var createdAt: Date?
}
```

---

## 四、主界面设计

请实现一个三栏式 macOS 主窗口：

```text
┌──────────────────┬──────────────────────────────┬──────────────────────────────┐
│ Sidebar          │ Paper Table                   │ Inspector                    │
│                  │                              │                              │
│ Library          │ Title | Authors | Year | ... │ Metadata / Annotations       │
│ Collections      │                              │                              │
│ Tags             │                              │                              │
│ Smart Views      │                              │                              │
└──────────────────┴──────────────────────────────┴──────────────────────────────┘
```

### 左侧 Sidebar

包含：

- Library
  - All Papers
  - Recently Added
  - Recently Opened
- Smart Views
  - Unfiled
  - Missing DOI
  - Missing Attachment
  - No Tags
- Collections
  - 支持新建、重命名、删除
  - 支持拖拽论文加入 Collection
- Tags
  - 支持新建、重命名、删除
  - 支持颜色
  - 支持拖拽论文加 Tag

### 中间 Paper Table

使用 SwiftUI Table 或 AppKit NSTableView bridge，要求具有 macOS 原生体验。

列包括：

- Title
- Authors
- Year
- Source
- DOI
- Rating
- Tags
- Added Date

功能：

- 搜索标题、作者、期刊、会议、DOI、年份
- 排序
- 多选
- 右键菜单
- 拖入 PDF 导入
- 拖拽到 Collection / Tag
- Enter 打开 PDF
- Space 触发 Quick Look
- Delete 删除文献记录，但不要默认删除 PDF 文件
- Command + O 导入 PDF
- Command + F 聚焦搜索
- Command + E 导出

### 右侧 Inspector

使用 TabView：

1. Metadata
2. Annotations

Metadata 面板可查看和编辑：

- Title
- Authors
- Year
- Source
- DOI
- arXiv ID
- Abstract
- Volume / Issue / Pages
- Cite Key
- Rating
- Notes
- Collections
- Tags
- PDF file path
- Buttons:
  - Open PDF
  - Reveal in Finder
  - Replace PDF
  - Refresh Metadata
  - Extract Annotations

Annotations 面板显示：

- 标注类型
- 页码
- 高亮文本
- 批注内容
- 颜色
- 图形标注截图，如果有
- 支持复制单条标注
- 支持导出所有标注

---

## 五、导入功能

### 1. PDF 导入

支持：

- 文件选择器选择一个或多个 PDF
- 从 Finder 拖入一个或多个 PDF
- 递归扫描文件夹中的 PDF
- 导入时不强制复制 PDF
- 保存 security-scoped bookmark
- 自动提取 PDF 基础信息

导入流程：

1. 用户选择 PDF。
2. 应用保存 PDF 的 bookmark data。
3. 使用 PDFKit 读取 PDF 前几页。
4. 尝试提取：
   - title
   - authors
   - DOI
   - arXiv ID
   - year
5. 如果找到 DOI，则调用 Crossref API 补全元数据。
6. 如果找到 arXiv ID，则调用 arXiv API 补全元数据。
7. 如果没有 DOI / arXiv，则保留从 PDF 猜测的信息，并标记为 Missing DOI。
8. 检查重复项：
   - DOI 相同视为重复；
   - arXiv ID 相同视为重复；
   - 标题高度相似视为可能重复。
9. 重复时弹出冲突处理：
   - Skip
   - Replace Metadata
   - Keep Both

### 2. DOI 导入

提供一个输入框：

- 用户输入 DOI
- 调用 Crossref API 获取元数据
- 创建 Paper 记录
- 此时可以没有 PDF，归入 Missing Attachment

### 3. BibTeX 导入

支持导入 `.bib` 文件。

要求：

- 解析常见 BibTeX 类型：
  - article
  - inproceedings
  - book
  - misc
  - unpublished
  - preprint
- 解析字段：
  - title
  - author
  - year
  - journal
  - booktitle
  - doi
  - arxiv
  - eprint
  - abstract
  - volume
  - number
  - pages
- 自动生成 Paper 记录
- 保留 citeKey
- 支持重复冲突处理

---

## 六、元数据提取与补全

请实现 `MetadataLookupService`，支持多来源补全。

优先级：

1. DOI 精确查询 Crossref
2. arXiv ID 查询 arXiv API
3. PDF 内嵌 metadata
4. PDF 前几页文本启发式解析
5. 用户手动编辑

需要实现：

- DOI 正则提取
- arXiv ID 正则提取
- PDF 前 3 页文本提取
- Crossref 查询
- arXiv 查询
- 元数据合并策略

合并策略：

- 用户手动编辑过的字段优先级最高，不应被自动覆盖。
- DOI / arXiv ID 精确查询结果优先级高于 PDF 猜测。
- 自动补全前尽量显示预览或允许撤销。
- 批量刷新元数据时要有进度显示。

---

## 七、PDF 标注提取

使用 PDFKit 实现 AnnotationExtractor。

需要支持：

- Highlight
- Underline
- StrikeOut
- Text
- FreeText
- Square
- Circle

每条标注提取：

- type
- page index
- page label
- selected text if available
- comment / contents
- color
- bounds
- created date if available

对于 Square / Circle 等图形标注：

- 根据 annotation bounds 从对应 PDF page 渲染局部截图
- 保存到应用支持目录中的 annotation images 文件夹
- 导出 TextBundle 时将图片一起打包

注意：

- 不要修改原 PDF 文件。
- 提取标注只读。
- 如果 PDF 文件缺失，要在 UI 中提示 Missing Attachment。
- 提取失败时要有可读错误信息。

---

## 八、Quick Look 与外部打开

实现：

1. Space 预览 PDF
   - 使用 QLPreviewPanel 或 QuickLookPreviewController bridge。
   - 选中文献有 PDF 时，按 Space 调用 Quick Look。
   - 无 PDF 时显示提示。

2. Enter 打开 PDF
   - 使用 NSWorkspace.shared.open(url)
   - 用系统默认 PDF 阅读器打开。

3. Reveal in Finder
   - 使用 NSWorkspace.shared.activateFileViewerSelecting([url])

4. Replace PDF
   - 允许用户重新选择 PDF。
   - 更新 bookmark data。
   - 保留原文献元数据。

---

## 九、文件整理策略

实现设置项：

- Library Base Folder
- Import behavior:
  - Link only：只链接原始 PDF，不移动、不复制
  - Copy to library folder：复制到指定文献库文件夹
  - Move to library folder：移动到指定文献库文件夹

默认使用 **Link only**。

当用户选择 Copy / Move 时，支持自动整理目录结构。

可选命名模板：

```text
{year}/{source}/{citeKey}.pdf
{year}/{firstAuthor}_{shortTitle}.pdf
{collection}/{citeKey}.pdf
```

要求：

- 自动清理非法文件名字符。
- 重名时自动追加后缀。
- 永远不要静默覆盖用户文件。
- 移动或复制前弹出确认。
- 所有文件操作失败都要显示错误原因。

---

## 十、导出功能

### 1. Markdown 导出

支持模板化导出。

默认 Metadata Template：

```markdown
# {{title}}

> Authors: {{authors}}
> Year: {{year}}
> Source: {{source}}
> DOI: {{doi}}
> Cite Key: {{citeKey}}

## Abstract

{{abstract}}

## Notes

{{notes}}

## Annotations

{{annotations}}
```

模板语法：

- `{{variable}}`：变量替换
- `{{#field}}...{{/field}}`：条件块
- `{{#annotations}}...{{/annotations}}`：标注列表块

可用变量：

```text
title, authors, year, source, doi, arxivID, abstract, volume, issue, pages, citeKey, rating, notes, collections, tags, annotations
```

### 2. Annotation Template

默认：

```markdown
- Page {{page}} · {{type}}
  {{#text}}
  > {{text}}
  {{/text}}
  {{#comment}}
  Comment: {{comment}}
  {{/comment}}
  {{#image}}
  ![]({{image}})
  {{/image}}
```

### 3. TextBundle 导出

如果标注中包含图片，则导出 `.textbundle`：

```text
PaperTitle.textbundle/
  text.md
  assets/
    annotation-1.png
    annotation-2.png
```

### 4. BibTeX 导出

支持：

- 单篇导出
- 多选批量导出
- 全库导出
- 自定义 citeKey 模板

citeKey 模板示例：

```text
{auth}{year}
{Auth}{year}
{auth}:{shortyear}
{auth}{title}
```

导出字段：

- title
- author
- year
- journal / booktitle
- doi
- eprint / arxiv
- abstract
- volume
- number
- pages

---

## 十一、搜索与筛选

实现全局搜索：

- title
- authors
- source
- year
- DOI
- abstract
- notes
- tags
- collections

实现筛选：

- All Papers
- Collection
- Tag
- Missing DOI
- Missing Attachment
- No Tags
- Recently Added
- Recently Opened
- Rating

搜索应实时响应，并且不要阻塞 UI。

---

## 十二、设置页面

设置页包括：

### General

- Library Base Folder
- Import behavior
- Default PDF open behavior
- Confirm before moving files
- Automatically extract metadata after import
- Automatically extract annotations after opening PDF

### Templates

- Metadata template editor
- Annotation template editor
- Reset to default
- Preview rendered output

### BibTeX

- citeKey template
- export field options
- duplicate citeKey strategy

### Appearance

- Follow system appearance
- Compact / Comfortable row height
- Show / hide inspector by default

---

## 十三、错误处理

所有错误都必须有清晰提示，不能只在控制台打印。

需要处理：

- PDF 文件不存在
- 没有文件访问权限
- bookmark 失效
- Crossref 请求失败
- arXiv 请求失败
- BibTeX 解析失败
- PDFKit 读取失败
- 标注提取失败
- 导出路径不可写
- 文件移动 / 复制失败
- 重复导入冲突

错误提示应包含：

- 发生了什么
- 为什么可能发生
- 用户可以怎么处理

---

## 十四、性能要求

目标：

- 启动速度快。
- UI 操作不卡顿。
- PDF 扫描、元数据查询、标注提取必须异步执行。
- 批量导入时显示进度。
- 大量论文时列表仍然流畅。
- 尽量减少内存占用。
- 不要一次性把所有 PDF 全文加载进内存。

实现建议：

- 使用 async / await。
- 使用 TaskGroup 批量处理导入。
- 对 PDF 文本提取只读取前几页。
- 对 annotation images 按需生成。
- 搜索索引可以先用内存过滤，后续再优化。

---

## 十五、MVP 开发优先级

请按以下阶段开发，不要一开始就做所有功能。

### Phase 1：可运行基础版

目标：先做出一个能启动、能导入 PDF、能展示列表、能打开 PDF 的应用。

必须完成：

- SwiftUI macOS App 项目
- 三栏主界面
- Paper 数据模型
- 本地元数据持久化
- PDF 文件选择导入
- 保存 PDF bookmark
- Paper Table 显示
- Metadata Inspector 显示
- Open PDF
- Reveal in Finder
- Delete paper record
- 搜索标题 / 作者

验收标准：

- 用户可以导入几个本地 PDF。
- 关闭应用再打开，文献记录仍然存在。
- 点击文献能看到右侧详情。
- Enter 可以用默认 PDF 阅读器打开 PDF。
- 可以在 Finder 中定位 PDF。
- 删除记录不会删除 PDF 文件。

### Phase 2：元数据自动提取

必须完成：

- PDF 前几页文本提取
- DOI 正则识别
- arXiv ID 正则识别
- Crossref 元数据查询
- arXiv 元数据查询
- 自动填充 title / authors / year / source / abstract / DOI
- 手动编辑 Metadata
- Missing DOI 智能视图
- Missing Attachment 智能视图

验收标准：

- 拖入带 DOI 的论文 PDF 后，能自动补全主要信息。
- DOI 导入可以创建没有 PDF 的条目。
- 用户手动编辑的字段不会被自动覆盖。

### Phase 3：Collections / Tags

必须完成：

- Collection CRUD
- Tag CRUD
- Tag color
- 拖拽论文加入 Collection / Tag
- Sidebar 筛选
- No Tags / Unfiled 智能视图

验收标准：

- 用户可以像管理 Finder 文件夹一样管理论文分类。
- 一篇论文可以属于多个 Collection 和多个 Tag。

### Phase 4：标注提取

必须完成：

- PDFKit 标注读取
- Highlight / Underline / StrikeOut / Text / FreeText / Square / Circle
- 右侧 Annotations 面板
- 复制标注
- 图形标注截图

验收标准：

- 用户在外部 PDF 阅读器中做的高亮，回到 PaperManager 后可以提取并查看。
- 图形标注能生成局部截图。

### Phase 5：导出

必须完成：

- Markdown 导出
- 模板渲染
- BibTeX 导入
- BibTeX 导出
- TextBundle 导出
- 批量导出

验收标准：

- 用户可以将一篇论文导出为 Markdown 文献卡片。
- 包含图形标注时可以导出 TextBundle。
- 可以导出 BibTeX 给 LaTeX / Pandoc 使用。

### Phase 6：体验优化

必须完成：

- Quick Look Space 预览
- 右键菜单
- 快捷键
- 批量操作
- 文件整理策略
- 设置页面
- 模板编辑器
- 更好的空状态
- 更好的错误提示
- UI polish

---

## 十六、UI 风格要求

整体风格：

- 简洁
- 克制
- 原生
- 高级
- 不要像网页后台
- 不要像数据库管理软件
- 不要信息过载

设计参考：

- macOS Finder
- Apple Mail
- Preview
- Notes
- Xcode 侧边栏
- 原生 Settings
- 原生 Table / Inspector 体验

视觉要求：

- 使用系统字体。
- 使用系统颜色。
- 支持浅色 / 深色模式。
- 使用合理留白。
- 列表密度适中。
- Inspector 要像原生检查器，不要像表单堆砌。
- 空状态要有清晰引导。
- 不要使用花哨动画。
- 不要使用非原生按钮风格。

---

## 十七、代码质量要求

请遵守：

- MVVM 架构。
- Model、Service、ViewModel、View 分离。
- 不要把业务逻辑写进 View。
- 所有异步任务要避免阻塞主线程。
- 所有文件访问都要处理 security-scoped resource。
- 所有网络请求要有错误处理和超时。
- 所有用户可见字符串尽量集中管理，方便后续本地化。
- 每完成一个阶段，请保证项目可编译运行。
- 不要留下伪代码。
- 不要只写 UI 壳子，核心功能必须可用。

---

## 十八、请你现在开始执行

请从 Phase 1 开始开发。

具体要求：

1. 创建完整的 macOS SwiftUI 项目结构。
2. 实现最小可运行版本。
3. 使用真实 Swift 代码，不要伪代码。
4. 所有文件路径和类名要清晰。
5. 实现本地数据持久化。
6. 实现 PDF 导入、列表展示、详情查看、打开 PDF、Finder 定位。
7. 提供可编译的代码。
8. 每完成一个功能点，检查是否有编译错误。
9. 如果当前环境无法创建 Xcode 工程，请生成完整源码文件结构和所有 Swift 文件内容，让我可以复制到 Xcode 中运行。
10. 不要擅自改变产品理念：PDF 文件永远优先保留在用户自己的 Finder 文件夹中，PaperManager 只是轻量连接、整理和导出中枢。

最终目标是开发出一款真正符合 macOS 原生体验的轻量论文管理器，而不是一个套壳网页应用，也不是一个笨重数据库容器。