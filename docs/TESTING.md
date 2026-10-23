# 测试

所有测试使用独立临时文库和合成 fixture，不操作用户的 Lattice 或 Zotero 文库。

| 命令 | 范围 |
|---|---|
| `scripts/test.sh core` | 文献/引用、实际 TCP/API、归档、编辑、文集标签、文件库、Zotero、导入备份、语言模板、Intents、CLI/MCP/浏览器逻辑 |
| `scripts/test.sh ui` | 原生表格、App/WindowGroup 尺寸与面板、设置协调、添加表单、标注操作、检查器选区/hover 几何及直接编辑 |
| `scripts/test.sh all` | core + ui |
| `scripts/test.sh ax` | 独立外部 AX 客户端、检查器崩溃回归和全表辅助功能压力测量 |

各 `scripts/test-*.sh` 可单独执行。连接器测试位于 `Tests/Connector/run.sh`，需要 Node.js 18+；自动查找 PATH、标准 NVM/Homebrew 目录，也可用 `PAPERMANAGER_NODE` 指定可执行文件。

共用工具链配置在 `scripts/lib/toolchain.sh`。默认选择有效 Xcode/CLT 和主机架构；可通过 `PAPERMANAGER_SDK`、`PAPERMANAGER_TEST_SDK` 指定 SDK。无需安装 REA/Ghidra 即可构建和运行重构测试。

结果日志保存在 `.build/test-results`。UI 组需要 macOS WindowServer 会话，AX 组还需要已有的辅助功能访问权限；脚本不会自动授予权限。几何测试、后台 AX 和真实屏幕操作是不同验证范围。

`test-native-window-group.sh` 包含 32 个阶段，覆盖不同窗口尺寸、侧栏/检查器收放及选择变化。它需要独占前台，运行期间不要同时操作其他应用。可设置 `PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL=1` 在临时源副本移除尺寸修复作负控；负控应失败。

`test-native-table.sh` 包含选中背景覆盖回归：在真实溢出列表中首次绘制选中行，再横向滚动、扩大视口并回到左右边界，检查新露出区域的像素。它同时覆盖非强调色、未选中和关闭高亮的状态。可单独运行并保存 JSON / PNG：

```sh
PAPERMANAGER_TABLE_SELECTION_ONLY=1 \
PAPERMANAGER_TABLE_SELECTION_REPORT="$PWD/.build/test-results/row-selection/report.json" \
  scripts/test-native-table.sh
```

这项回归验证保留的选中背景是否覆盖完整行，不替代实际窗口滚动和面板动画的屏幕检查。

CI 在主分支构建前运行 core 和项目成员检查，再使用完整 Xcode 构建 app/CLI，签名并产生安装包。测试通过不等于 Shortcuts 注册、Safari 发行或所有视觉操作已验收。

侧栏计数包含多文集共享祖先去重和子文集开关；服务回归还覆盖查询排序、API 重复配置及替换监听的生命周期。标题选区和 hover 几何测试已纳入 UI 组；它们不替代真人鼠标、跨屏或输入法验证。
