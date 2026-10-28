# 测试

常规测试使用独立临时文库和合成 fixture，不操作用户的 Lattice 或 Zotero 文库。可选的 UI fidelity 测试只读复制明确指定的文库，并验证原 JSON 的 SHA256 未变。

| 命令 | 范围 |
|---|---|
| `scripts/test.sh core` | 文献/引用、实际 TCP/API、归档、编辑、文集标签、文件库、Zotero、导入备份、语言模板、Intents、CLI/MCP/浏览器逻辑 |
| `scripts/test.sh ui` | 原生表格、App/WindowGroup 尺寸与面板、设置协调、添加表单、标注操作、检查器选区/hover 几何及直接编辑 |
| `scripts/test.sh all` | core + ui + ax + extended-ui，按顺序运行 |
| `scripts/test.sh ax` | 独立外部 AX 客户端、检查器崩溃回归和全表辅助功能压力测量 |
| `scripts/test.sh extended-ui` | 设置交互、欢迎页导入路由、15 种文献检查器字段矩阵 |
| `scripts/test.sh ui-fidelity /absolute/source-library.json` | 可选：真实文库副本上的原生视图多尺寸、面板与横向滚动几何检查；不纳入 `all` |

各 `scripts/test-*.sh` 可单独执行。连接器测试位于 `Tests/Connector/run.sh`，需要 Node.js 18+；自动查找 PATH、标准 NVM/Homebrew 目录，也可用 `PAPERMANAGER_NODE` 指定可执行文件。

共用工具链配置在 `scripts/lib/toolchain.sh`。默认选择有效 Xcode/CLT 和主机架构；可通过 `PAPERMANAGER_SDK`、`PAPERMANAGER_TEST_SDK` 指定 SDK。无需安装 REA/Ghidra 即可构建和运行重构测试。

结果日志保存在 `.build/test-results`。UI 组需要 macOS WindowServer 会话，AX 组还需要已有的辅助功能访问权限；脚本不会自动授予权限。几何测试、后台 AX 和真实屏幕操作是不同验证范围。

完整验收应使用 `all`，需要独占前台的图形会话和已有 AX 权限；失败会保留日志并以非零状态退出。`test-import-busy.sh` 仍是编译和暂存入口，必须另外通过 CUA/人工操作暂存的隔离 fixture 完成忙碌状态导入验证，不能将 compile-only 当作该流程通过。

核心回归还包含 RIS ISSN/ISBN 与 DOI 规范化、同批导入预览、查询缓存和 Unicode 等价搜索、附件删除/恢复及未知本地文库版本写入保护。查询规模基准可用 `scripts/test-library-query.sh --benchmark` 单独执行，区分首次构建索引与复用索引的耗时。

`test-rating-interactions.sh` 使用隔离文库和真实列表/检查器控件，验证两处评分 hover 不写盘、移出恢复、禁用和复用清理，以及双向即时同步与写盘失败回退；结果与控件截图写入 `.build/test-results/rating-interactions`。它会短暂激活自己的测试窗口，通过控件本地事件执行，不移动系统指针。可传 `--compile-only` 仅编译，该模式不代表交互验收通过。

`test-native-window-group.sh` 包含 32 个阶段，覆盖不同窗口尺寸、侧栏/检查器收放及选择变化。它需要独占前台，运行期间不要同时操作其他应用。可设置 `PAPERMANAGER_GEOMETRY_NEGATIVE_CONTROL=1` 在临时源副本移除尺寸修复作负控；负控应失败。

`test-native-table.sh` 包含选中背景覆盖回归：在真实溢出列表中首次绘制选中行，再横向滚动、扩大视口并回到左右边界，检查新露出区域的像素。它同时覆盖非强调色、未选中和关闭高亮的状态。可单独运行并保存 JSON / PNG：

```sh
PAPERMANAGER_TABLE_SELECTION_ONLY=1 \
PAPERMANAGER_TABLE_SELECTION_REPORT="$PWD/.build/test-results/row-selection/report.json" \
  scripts/test-native-table.sh
```

这项回归验证保留的选中背景是否覆盖完整行，不替代实际窗口滚动和面板动画的屏幕检查。

`test-ui-fidelity.sh` 使用指定文库的隔离副本，在 1539×918、1280×800 与 1080×680 的受控原生 host 中验证侧栏/检查器锚点、面板隐藏与快速切换、Attention 条目附件展开、横向滚动及恢复。1080pt 是小于正式应用 1200pt 最小宽度的额外压力场景。运行时不会请求激活测试应用；不要与其他原生 UI 测试并行运行。

```sh
scripts/test.sh ui-fidelity \
  "/absolute/read-only/source-library.json" \
  "$PWD/.build/ui-fidelity-20261024/native-host"
```

结果包括 12 张 `native-host-*.png`、`native-host-geometry.json` 和 `isolated-library.json`。原生侧栏、表格和检查器来自正式实现，外围 host 只重建三个工具栏按钮。PNG 使用 `cacheDisplay`，窗口处于非激活状态：系统选中背景、振动材质、工具栏合成及部分 SwiftUI 文字颜色无法代表真实窗口。JSON 几何结果可用于布局验证；精确颜色、像素和 hover 动画仍须在已安装应用中截图与操作检查。

CI 在主分支构建前运行 core 和项目成员检查，再使用完整 Xcode 构建 app/CLI，签名并产生安装包。测试通过不等于 Shortcuts 注册、Safari 发行或所有视觉操作已验收。

侧栏计数包含多文集共享祖先去重和子文集开关；服务回归还覆盖查询排序、API 重复配置及替换监听的生命周期。标题选区和 hover 几何测试已纳入 UI 组；它们不替代真人鼠标、跨屏或输入法验证。

### PDF 预览

`scripts/test-pdf-preview.sh`（包含在 core）使用合成三页 PDF，覆盖首尾页、越界、缺失文件及旧统计字段兼容读取。界面检查包括标题与作者全宽、预览位于文字区下方、长标题、无 PDF、缺失文件提示和原生翻页按钮；交互使用隔离文库。
