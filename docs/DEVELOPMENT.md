# 开发说明

## 目录

| 路径 | 内容 |
|---|---|
| `Sources/PaperManager/Models` | 文献、附件、组织关系、设置和备份模型 |
| `Sources/PaperManager/Services` | 文库持久化、导入导出、文件库、备份、Zotero、本地 API、元数据与本地化 |
| `Sources/PaperManager/Views` | 原生 split/outline/table、SwiftUI 检查器、设置和导入界面 |
| `Sources/PaperManager/Intents` | App Intents 文献和模板实体及导出操作 |
| `Sources/PaperManager/Resources` | 图标、隐私清单、中文/英文资源 |
| `Sources/PaperManagerCLI` | 独立 Swift CLI 与 stdio MCP，只有四个生产源文件 |
| `BrowserExtension` | 可手动载入的 MV3 连接器源码 |
| `Tests` | Swift 回归、外部 AX 客户端；`Connector` 为 Swift/Node.js 端到端测试 |
| `scripts` | 构建、测试和迁移入口；`lib` 为共用工具链配置，`tools` 为迁移与文档预览工具 Swift 入口 |
| `App`、`PaperManager.xcodeproj` | 应用 Info.plist 与原生 Xcode app/CLI target |
| `dist`、`LocalData`、`.build` | 忽略的应用产物、个人文库、缓存与测试结果 |

## 构建

`scripts/build-app.sh` 编译 app，并调用 `scripts/build-cli.sh` 构建独立 CLI，将 helper、双语资源、隐私清单、图标和浏览器源码打包到 `dist/PaperManager.app`，依次签名 CLI 和 app，并做严格验证。默认匹配当前主机架构，最低系统 macOS 14。app 与 CLI 共用 `scripts/lib/build-configuration.sh`，正式构建使用 `-Osize -whole-module-optimization`；调试时设 `PAPERMANAGER_BUILD_CONFIGURATION=debug`。Xcode Release 同样使用体积优化与 dead-code stripping。

`scripts/build-swiftpm.sh` 编译两个可执行产品，输出到 `.build/swiftpm-native`。本机 Swift 6.4 使用 native SwiftPM engine 兼容 CLT；该路径不生成 `.app`，不等于 Xcode 构建。

Xcode scheme 为 `PaperManager`，应用依赖 `PaperManagerCLI` target，并将产品复制、签名到 `Contents/Helpers`。`scripts/check-project-membership.py` 检查生产源成员、资源和依赖关系。新增或移动生产源时同步维护工程；Tests 不加入 app target。

## 职责边界

- `NativeLibraryView.swift`：SwiftUI 与原生分栏协调；`NativeLibrarySidebar.swift`：侧栏组织；`NativeLibraryTable.swift`：文献列表与选择命令。
- `NativeLibraryCells.swift`：共享原生 cell/outline；`NativeLibraryToolbar.swift`：工具栏路由；`NativeLibraryGeometryLog.swift`：按需开启的几何诊断。
- `LibraryQuery.swift`：纯数据查询、排序和侧栏计数；`LibraryStore`：事务、持久化和操作协调。计数不调用排序，文集祖先在一次查询中复用。
- 菜单通过 `FocusedSceneValue` 发送到活动窗口；欢迎页定向导入保留单独路由。

## 实现约定

- 文库以 JSON 持久化，使用 durable mutation 先原子写盘再发布内存状态。
- 检查器通过草稿会话合并最新字段；关闭窗口、备份、恢复、退出前尝试保存。写失败不能假装成功。
- 原生 split controller 管理面板尺寸。内嵌 NSHostingController 的 `sizingOptions = []` 防止空内容最大高度约束压缩整个分栏。
- FocusedScene 路由菜单到活动窗口；无修饰 Return/Space/Delete 由原生列表处理，避免截获文本编辑。
- 本地 API 只监听 loopback；CLI 和服务端各自执行写入策略。
- 用户文献、文件和原始逆向抓取不进入仓库。报告说明原版证据、推断和实际验证的各自边界。

## 迁移工具

```sh
scripts/lattice-archive.sh --help
scripts/import-lattice-library.sh --help
```

工具编译产物位于 `.build/helpers`。恢复前使用独立目标和明确的 PDF 复制目录；完整备份也可在应用设置中恢复。工具不依赖项目外的原始逆向资料。

## 清理

`scripts/clean.sh` 删除可重建缓存和中间产物并保留测试日志。历史截图、调查工具和源码快照移至项目外归档，路径见 [本地布局](LOCAL_LAYOUT.md)。

## 启动与文档图片

`scripts/run-app.sh` 是当前仓库启动入口；根目录双击脚本调用它。旧 `scripts/run-reconstruction.command` 保留兼容包装，文库选择逻辑未变。行为保持约定见 [重构说明](REFACTORING.md)。

`scripts/render-readme-images.sh` 从当前原生组件生成 README 演示图片，使用临时偏好域和合成文库；不读取用户数据。图片来源与限制见 [图片说明](images/README.md)。
