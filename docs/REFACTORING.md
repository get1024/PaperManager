# 行为保持的代码整理

本轮按[分享对话](https://chatgpt.com/s/t_6adb7eb000c88191bd3f554bec0f11ab)中的方法组织：记录当前行为，按职责分批修改，比较可观察结果，再由另一名审查者检查遗漏。

## 本轮基线与兼容性

起点是已完成原生界面拆分与查询整理的本地 `.32` 工作树，含此前未提交改动。它们不因本轮整理而重置。此前完整验证结果保存在 [清理记录](CLEANUP.md)，本轮只重跑与构建入口有关的必要检查。

保持以下内容不变：

- App 与 CLI 的 Release/Debug 编译参数、签名与严格校验。
- 安装时的暂存、完整替换、失败回滚，以及构建 stdout 仅输出产物路径的约定。
- 显式文库环境变量、有效偏好、旧本地文库、应用默认路径的启动优先级。
- 根启动器和旧 `scripts/run-reconstruction.command` 路径继续可执行。
- CLI 帮助、版本、使用错误、MCP 配置与导出 Skill 的内容和退出码。
- App 的本地 API 默认关闭、CLI 默认只读；不为修正文档而改变设置默认值。

## 小批次整理

| 批次 | 结构变化 | 验证方式 |
|---|---|---|
| CLI 构建 | `build-app.sh` 调用 `build-cli.sh`，编译、签名与验签只有一个维护入口 | 自定义输出目录真实 app 构建；签名、资源及 CLI 差分 |
| 启动入口 | 新增 `run-app.sh` 作为当前入口；旧路径保留 `exec` 包装 | 原启动逻辑逐字比较；语法与执行权限检查 |
| 项目首页 | README 按定位、界面、功能、快速开始和开发分层；修正文档中的 API 默认策略 | 本地链接与图片检查；浏览器渲染检查 |
| 图片工具 | 直接使用生产原生组件和隔离演示数据渲染 | 图片尺寸、不透明度与人工视觉检查；保存来源清单 |

## 比较规则

CLI 的 `--help`、`--version` 和未知命令比较退出码、stdout、stderr。MCP 配置和 Skill 导出包含实际可执行路径，比较前仅将各自的该路径替换为同一个标记；其他内容不归一化、不放宽差异。

原文库只记录并复核 SHA256，不用于演示图，不执行测试写入。图片工具使用独立文库与偏好域，所有演示记录均为合成示例。既有像素差异不在此次构建整理中修复。

## 验证记录

本轮实际结果保存在 `.build/test-results/readme/`。图片的生成方式、演示数据和源码指纹保存在 [manifest.json](images/manifest.json)。

| 命令或检查 | 实际结果 |
|---|---|
| `PAPERMANAGER_BUILD_DIR=/tmp/papermanager-readme-validation scripts/build-app.sh` | 成功；app 与内嵌 CLI 严格签名通过，Info.plist、语言资源和隐私清单与当前安装版一致 |
| 旧安装 CLI 与新 helper 的相同输入比较 | 7 组通过；退出码、stdout/stderr 保持一致，仅对已核实的实际可执行路径做归一化 |
| `Tests/Connector/run.sh` | 12 passed，0 failed；实际 loopback TCP、CLI、MCP 与浏览器核心模块 |
| 启动逻辑逐字比较、脚本语法及可执行位 | 通过；旧入口保留兼容包装 |
| `scripts/render-readme-images.sh` | 3 张图生成成功；全部像素 alpha=255，尺寸和生产源/生成器/图片指纹一致；完成目视核对 |
| 本地 GitHub 风格 Markdown 预览 | 首页、图册与页内跳转检查通过；本地图片和文档链接有效 |
| Xcode 成员与 `git diff --check` | 通过；本轮没有新增或修改 app 生产 Swift 文件 |
| 正式文库 SHA256 | 与本轮开始时相同 |

本轮没有重新运行全部 core/UI/AX，也没有进行新的完整 Xcode 构建、像素回归、浏览器扩展安装或 Shortcuts 注册验证。此前完整回归的范围仍以历史记录为准。
