<p align="center">
  <img src="docs/images/app-icon.png" width="96" height="96" alt="PaperManager 应用图标" />
</p>

<h1 align="center">PaperManager</h1>

<p align="center">
  <strong>让文献、笔记与引用，各就其位。</strong><br />
  为 macOS 构建的原生文献管理器。
</p>

<p align="center">
  <a href="#quick-start">快速开始</a> ·
  <a href="#features">功能</a> ·
  <a href="#preview">界面预览</a> ·
  <a href="#development">开发</a> ·
  <a href="https://github.com/get1024/PaperManager/issues">反馈问题</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-18181B?logo=apple&logoColor=white" alt="macOS 14 及以上" />
  <img src="https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white" alt="原生 Swift 应用" />
  <img src="https://img.shields.io/badge/UI-AppKit%20%2B%20SwiftUI-2563EB" alt="AppKit 与 SwiftUI" />
</p>

[![演示文库：文集和标签、文献列表、元数据检查器](docs/images/library.png)](docs/images/library.png)

<p align="center"><sub>演示数据 · 基于当前源码生成的原生组件渲染</sub></p>

PaperManager 将收集、整理、检索与引用放进一个原生 macOS 工作空间。用文集和标签组织资料，在检查器中直接编辑元数据，再将所选文献导出到写作工具。

应用使用系统提供的 AppKit、SwiftUI、PDFKit 和 Quick Look，本地文库无需安装 Node.js 或 Python。在线元数据查询会访问 Crossref、arXiv 和 Open Library。

<a id="features"></a>
## 功能

| 从收集到写作 | 你可以做什么 |
|---|---|
| **收集文献** | 导入 PDF、BibTeX、RIS 或文件夹；使用 DOI、arXiv、ISBN 或标题查询；提交前预览并处理重复项。 |
| **整理资料** | 使用最多三级文集、彩色标签和评分组织文库；管理 PDF 与附件，按规则整理或重命名文件。 |
| **快速检索** | 搜索标题、作者、标识符、摘要、备注和自定义字段；排序、多选、调整列宽，独立收起两侧面板。 |
| **完善记录** | 编辑 15 种文献类型，维护引用键、自定义字段、摘要和备注；批量刷新元数据并查看进度。 |
| **阅读与引用** | 用系统或指定阅读器打开 PDF，也可 Quick Look 预览；提取 PDF 标注，导出 BibTeX、RIS 或模板化 Markdown。 |
| **迁移与连接** | 使用 `.papermanager` 可移植备份，导入 `.lattice` 或 Zotero 文库；通过可选本地 API、CLI 和 MCP 连接其他工具。 |

<a id="preview"></a>
## 界面预览

<table>
  <tr>
    <td width="50%" align="center"><a href="docs/images/import-preview.png"><img src="docs/images/import-preview.png" alt="BibTeX 导入预览：逐项选择并确认文献" /></a></td>
    <td width="50%" align="center"><a href="docs/images/templates.png"><img src="docs/images/templates.png" alt="元数据模板：自定义导出内容并实时预览" /></a></td>
  </tr>
  <tr>
    <td align="center"><strong>确认后再导入</strong><br />先检查元数据与重复项，再决定保留哪些记录。</td>
    <td align="center"><strong>按写作习惯导出</strong><br />自定义元数据模板，让引用与笔记保持一致。</td>
  </tr>
</table>

图中使用独立演示文库；图片由当前生产组件渲染。生成方式与来源记录见[图片说明](docs/images/README.md)。

<a id="quick-start"></a>
## 快速开始

**运行要求：macOS 14 或更新版本。** 从源码构建需要可用的 Xcode 或 Command Line Tools，以及与源码 API 匹配的 macOS SDK。

```sh
git clone https://github.com/get1024/PaperManager.git
cd PaperManager
scripts/build-app.sh
scripts/install-app.sh
```

随后从 `~/Applications/PaperManager.app` 启动，或双击仓库中的 **Launch PaperManager.command**。

- 构建产物位于 `dist/PaperManager.app`。默认安装后，该路径成为指向正式应用的链接。
- 正式构建使用 `-Osize` 全模块优化，匹配当前主机架构。
- 本地构建使用临时签名；当前没有提供经过公证的发行包。

<details>
<summary>开发运行、调试构建与自定义输出</summary>

```sh
# 直接启动仓库中的应用；尚未构建时自动构建
scripts/run-app.sh

# 带调试信息构建
PAPERMANAGER_BUILD_CONFIGURATION=debug scripts/build-app.sh

# 输出到指定目录
PAPERMANAGER_BUILD_DIR=/tmp/PaperManagerBuild scripts/build-app.sh

# 仅验证 SwiftPM 可执行产品；此命令不生成 .app
scripts/build-swiftpm.sh -c release
```

更多工具链和路径配置见[开发说明](docs/DEVELOPMENT.md)。

</details>

## 数据与备份

文库以本地 JSON 保存。首次使用采用应用默认位置；选择其他文库后，启动时会沿用有效的偏好路径。PDF 可以保留原位，也可以按文件库设置复制或移动。

检查器中的元数据编辑在原子写盘成功后才发布成功状态；写入失败保留草稿。恢复和文件整理会检查并发变更；文件操作失败时尝试回滚，并报告未能完成的部分。迁移或批量整理前，建议先在设置中导出一份 `.papermanager` 备份。

个人文库、PDF、备份和凭据不进入源码仓库。路径规则见[数据与目录说明](docs/LOCAL_LAYOUT.md)。

## CLI、MCP 与浏览器

本地 API **默认关闭**。在「设置 → 集成」启用后，可以开启只读模式并调整端口。CLI **默认只读**；写操作还必须得到应用端允许。

```sh
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI status
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI search --query transformer
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI mcp
```

设置页支持导出 Agent Skill 和 MCP 配置。浏览器连接器提供可手动载入的 MV3 源码包，支持页面元数据预览和可选 PDF 上传。

[集成文档](docs/INTEGRATIONS.md) · [浏览器连接器](BrowserExtension/README.md)

<a id="development"></a>
## 开发

```sh
scripts/test.sh core      # 数据、导入导出、持久化、API、CLI / MCP
scripts/test.sh ui        # 原生布局、表单、选区与编辑
scripts/test.sh ax        # 跨进程辅助功能
scripts/clean.sh          # 清理中间产物，保留最新测试日志
```

UI 测试需要 macOS 图形会话；AX 测试还需已有的辅助功能权限。连接器测试使用 Node.js 18+，工程成员检查使用 Python；这些都是开发工具，不是应用运行依赖。

```text
Sources/
├── PaperManager/
│   ├── Models/       文献、组织关系与设置
│   ├── Services/     查询、持久化、导入导出与集成
│   ├── Views/        原生界面与窗口协调
│   └── Intents/      App Intents
└── PaperManagerCLI/  CLI 与 stdio MCP
Tests/               隔离文库、原生 UI 与连接器回归
scripts/             构建、启动、测试与维护入口
```

重构按小批次进行：先记录现有行为与副作用，再调整职责，最后比较结果并复审。公共入口、配置默认值、文件格式和用户可见行为都属于兼容性范围。

[开发说明](docs/DEVELOPMENT.md) · [测试说明](docs/TESTING.md) · [重构约定与本轮验证](docs/REFACTORING.md)

## 当前状态

核心文献管理、导入导出、备份和本地集成已经实现。浏览器连接器仍以源码包交付；Safari 签名发行和 Shortcuts 系统注册尚未完成验证。

本项目参考 Lattice 3.0 的发布包与实际行为独立实现。界面仍有少数字形、材质和未测状态差异；具体测试覆盖见[验证记录](docs/CLEANUP.md)。

新的图标方向、设计研究与原始素材见[图标设计探索](docs/design/icon-exploration/README.md)。当前应用仍使用现有图标。

---

README 的结构与图文呈现参考了 [IINA](https://github.com/iina/iina)、[Stats](https://github.com/exelban/stats) 和 [Ice](https://github.com/jordanbaird/Ice)。本页界面图片均由 PaperManager 自身组件生成。
