# 本轮交付与验收

2026-10-18，Asia/Shanghai。对象为安装版 Lattice 3.0 (26) 与独立原生 Swift 重构 PaperManager。

## 可运行交付

- 应用：`dist/PaperManager.app`。
- 独立文库启动：`scripts/run-reconstruction.command`。使用 `LocalData/Library/library.json`，不替换原版 Lattice 或已有 PaperManager 文库。
- 已迁移 72 篇文献、5 个文集、32 个标签、2 条标注、1 个模板和全部 72 个独立 PDF 副本。
- 完整可移植备份：`LocalData/Backups/PaperManager-72-paper-library.papermanager`。实际恢复到新目录后，数量、关系和全部 PDF 可读性通过验证；原版未修改。
- 最终本机 CLT 构建、SwiftPM app/CLI 构建、应用与 Helpers CLI 的严格签名验证通过。完整 Xcode 构建随后由 GitHub Actions 验证通过，见下方 CI 记录；未提供公证发行。

## 大片空白的修复与证据

根因是空检查器的 `NSHostingView.maxHeight <= 175` 约束通过原生分栏的共同上下边缘压缩三栏。`inspector.sizingOptions = []` 让 `NSSplitViewController` 管理面板尺寸。设置页的 detail hosting 使用同样处理。保留原生控制器层级，删除试验性的直接拆分、手动 frame、late pin 和补偿布局。

- 真正 SwiftUI `App/WindowGroup` 测试 9 阶段通过：三种窗口尺寸、面板收放、选中及取消选择；初始三栏 808pt，缩放后 680/948pt。
- 同源单行负控：仅在临时源副本删除 `sizingOptions = []`，9 阶段中 6 阶段重新出现 175pt，证明测试能捕获原问题。
- 设置窗口的五个面板均铺满内容高度，5 阶段通过。
- 最终打包应用 `PaperManagerReady` 的运行几何也为三栏 808pt。用户实屏确认：**“PaperManagerReady 布局正常”**。
- 工具栏 AX 树确认仅有「面板、添加、导出」三个控件，面板菜单独立控制侧栏和检查器。

几何报告在 `.build/qa-2026-10-18/window-group-fixture/`、`window-group-fixture-negative/` 和 `settings-window-fixture/`。详细调查见 `NATIVE_TABLE_PERFORMANCE.md`。

## 崩溃、性能与数据验证

- 检查器：移除可选择引用键文字上导致 SwiftUI/AppKit 标签递归的自定义 AX label，保留文字选择和原生可访问值。空选择到选中，再连续三次外部 AX 读取通过；恢复旧 label 的临时负控可复现崩溃。见 `INSPECTOR_AX_CRASH_FINDINGS.md`。
- 表格：复用原生 cell，以一个原生星级控件代替每行五个按钮；去除装饰 AX 子层，缓存相同内容/样式。最终 1420×900 fixture 的全表外部 AX 扫描 11.892 秒，72×7 列及 72 个评分控件完整，包含屏外行。该压力扫描耗时不等于日常点击延迟。见 `NATIVE_TABLE_AX_PERFORMANCE.md`。
- 行为回归：文献/引用 12、真实 TCP/API 14、Lattice 归档 14、编辑 9、组织 7、文件库 11、Zotero 14、导入/备份 27、语言/模板 6、Intents direct perform 6、CLI/MCP/browser core 12，均通过。原生表格/生命周期/焦点路由为 8 组通过。
- 双语资源 509/509，键集合一致；最终 CLI Skill 导出保留当前端口和只读配置。Xcode 工程 33 个应用源、4 个 CLI 源、资源与 Helpers 依赖/复制检查通过。

最终构建/回归日志和源文件散列在 `.build/qa-2026-10-18/`。其中个人文库、PDF、原备份与大体积运行产物均不纳入 Git。

## 尚未完成的验收与差异

本轮已通过官方 `rea-agents setup` 接入 REA Skill/MCP，并使用项目私有 Ghidra 完成实际 arm64 函数分析。发布包、运行观察和真实归档提供重建依据；没有把函数片段当作恢复全部原始 Swift 源码。

以下边界仍保留，不能称作原版全部行为已经逐项等价验收：

- **完整实屏操作回归未完成。** 在用户解锁并展开新版后，界面工具仍持续返回 ScreenCaptureKit `-3812`，截图与后续操作不可用。主窗口正常来自用户实屏确认和实际应用几何，不能外推为拖放、双窗口、语言截断、所有导入/设置 sheet 的视觉验收均通过。
- **Shortcuts 系统注册未验收。** CLT 不含 `appintentsmetadataprocessor`，直接调用 Intent 通过不代表系统发现/注册通过。
- **浏览器扩展未安装/授权，Safari 签名发行未验收。** 已交付 MV3 源包并完成提取与真实 API 联通测试。
- 部分原版内部算法仍未知，批量刷新调度/取消与原版完整行为有差异；没有接入原版 StoreKit 权益服务。具体范围见 `FEATURE_CONTRACT.md`。

最终状态：可运行原生重构、独立数据迁移和本次布局修复已交付；上述界面及平台边界仍需后续验证。

## 2026-10-18 仓库清理

最终应用统一为 `dist/PaperManager.app`；旧应用和原始资料可恢复归档至项目外，测试辅助程序已移出生产源码。共用工具链、统一测试入口及目录说明见 [开发说明](../../docs/DEVELOPMENT.md) 与 [本地目录说明](../../docs/LOCAL_LAYOUT.md)。本机数据未提交到远程仓库。

清理后的源码重新通过：十组核心服务回归、连接器 12 项、原生表格 8 组、WindowGroup 9 阶段、设置窗口 5 阶段，以及 app/CLI 打包、严格签名验证、SwiftPM 构建和 Xcode 工程成员检查。连接器最初因 Node 不在 PATH 未运行，补充标准 NVM/Homebrew 路径查找后已单独重跑通过。两个迁移工具的编译和 `--help` 入口通过。测试结果在当前 `.build/test-results/`，旧证据按本地归档映射保留。

## 远程 CI 验证

源码提交 `f03f4bc64658cc1f64bac5366bf0211279daac58` 已推送到 `main`。[GitHub Actions 39119693256](https://github.com/get1024/PaperManager/actions/runs/39119693256) 的两个 job 全部成功：

- Xcode 生产源/资源成员检查与全部核心回归。
- SwiftPM 编译、完整 Xcode Release app/CLI 构建、临时签名验证、DMG 打包与构建产物上传。

这补充了此前本机只有 CLT 时缺少的 Xcode 构建验证。Shortcuts 系统运行注册、Safari 签名发行及完整实屏操作边界仍保持上述说明。此后补充 CI 链接的提交仅修改文档，未改变已验证源码。
