# PaperManager

参考 Lattice 3.0 (26) 的发布包、实际行为和备份结构，独立实现的原生 macOS 文献管理器。使用 Swift、AppKit、SwiftUI、PDFKit 和 Quick Look，支持 macOS 14+。

## 构建与启动

```sh
scripts/build-app.sh
scripts/run-reconstruction.command
```

最终应用统一输出到 `dist/PaperManager.app`。也可以双击仓库根目录的 **Launch PaperManager.command**。

启动脚本优先使用已有的 `LocalData/Library/library.json`。本机迁移的 72 篇文献及 72 个 PDF 保存在这里，完整可移植备份在 `LocalData/Backups/`。这些是个人数据，不进入 Git。新检出没有此目录时，使用应用默认文库 `~/Library/Application Support/PaperManager/library.json`；直接双击 `.app` 也使用默认文库。可通过 `PAPERMANAGER_LIBRARY_PATH` 显式指定其他文库。

需要有效的 Xcode 或 Command Line Tools。脚本自动选择可用工具链；本机 CLT 使用已安装的 26.5 SDK。可设置 `PAPERMANAGER_SDK` 和 `PAPERMANAGER_BUILD_DIR` 覆盖。构建会做临时签名，未提供公证发行。

## 主要功能

- 原生三栏文库、文集和标签树；搜索、多选、排序、列调整、PDF/附件展开与 Quick Look。
- 「面板、添加、导出」三个工具栏控件，独立显示或隐藏侧栏和检查器；活动窗口快捷键。
- 15 种文献类型、引用键、固定字段、自定义字段、摘要、备注、评分、附件及 PDF 标注提取。
- PDF、BibTeX、RIS、文件夹与标识符导入；提交前逐项预览，重复时跳过、替换书目信息或打开已有文献。
- 最多三级文集、标签颜色与拖放组织；文件库复制、移动、整理及重命名，保护共享和只读来源。
- BibTeX/RIS/Markdown 导出、多套元数据模板，中文与 English 界面及帮助。
- `.papermanager` 可移植 ZIP 备份与校验，读取 `.lattice` version 1/schema 2，支持 Zotero SQLite/WAL 迁移。
- 原生 Swift CLI、MCP stdio、本地 API 和 MV3 浏览器连接器源码。

新增和编辑在原子写盘成功后才报告成功；失败草稿保留，退出时无法保存会阻止退出。备份、恢复和文件操作包含失败回滚与并发变更检查。

## CLI 与浏览器

在「设置 → 集成」启用本地 API 并匹配端口。客户端默认只读，写入还需要应用端允许。

```sh
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI status
dist/PaperManager.app/Contents/Helpers/PaperManagerCLI search --query transformer
```

集成页可导出包含当前端口的只读 Agent Skill/MCP 配置，并显示浏览器扩展源码。详见 [连接器说明](ReverseEngineering/2026-10-18/AGENT_CONNECTOR.md) 和 [浏览器说明](BrowserExtension/README.md)。

## 开发与验证

```sh
scripts/build-swiftpm.sh
scripts/test.sh core
scripts/test.sh ui
```

- [开发与目录结构](docs/DEVELOPMENT.md)
- [测试入口与环境](docs/TESTING.md)
- [清理、数据与本地归档](docs/LOCAL_LAYOUT.md)
- [逆向资料索引](ReverseEngineering/README.md)
- [本轮验收与已知边界](ReverseEngineering/2026-10-18/ACCEPTANCE.md)

## 当前验证边界

主窗口大片空白和检查器辅助功能递归崩溃已修复；真实 WindowGroup、设置窗口和外部 AX 回归通过，用户已确认实际窗口布局正常。完整实屏流程仍未逐项验收。

App Intents 的实体查询和直接执行已实现并测试；CLT 缺少系统元数据处理器，Shortcuts 系统注册尚未验证。浏览器连接器已测试逻辑和真实 API 联通，未安装到用户浏览器，未提供 Safari 签名包。批量刷新调度与原版仍有差异；没有接入原版 StoreKit 服务。

已通过官方 [REA](https://github.com/morluto/rea) 的 `rea-agents setup`、Skill/MCP 与项目私有 Ghidra 获取分析证据。应用是独立 Swift 实现，所分析函数不等于恢复全部原始源码。
