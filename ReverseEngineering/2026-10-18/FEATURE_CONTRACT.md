# Lattice 3.0 功能契约与 Swift 重构差距

2026-10-18，Asia/Shanghai。对象为用户指定的 `/Applications/Lattice.app`，版本 **3.0 (26)**，最低 macOS 14。此文档是对当前可读原版资源、2026-10-13 留存的 REA/原版运行证据，以及当前 `Sources/PaperManager` 的逐项比对；不把“源码含有实现”写成“已完成原版行为验收”。后续代码变更可按本表维护状态。

**阅读顺序：下方「Current 实施矩阵」是当前状态，共覆盖65个契约ID。其后的「最初审计快照」保留实施前的问题定位，不代表这些缺口仍未解决。** 当前源码已包含导入预览/BibTeX宏、完整字段与固定、文集标签组织、FocusedScene命令、FileLibrary、portable备份、Zotero、独立CLI/MCP/浏览器源包、双语帮助和原生表格性能修复。`currentUI = 待主任务最终验收`：本表不代填当前应用的截图、跨进程AX、实际拖放、双窗口及系统注册结果。

## 证据分层与边界

- **O-runtime**：此前真实原版 UI/API/归档的观察，保留其日期；本子任务没有重新操作 UI。
- **O-artifact**：直接读到已发布包中的文档、字段、接口声明或 AppIntents 元数据。它证明“包内有此声明/结构”，不能单独证明每条运行路径。
- **I**：从类型、调用入口或重构代码推导的行为，待运行验证。
- **U**：现有证据不能回答，必须保留为未知。
- 原始表状态 **有 / 部分 / 缺少 / 有意差异** 属于最初审计快照。Current表的「已实施」表示当前源码和所列回归覆盖；「部分/U」明确保留实现范围或原版证据未知，不等同原版全部行为已验收。

原版当前 `Info.plist` 已重新读取，版本仍为 3.0 (26)。`Help.strings` 有 318 条、`Localizable.strings` 有 614 条，与 2026-10-13 的语义 JSON 完全相同；文件 SHA-256 分别为 `b5b8411ceac94ed219b1b1795d41fb157e4d88bff53a4f026661a1bc850819d4`、`98a6e1a15183572ec9135f41fbbfe821db5c083bf9425ac099e061819a102fb5`。这不保证所有 Help 内容准确：**3.0 实际设置 UI 的四项导出开关优于 Help 中遗留的九项开关说明**。`RecoveredLattice` 中 2.4 (20) 的 schema、截图和文档仅作历史线索。

最初只读审计时，`LATTICE_CLI_READONLY=1 .../LatticeCLI status` 返回 exit 1：`Lattice isn't reachable at http://127.0.0.1:29467`。这个结果没有新增原版 API 运行通过结论；该只读审计未启动原版、改设置、读写 SwiftData、开关共享 REA session、复制原版 PDF 或修改原库。后续对子建服务的真实CLI/TCP回归，以及主任务原版UI观察，分别记录其对象和边界。个人文献内容不进入本文档。

## 可复用证据索引

| 编号 | 来源及能证明的范围 |
|---|---|
| E1 | `../2026-10-13/static/app-fingerprint.json`、`NATIVE_FINDINGS.md`、`classes-and-ivars.md`：原版身份、AppKit/SwiftUI/SwiftData/PDFKit 架构及部分运行时模型。当前 plist 再读确认版本。 |
| E2 | `../2026-10-13/static/zh-Hans.Help.json`、`zh-Hans.Localizable.json`：当前安装包全部 Help/中文字符串的格式化投影；今天确认语义未变。声明和错误文本不能代替执行。 |
| E3 | `/Applications/Lattice.app/Contents/Resources/lattice-cli/{SKILL.md,sidecar/*.md}`；相同内容留存在 `../2026-10-13/static/bundled-cli/`：官方 CLI 读写接口、限制和错误契约。 |
| E4 | `../2026-10-13/mcp/SETTINGS_SIDEBAR_METADATA_FINDINGS.md`、`settings-sidebar-metadata-evidence.json`：设置、侧栏、搜索、字段结构及原版 3.0 Citation UI 的实际观察。原生元数据 Evidence `ev_56af5f9b3a9cfe5c072b631d0e6303a69d39890f4e5ddca7173828adfda88677`，demangle `ev_f967e3919483fef4537b99552ca42da00bb8c9392a98ba3d9a2758cb5a3ce3d0`。 |
| E5 | `../2026-10-13/mcp/LATTICE_ARCHIVE_FINDINGS.md`、`lattice-archive-structure.json`：原版真实 version 1/schemaVersion 2 备份的格式和脱敏计数；REA 归档 Evidence `ev_b089e9dc55981f877a1826f2afcb34ba7bdb41750ad9778962164f851f196a32`。原始归档、个人元数据只在忽略目录。 |
| E6 | `../2026-10-13/static/{local-api-status,local-api-read-summary,paper-detail-shape,api-pagination-probes,collection-filter-probes}.json`：先前实际 API 读请求及覆盖边界；只对当时实例成立。 |
| E7 | `/Applications/Lattice.app/Contents/Resources/Metadata.appintents/extract.actionsdata`：已发布 JSON，明确 `ExportPaperMetadataIntent`、`PaperEntity`、`TemplateEntity`、`MetadataOutputMode`。精简无个人数据投影见本目录 `appintents-contract.json`。 |
| E8 | `/Applications/Lattice.app/Contents/PlugIns/Lattice Safari Extension Extension.appex/Contents/Resources/manifest.json`：实际 Safari MV3 扩展，version 3.0、activeTab/storage/scripting、loopback host permission 和按需其他站点授权。未激活或执行该扩展。 |
| E9 | `../2026-10-13/static/recovered-source-file-names.txt`：82 个原文件名线索，例如 ZoteroImportService、InspectorPinStore、FileLibrary、PDFReorganizationCoordinator、Onboarding；文件名只支持定位，不能证明算法。 |
| E10 | 本目录 `official-cli-wire-probe.json`：安装包原版 LatticeCLI 连接自建合成 loopback responder 的请求记录。观察到 `/search?q=...`、`/papers/by-citekey?key=`、UUID detail 和 include 变换；这不是对原版 Local API 服务的运行观察。一次 create 只向无存储的合成 responder 发送 JSON，未创建原版文献或访问原库。 |

下表 `Sources/...` 均相对于仓库根目录；为便于持续迭代，使用类型/方法名定位，避免后续编辑导致旧行号失真。

## Current 实施矩阵（2026-10-18收口源码）

表内依据为当前源码、已完成的冻结源码fixture及子任务验证文档，不把fixture当作原版动态证据。所有行的 **currentUI均待主任务最终验收**，无需逐行重复。

| ID | 当前实施与验证 | 当前范围 / 剩余边界 |
|---|---|---|
| UI01 | `NativeLibraryView` 原生三栏split/outline/hosting；工具栏单一面板菜单且移除系统重复sidebar toggle。 | 已实施；当前窗口尺寸、隐藏恢复与视觉待验。 |
| UI02 | 论文/附件父子行、展开恢复、独立附件选择及打开/预览/移除。 | 已实施；原版持久化activePDFAttachID内部策略U。 |
| UI03 | 七列排序、多选、调整宽序/隐藏/重置，AppKit `autosaveTableColumns`。 | 已实施；原版精确默认列序与跨重启体验待验。 |
| UI04 | 行菜单PDF/附件打开、Finder、刷新、导出/复制、删除、整理/重命名；检查器可添加附件。 | 已实施主体；添加附件的菜单位置与原版逐项对版待验。 |
| UI05 | ⌘I/⌘E/⌘F、⌃⌘S侧栏、⌥⌘I检查器；未修饰Return/Space/Delete由原生列表处理。 | 已实施，避免文字编辑时全局快捷键截获。 |
| UI06 | `FocusedSceneValue`/`PaperManagerWindowActions`替代全窗口通知广播，`WindowGroup`多窗口。 | 已实施；真实双窗口焦点路由待验。 |
| UI07 | UI按拼接字段substring搜索；公开API按词、忽略大小写/重音、限定公开字段。 | 已实施，明确为重构matcher策略；原版全部搜索算法U。 |
| UI08 | 全部/未归类/缺PDF/缺ID及计数，另有日期/标签/评分filter模型。 | 已实施；missingID接受eprint，原版当前3.0是否完全相同U。 |
| UI09 | 侧栏展开IDs与split/列AppKit autosave；非结构变化保留节点身份。 | 已实施；重启/跨窗口显示状态待验。 |
| OR01 | 多重归属、论文拖放、检查器编辑、导入与替换加入捕获的目标；已删目标安全回退。 | 已实施；ImportBackup与sidebar fixtures。 |
| OR02 | throwing `createCollection`校验父级/三级，包含后代筛选/计数、增删改。 | 已实施；sidebar 7/7。 |
| OR03 | 文集原生拖放排序/改父级/移根，整棵子树depth和cycle验证、sortOrder规范化。 | 已实施；sidebar 7/7。 |
| OR04 | 标签拖放排序、增删改、预设/自定义3或6位hex颜色。 | 已实施；sidebar 7/7。 |
| OR05 | 表格单个原生矢量星级control，鼠标/键盘/同星清零/AX slider增减；检查器保留逐星按钮。 | 表格已实施且native smoke 8组；检查器与原版AX整体等价尚未证明。 |
| OR06 | 侧栏状态/忙碌进度，导入Task可停止，文件放置开始前可取消。 | 部分：批量metadata刷新仍串行Task，无原版完整可取消调度/重排队系统。 |
| IM01 | PDF/BibTeX/RIS/文件夹多文件与原生拖放；prepare先读候选，PDF有效性检查。 | 已实施；ImportBackup fixtures。 |
| IM02 | `ImportPlan`/`ImportPreviewView`勾选、X/Y、取消/确认、逐项错误与停止导入；确认前不变更库/文件。 | 已实施；准备/取消与选择fixture，真实sheet交互待验。 |
| IM03 | skip/replace/openExisting/applyAll；commit重新检测本批次及跨窗口重复；替换保留本地备注/评分/附件/标注并合并归属。 | 已实施；27项ImportBackup含同UUID重放、目标被删和真实写失败。 |
| IM04 | braces/quotes/bare/parentheses、跳过comment/preamble、`@string`/月份宏及`#`拼接。 | 已实施；宏/拼接fixture，不声称恢复原版完整BibTeX解析器。 |
| IM05 | RIS continuation/类型导入与导出。 | 已实施；来源格式的字节级原版等价仍U。 |
| IM06 | DOI/arXiv/ISBN/title查找，结果进入同一导入预览及重复决策，再确认commit。 | 已实施；网络服务当前响应不由离线fixture证明。 |
| IM07 | PDF attributes/前三页DOI/arXiv/带checksum的ISBN-10/13提取。 | 已实施；无OCR，原版页数/识别优先级U。 |
| IM08 | PDF确认commit时可补全、导入后可提标注；单篇/批量刷新；API enrichment异步pending并保护期间编辑。 | 部分：UI PDF补全仍逐项await；Bib/RIS没有原版等价后台补全队列。 |
| IM09 | Crossref/arXiv/OpenLibrary三种metadata来源。 | 部分/U：OpenAlex/SemanticScholar/PMC的原版完整fallback次序未恢复。 |
| MD01 | Paper/Attachment/Collection/Tag/Annotation/MetadataTemplate六实体；模板按源五字段、额外来源保留raw sidecar。 | 已实施主体；原版所有内部FileLibrary/active附件属性不声称一比一。 |
| MD02 | 全15类型，独立inCollection；BibTeX thesis/preprint/incollection及Lattice chapter-container映射。 | 已实施；editing/ImportBackup全部类型fixture。 |
| MD03 | 活动检查器type-specific Standard/More/Other Filled/Custom，高级sheet、标准全局pin与每文献custom pin。 | 已实施；editing 9/9覆盖编辑生命周期/字段可达性。 |
| MD04 | DOI/ISBN/eprint独立编辑与清空；类型改变保留其他已有值。 | 已实施；独立标识符fixture。 |
| MD05 | volume/issue/bookTitle/institution/school/series/edition/chapter/venue/howPublished及其他字段有活动编辑入口。 | 已实施；各原版类型默认schema完全对版仍待观察。 |
| MD06 | `PaperDraftSession`同步binding+debounce+field merge；切换/消失/退出flush；落盘失败保留draft并阻止退出。 | 已实施；editing 9/9含真实写失败、跨选择与后续重试。 |
| MD07 | canonical格式/冲突后缀、相关编辑/格式变更更新；迁移源citekey保真。 | 已实施；中文作者/原版所有冲突排序策略仍U。 |
| MD08 | reader/bookmark、Finder、附件管理；替换新PDF提升为primary且保留原附件/只读授权。 | 已实施；附件与API fixture，实际外部阅读器交互待验。 |
| FL01 | 单根bookmark、notAsked/declined/configured/unavailable/legacyConflict与修复、更换/重置。 | 已实施；FileLibrary 11/11。 |
| FL02 | copy/move/none用于全部本地附件；browser/Zotero managedImport强制copy。 | 已实施；只读源不移动、不重命名。 |
| FL03 | none/year/authorInitial/sidebar首文集，无值Unsorted，两种PDF/Attachments或byPaper布局。 | 已实施；当前namespace为明确重构策略。 |
| FL04 | 自动规则与显式rename独立，缺必需变量保留原名，冲突编号，managed来源复用plan。 | 已实施；命名语法/所有原版细节仍U。 |
| FL05 | `organizeFiles`/`renameFiles`接菜单及设置Apply；共享/只读保护、exclusive IO、receipt rollback。 | 已实施；FileLibrary及ImportBackup覆盖失败/别名/字节保护。 |
| FL06 | 换根/布局只影响未来操作，无目录watcher；已有文件仅显式Apply/organize处理。 | 已实施。 |
| AN01 | PDFKit提取七类、page/label/text/notes/color/bounds，替换刷新；异步完成检查当前primary与annotation baseline。 | 已实施主体；未知kind仍按note处理，精确markup几何/文字算法U。 |
| AN02 | square/circle裁图，详细导出textbundle图片；portable备份图片roundtrip。 | 已实施；合成图片校验覆盖，原版shape样本像素级对照未做。 |
| AN03 | 检查器标注查看/刷新/导出。 | 部分：仍显示前80条；批注编辑与跳页原版行为U。 |
| EX01 | 选中项否则当前visible结果导出；All筛选可导出全库，剪贴板BibTeX/RIS；空结果不再回退全库。 | 已实施入口策略；没有独立scope picker。 |
| EX02 | 当前3.0四开关控制abstract/tag keywords/notes/customFields，其他非空字段始终导出。 | 已实施；不使用旧Help九开关。 |
| EX03 | .md或.textbundle详细导出、citekey/标题文件名、不覆盖编号；独立annotation模板。 | 已实施；ExportService/ImportBackup fixture。 |
| EX04 | 多MetadataTemplate CRUD/active/explicit、preview/reset，保留全局annotation模板；标准context key不被custom覆盖。 | 已实施；localization/templates 6/6、intents 6/6与标准key保护fixture。 |
| EX05 | 自家`papermanager://paper/UUID`，兼容模板别名bibtexKey/latticeURL/pdfURL。 | 有意差异：不抢注原版scheme；latticeURL变量返回自家链接。 |
| BK01 | `.papermanager` portable v2 ZIP携主PDF/附件/标注图，metadata-only与旧JSON兼容。 | 已实施独立格式；**不宣称写出原版.lattice**；27项含SHA/size/精确清单覆盖。 |
| BK02 | 自家v2/旧JSON完整restore与.lattice专用reader，后台prepare、预备份、draft flush、revision token防并发、durable commit和新目录清理。 | 已实施；原版.lattice未知secondary/图像布局及ZIP64仍不支持，明确拒绝/保留边界。 |
| BK03 | .lattice sourceIDs/key/date/rating/完整metadata/membership/样本标注及所有模板，raw未知sidecar。 | 已实施且限证据样本；14项归档+15类型/多模板fixture不等于任意原库全保真。 |
| BK04 | SQLite backup API读取活跃WAL，Zotero预览/幂等合并/notes/annotations/tags/collections，metadata-only、copy与外链opt-in、取消清理。 | 已实施；Zotero 14/14；未用真实用户库，墨迹/未知几何明确warning。 |
| API01 | loopback listener/Origin/port/readOnly/capabilities及真实FileLibrary状态。 | 已实施；13项TCP，不冒报plugin-hosting。 |
| API02 | `/search`10/50/recent、exact trimmed case-insensitive citekey解析，UUID detail与CSL提取。 | 已实施；官方安装CLI对自建server实际回归通过。 |
| API03 | include opt-in、collections/tags对象、pdfPath可读检查及typed CSL。 | 已实施；CSL不是provider不可见扩展原对象。 |
| API04 | 多hint lookup、作者string/array、UTF8/type/数量校验，missing collection仅warning，tags创建。 | 已实施；TrustedFolders/pdfPath原位授权未恢复，明确warning引导upload。 |
| API05 | skip/replace、alreadyExists/conflict/warnings/pdfAttached，后台pending enrichment基于最新记录填缺项。 | 已实施；原版不可达时未做写响应逐字对照。 |
| API06 | public与connector两PUT PDF路由、PDFKit/magic/MIME、200,000,000上限、force保护、保留旧只读源。 | 已实施；真实TCP+source字节保护fixture。 |
| API07 | 自家Swift CLI、stdio MCP、skill/config exporter、只读默认/双端写权限/JSON退出码；app Helpers内嵌签名。 | 已实施；connector 12/12；导出不等于安装/注册agent。 |
| BR01 | MV3 popup/提取/编辑预览/集合标签/duplicate与PDF force独立/optional upload，自家资源源包。 | 已实施源包与browser-core fixture；未安装扩展、未做popup交互/Safari签名。 |
| BR02 | browser/API/FileLibrary状态连通；未配置/declined/unavailable的metadata-only和legacyConflict写入保护。 | 已实施；真实浏览器授权流程待验，源包复制不等于安装。 |
| OS01 | AppIntent/PaperEntity/TemplateEntity动态查询，default clipboard/annotations=false/openAppWhenRun=false、两输出模式。 | 已实施；direct perform与queries 6/6，不代表Shortcuts系统注册。 |
| OS02 | AppShortcuts声明与当前模板/标注渲染，明确缺ID错误。 | 部分：CLT缺appintentsmetadataprocessor，真实Shortcuts/Siri/Spotlight注册和原版通知行为未验。 |
| ST01 | 原生Settings split五pane、reader/FileLibrary/citation/backup/多模板、系统/简中/English与509对等资源key。 | 已实施；系统菜单重开及原版精确布局待最终UI验收。 |
| ST02 | 独立Help scene原生split、搜索/主题/完整中英正文与键盘表，所有固定正文经PMLocalization。 | 已实施；不再有“英文帮助仅中文”提示；为重构功能独立撰写。 |
| ST03 | 三步welcome首启一次/可重开、双语What's New与Help菜单。 | 已实施；实际首启profile与窗口行为待验。 |
| ST04 | 独立重构未接原版StoreKit购买/恢复或商业权益服务。 | 有意差异；残留设置布尔值不代表真实Pro权益。 |

### Current 验证依据与集成状态

- `CORE_RECONSTRUCTION.md`：editing 9/9、sidebar 7/7、metadata intents 6/6；`NATIVE_TABLE_PERFORMANCE.md`：native AppKit性能/AX smoke 8组。差分更新和复用避免selection/status触发全量重建；单一星级AX slider覆盖键鼠和值变更。跨进程CUA/VoiceOver与可见窗口不由隐藏窗口smoke代替。
- `RECONSTRUCTION_AUDIT.md`：ImportBackup 27/27、Zotero 14/14、LatticeArchive 14/14，包含真实持久化失败、恢复并发revision、共享/只读文件保护、清单完整性和原库字节保留。`FILE_LIBRARY_FINDINGS.md`：FileLibrary 11/11。
- `API_COMPATIBILITY.md`：真实TCP 14/14，含安装版官方CLI只读调用自建server；`AGENT_CONNECTOR.md`：自家CLI/MCP/browser-core 12/12。原版本地API不可达的观察不外推为自家API不可用。
- `LOCALIZATION_TEMPLATES.md`：语言/模板6/6、完整Help双语，当前资源509/509、无重复且format占位符对应；不是把用户文本送去翻译。
- 已在独立目录完成冻结源码的CLT SDK26.5 SwiftPM **native engine** app/CLI构建、资源bundle检查；`.build/packaging-validation-20261018/PaperManager.app`完成app和`Contents/Helpers/PaperManagerCLI`签名、CLI help/version/config与资源检查。PBX语法、33个app Swift全覆盖及两语言资源检查通过。没有完整Xcode，**未声称Xcode build通过**；后续源码修复后的最终集成build与currentUI由主任务填写。
- 原生REA/Ghidra engine已配置，已留存第一条真实函数Evidence；见`NATIVE_ANALYSIS_PLAN.md`及`native/rename-pdf-action.function.json`。它只证明所分析函数的静态回调边界，不等于恢复完整Swift重命名算法。

## 最初审计快照：主窗口、浏览与组织

**以下原表保留实施前的定位与证据，状态应与上方Current矩阵交叉阅读，不能直接作为当前待办清单。**

| ID | 原版契约 / 证据类型 | 当前 Swift 实现与差距 | 状态 |
|---|---|---|---|
| UI01 | 三栏：原生侧栏、论文表格、详情检查器；原版采用 NSSplitViewController（E1 O-artifact；E2 文档）。 | `Views/NativeLibraryView.swift` 使用 NSSplitViewController、NSOutlineView，右栏 NSHostingController。需实际窗口尺寸/分隔位置/隐藏恢复验收。 | 有 |
| UI02 | 论文父行可展开 PDF/附件子行，原版实际列表是 NSOutlineView（E1 O-artifact）。 | `NativePaperNode.children` 和展开状态、附件打开/移除均有；原版 activePDFAttachID 等活动附件语义未等价实现。 | 部分 |
| UI03 | 标题、作者、年份、来源、评分、添加日期等列；可排序、选择多篇，列重排/隐藏/重置（E1 callbacks，E2 Reset Columns）。 | `NativePaperTableController` 七列及表头菜单、排序、多选；列宽/隐藏在重启后的持久化和原版默认列序需验收。 | 有 |
| UI04 | 开 PDF、空格 Quick Look、Finder、删除、复制引用、元数据刷新和多种导出（E1/E2）。 | `NativeLibraryView.rowMenu` 覆盖前述大部分；原版显式“整理文件”“重命名 PDF”“添加附件”行菜单缺少。 | 部分 |
| UI05 | 原版 ⌘I 导入、⌘E 导出、检查器切换等快捷键声明（E2）。 | `PaperManagerCommands` 导入目前是 ⌘O，未发现原版检查器快捷键；Enter/Space/Delete/⌘F/⌘E 有。应按原版当前菜单实测校正，避免只凭 Help 猜全部键值。 | 部分 |
| UI06 | 新窗口（E2），全局菜单只作用于活动窗口是 macOS 合理预期（I）。 | `WindowGroup` 有；命令使用全局 NotificationCenter，每个 ContentView 均订阅，存在所有窗口同时响应导入/删除的风险，需双窗口验收。 | 部分 |
| UI07 | 搜索：CLI 明确 title/author/source/citekey/year；UI 有原生搜索字段（E3、E1）。 | `LibraryStore.filteredPapers` 是拼接全文后的单个 lowercased substring，另外搜索摘要、备注、集合和自定义字段；UI/CLI 是否同算法 U。无 token、重音、排序一致性证据。 | 有意差异 / U |
| UI08 | 智能筛选：全部、未归类、缺少 PDF、缺少标识符，显示计数（E2）。 | 活动原生侧栏四项都有；`missingIDs` 以 `hasIdentifier` 接受 eprint，而 Help 声明无 DOI/ISBN，需受控样本确认当前 3.0 实际规则。 | 部分 |
| UI09 | 文集与标签分组展开状态持久化（E1/E4）。 | `NativeSidebarController` 存 expandedIDs；重启验收未由本次执行。 | 有 |
| OR01 | 文献可属于多个文集、多个标签，拖论文到目标分配，导入自动归属当前选中目标（E2；E6 关系读值）。 | Store.addPapers、导入 targetFilter、检查器多选归属均有；普通/替换/去重分支都需验收。 | 有 |
| OR02 | 文集新建/子文集/重命名/删除，最多三级；父文集默认含后代，可切换且计数一致（E2）。 | 增删改及 includeSubcollections 有；`addCollection` 尚不限制深度，且可构造无效 parent。 | 部分 |
| OR03 | 同级文集拖动排序、拖到另一个文集改父级，阻止环及超过三级（E2；E1 sortOrder/parent）。 | 原生侧栏只接收论文拖放，没有文集拖放。Store 无 reparent/reorder API。 | 缺少 |
| OR04 | 标签新建/重命名/改颜色/删除、自定义 hex 颜色、标签拖动排序（E2）。 | Store.updateTagColor 有，但活动原生侧栏菜单无改色；无标签重排。 | 部分 |
| OR05 | 1..5 星，重复点击当前星清零，辅助功能为可增减 slider（E2）。 | `NativeRatingCell` 和检查器星级支持点击清零；逐星 Button 是否等价 VoiceOver slider U，需要补聚合 AX 值/增减。 | 部分 |
| OR06 | 后台刷新/整理进度在侧栏底部，可取消（E2；E1 PaperRefreshCoordinator）。 | 状态文本和 isBusy 有；没有与原版相应的取消、队列、重新入队和 generation 管理。 | 部分 |

## 最初审计快照：导入、元数据与检查器

| ID | 原版契约 / 证据类型 | 当前 Swift 实现与差距 | 状态 |
|---|---|---|---|
| IM01 | 选择多个 PDF/BibTeX/RIS/整个文件夹；PDF/文件夹可拖入（E2 当前 Localizable）。 | `ImportService.expand` 和 ContentView 文件导入/Native drop 有。文件枚举顺序、权限跨异步、损坏 PDF 错误还需验收。 | 有 |
| IM02 | 导入前预览标题/作者/来源/年份，每项勾选、X/Y 计数、Escape 取消、Enter 导入（E2 Import panel）。 | `importURLs` 直接提取并逐项写 Store，缺少候选批次和预览 Sheet，不能在写入前取消或取消某条。 | 缺少 |
| IM03 | 重复检测后提供跳过/替换/打开已有、全部应用；替换同时增加当前文集/标签（E2，E3）。 | 普通 .bib/.ris 遇重复固定跳过，PDF/标识符通过 addOrReplace 默认返回已有；没有统一冲突对话框和批量选择。PDF 分支可能将新文件附到重复旧条目，应契约化。 | 部分 |
| IM04 | BibTeX braces/quotes/bare/parentheses、@comment/@preamble 跳过、@string 宏和 # 拼接（E2）。 | `BibTeXParser` 支持前述括号/转义大体结构；当前直接跳过 @string，cleanValue 把宏名/# 保留为字面量，宏解析缺少。 | 部分 |
| IM05 | RIS 导入、导出（E2 当前 Localizable）。 | `RISParser` 有标准分隔/continuation 和类型映射，ExportService.ris 有；跨系统来源 fixture 仍是重构验收而非原版输出逐字等价。 | 有 |
| IM06 | DOI 导入；官方机器接口还支持 arXiv、ISBN、title metadata lookup（E2/E3）。 | DOISheet/MetadataLookupClient 提供四种提示。但查到第一条标题候选立即创建，没有身份确认预览；原版 UI 候选决策 U。 | 有 / U |
| IM07 | 本地 PDF 自动提取 DOI/ISBN/元数据信号（E2；E9 PDFImportPreparationService）。 | `PDFMetadataExtractor` 读 PDF attributes、前三页 DOI/arXiv；**没有 ISBN 提取**，未发现 OCR；原版 ISBN 精确算法、页数、优先级 U。 | 部分 |
| IM08 | 导入后后台补全；单篇/批量刷新（E2）。 | PDF 导入在写入前 await enrich，逐文件串行；.bib/.ris 分支不排后台补全。点击刷新有；原版多来源 fallback、覆盖保护、服务次序 U。 | 部分 |
| IM09 | 多学术服务，包括 strings 出现 Crossref/OpenAlex/SemanticScholar/PMC（E1 字符串，仅 I）。 | 当前 Crossref、arXiv、OpenLibrary 三种，按给定 hint 单一路由。不能把新增 endpoint 当作已确认的原版优先级。 | 部分 / U |
| MD01 | Paper/Attachment/Collection/Tag/Annotation/MetadataTemplate 六种实体及扩展 BibTeX 字段（E1，E5 实际样本）。 | `LibraryModels` 大部分书目字段有；MetadataTemplate 实体简化为 AppSettings 两个字符串；File Library identity/placement、collection icon、active attachment 不完整。 | 部分 |
| MD02 | 类型选择，CLI 活跃类型含 article/book/inbook/**incollection**/inproceedings/proceedings/thesis/report/online/dataset/software/patent/manuscript/preprint/misc（E3）。 | `PaperType` 把 incollection 合并 inBook，fromBibTeX("thesis"/"preprint") 当前会掉到 misc，不能完整保留全部原版规范类型。 | 部分 |
| MD03 | 检查器能编辑所有字段；Standard/More/Other Filled/Custom 分组、按文献类型标准字段，固定和取消固定（E2，E4 InspectorPinStore）。 | 活动 metadataInspector 是固定布局；旧 `basicSection/sourceSection/advancedSection/customFieldsSection` 属性存在但未被 body 调用，不能算已实现。未显示的标准字段和自定义字段无活动编辑入口。 | 部分 |
| MD04 | 同时保留 DOI、ISBN、电子预印本；类型改变不应无声丢数据（E1/E5）。 | 活动 identifierBinding 将 DOI→eprint→ISBN 合为一个。修改为 ISBN/arXiv 未清原高优先级 DOI，新值被遮蔽；清空只有 ISBN 的文献会写空 DOI 而不清 ISBN。应改为独立字段。 | 部分，有可定位缺陷 |
| MD05 | 明确应可编辑的完整来源/书目字段（E1，E2 all fields）。 | 活动 Inspector 没有独立 volume、issue、bookTitle、institution、school、series、edition、chapter、venue、howPublished、customFields 编辑入口；More Fields 不等于这些数据已可编辑。 | 缺少入口 |
| MD06 | 摘要、备注、多文集/标签、评分、类型、附件显示（E2/E5）。 | 活动 Inspector 有；draft/baseline 字段合并减少并发编辑覆盖。450ms 保存 debounce 和退出/关闭窗口 flush 要检查；本次不宣称保存链已运行完成。 | 有 |
| MD07 | Canonical citekey：当前3.0 `{auth}{year}`，import 重新生成、相关 metadata/template 改变更新、冲突加 a/b/c（E4 O-runtime；E2）。 | CitekeyGenerator、Store 导入/编辑/template 触发有；迁移保留原始 keys 是重构的刻意数据保真策略。复杂中文作者/重名/稳定排序需验收。 | 有 |
| MD08 | 阅读器、自定义打开、Finder 和附件管理（E2）。 | 读者设置、bookmark/path、打开/显示/移除有。活动“替换 PDF”实际 attachFile 会追加另一 .pdf，primaryPDF 取 attachments.first；需修正文案或主附件替换语义。 | 部分 |

## 最初审计快照：PDF 文件库、标注、导出与备份

| ID | 原版契约 / 证据类型 | 当前 Swift 实现与差距 | 状态 |
|---|---|---|---|
| FL01 | 单一获授权 File Library，Not Asked/Declined/Configured/Unavailable/Legacy Conflict 流程；每 Mac 单独授权，修复失效 bookmark（E2；E1 3.0 新状态类型）。 | 当前路径字符串+Attachment bookmark；没有 File Library 状态机、单根约束、旧双根冲突解决或重新授权流程。 | 缺少 |
| FL02 | Local File Action = Do Nothing/Copy/Move，同时适用于本地 Primary PDF 和任意附件，不控制浏览器/Zotero/restore（E2）。 | `organizeAttachmentIfNeeded` 仅处理 isPDF，任意附件不整理；浏览器另设 root，偏离统一文件库。 | 部分 |
| FL03 | 分组 None/Year/authorInitial/first collection in sidebar order；无分组值→固定 Unsorted；File Layout 可分开放 PDF/Attachments 或按论文放一起（E2）。 | `PDFSubfolderGrouping` 四种有；无年份用 Unknown Year，无作者/文集可能落根，未按 sidebar sortOrder 选首文集；File Layout 未实现。 | 部分 |
| FL04 | Rename Rule 独立于 Organization Rule；缺必需变量保留原名；碰撞加编号；本地/browser/Zotero 共用（E2）。 | 仅导入copy/move流程 autoRename，未独立 rename 操作；未验证必需变量完整性；browser 固定 citekey，未共用规则。 | 部分 |
| FL05 | 手动 Organize Files 重应用规则/布局/适用文件动作；Rename PDF 独立动作；共享引用/并发变更应保护并回滚（E2 当前错误文本）。 | 行菜单/Store 缺少显式整理与重命名、共享引用保护和事务化文件操作。源迁移只读引用保护有。 | 缺少 |
| FL06 | 换根仅影响将来操作，不自动移动已有文件；往 root 放文件不自动导入（E2）。 | 设置改 root 未搬旧文件，也无watcher；未来改为状态机需保留此行为。 | 有 |
| AN01 | 从 PDF 提取 highlight/underline/strikeout/text/freetext/square/circle，page/label/text/notes/color；全量替换刷新（E2）。 | PDFMetadataExtractor 和 Store.updateAnnotations 有；当前未知 annotation kind 被当 note，需决定过滤策略；markup 四边形与 bbox 精确文本 U。 | 有 / U |
| AN02 | Square/circle 生成 PNG 图片，详细导出带图片（E2）。 | renderAnnotationImage 裁图和 textbundle 有；需给真实 shape fixture 作渲染验收，真实源样本只有2个highlight，不能据此宣称形状已对版。 | 有 / 未实测对版 |
| AN03 | Inspector 标注列表可查看/刷新/导出（E2）。 | 有，但 UI 仅前80条，重构自己的限制；没有证据原版如此。批注编辑、点击跳转具体页行为 U。 | 部分 |
| EX01 | BibTeX/RIS 导出选中项、当前筛选结果、整个库；直接剪贴板复制（E2）。 | `ContentView.targetPapers` 目前选中→可见→全库 fallback，没有清晰独立 scope picker；需避免空筛选时意外导出全库。 | 部分 |
| EX02 | **真实3.0 UI** 四选项：abstract、tag keywords、notes、customFields，默认开，其他非空字段始终导出（E4；E2 当前Localizable）。 | AppSettings.CitationExportField + ExportService +调用点有；Help九项过时不能作为交付目标。 | 有 |
| EX03 | 逐篇 detailed export，无图片→.md，有图片→.textbundle；citekey文件名无key退标题，碰撞不覆盖（E2）。 | ExportService.writeDetailedMarkdown/textBundle 有；模板路径、文件失败逐篇报错及includeAnnotations选择需验收。 | 有 |
| EX04 | 元数据/标注两套模板、variables/conditional blocks、preview/reset，{{collectionPaths}}而非单数（E2，E5真实模板）。 | TemplateRenderer + Settings模板预览/restore有；原版 MetadataTemplate 多实体和AppIntent TemplateEntity未覆盖；自定义key覆盖标准context需限制。 | 部分 |
| EX05 | 原版内部 `lattice://` 与 PDF URL变量（E1plist，E5模板）。 | `papermanager://paper/UUID` 正确是独立重构 app 的URL，不抢注原版 scheme；aliases bibtexKey/latticeURL/pdfURL有，但latticeURL实际是自家scheme，需说明为兼容变量名。 | 有意差异 |
| BK01 | .lattice ZIP备份metadata/annotations/tags/collections/templates，可选择含linked primaryPDF和attachments（E2；E5部分实际验证）。 | BackupService 只导出路径引用JSON，**不等于可携附件的.lattice备份导出**；当前只有原版archive reader。 | 部分 |
| BK02 | restore完全替换当前库，含文件选择extract目录，否则重连原路径；版本/schema拒绝未知（E2，E5）。 | LatticeArchiveService已有version1/schema2读取/primaryPDFcopy/目标备份/验证；secondary附件与annotation图像payload布局因真实样本无此数据，尚不支持/未验证。ZIP64被拒。 | 部分 |
| BK03 | 原库完整数据保真而非CLI丢字段（E5真实72paper归档）。 | 已可保留sourceIDs/key/date/rating/abstract/eprint/membership及2highlight，未知rawsidecar。此样本零notes/secondary不代表任意库零数据。 | 有（限定样本） |
| BK04 | Zotero迁移：读zotero.sqlite、文集/notes/annotations；PDFcopy或metadata-only；外部linkedPDF额外授权；永不移动/删Zotero源（E2、E9）。 | 无SQLite读取或迁移UI；LatticeCLI导入是另一独立功能，不能替代。 | 缺少 |

## 最初审计快照：系统集成、设置和外围功能

| ID | 原版契约 / 证据类型 | 当前 Swift 实现与差距 | 状态 |
|---|---|---|---|
| API01 | loopback listener，port开关/只读开关；status返回apiVersion/appVersion/capabilities/fileLibrary（E3，E6）。 | Network listener/loopback/CORS/readOnly/port有及既有TCP测试；capabilities与原版CLI要求名不同，缺fileLibrary状态。 | 部分 |
| API02 | `/api/v1/search?q=&limit=`，默认10、1..50、recent默认结果；官方CLI search/get-paper/get-by-reference/get-csl-item（E3/E6）。 | 目前无/search；GET/papers直接全部记录；没有exact-citekey resolver或csl独立接口。需按已发布CLI真实请求验证，不凭命令名猜路由。 | 缺少 / 部分 |
| API03 | detail opt-in include library/collections/tags/abstract/pdf_path；uuid/citekey精确不区分大小写；CSL原对象（E3）。 | detail无include gating，collections/tags返回字符串而非CLI要求object，当前CSL是自行生成的部分字段。需对接口schema逐项验收。 | 部分 |
| API04 | metadata lookup多hint；create-paper标题/authors/abstract/collection/tag UTF8上限、15types、missingcollection仅warning、不创建（E3）。 | lookup/POSTcreate有，collectionID(forPath:)会自动创建缺失层级且无warning，未实现完整上限校验及全部type；与已发布CLI契约不同。 | 部分 |
| API05 | duplicate默认skip，replace仅所给字段，returned alreadyExists/conflict/warnings/pdfAttached/enrichmentStatus；pending不是完成（E3）。 | metadata merge改进有；skip当前409，返回缺alreadyExists；enrich同步等待后"attempted"，并非原版排队pending契约。 | 部分 |
| API06 | PrimaryPDF上传/api/v1/papers/<id>/pdf及CLI attach，PDFmagic、regularfile、最大200,000,000bytes，force才替换（E2/E3）。 | 仅/connector上传路由；上限是200*1024*1024，force插前仍留旧链接；格式验证有。需对原版response reason=uploaded和实际路由兼容。 | 部分 |
| API07 | 官方CLI随包，--version/help/status、只读策略、loopback配置、JSONstdout/exitcode；可导出agent Skill/MCP（E3，E2）。 | 重构没有自家CLI/MCP/skill exporter；只使用原版CLI做迁移不能宣称具备本机agent接口。 | 缺少 |
| BR01 | Safari MV3已随包，Chrome类扩展可通过localAPI；无独立browser enabled设置，随LocalAPI启用；picker预览选择集合/标签/重复处理（E2/E8）。 | 仅connector server部分；无自己的可安装扩展，设置多一项browserExtensionEnabled；原版扩展端到端未验证。 | 部分 |
| BR02 | File Library NotAsked先设置/仅metadata；declined metadata-only；unavailable保存metadata报告PDF失败；legacyConflict先解决再创建（E2）。 | 无状态机，单browserUploadFolder无等价流程。 | 缺少 |
| OS01 | AppIntents ExportPaperMetadataIntent：default output=copyToClipboard，includeAnnotations=false，returnText/clipboard两种，openAppWhenRun=false（E7直接JSON）。 | 无import AppIntents、Intent/Entity/Query/ShortcutProvider。AppIntent中的动态paper picker实现细节仍U，Help多选声明不能由静态parameters证明。 | 缺少 |
| OS02 | Spotlight/Siri/Shortcuts，模板渲染、annotation图片占位、copy成功通知（E2/E7）。 | 模板renderer可复用，系统注册与picker/通知均缺少。 | 缺少 |
| ST01 | 外观、系统语言/中英文重启生效、默认PDF reader、文件库、citation/templates/integrations/backup（E2/E4）。 | SwiftUI设置五pane，appearance/reader/citation/templates/API/backup有；仅简体中文，native settings split/语言变化/通用细项布局未对版。 | 部分 |
| ST02 | Help独立原生split，有quickstart/import/library/citation/export/pdfOrganize/backup/shortcuts/template/localAPI/support（E2/E9）。 | 无内置帮助scene/菜单路由；README不能当作原生helpwindow。 | 缺少 |
| ST03 | 首启导览、可重启导览、What's New（E2/E9）。 | 无Onboarding/WhatsNew，实现功能帮助覆盖缺少。 | 缺少 |
| ST04 | AppStore免费50篇/Pro购买恢复、首次Zotero免限提示（E2，StoreKit包资源）。 | 模型残留freePaperLimit/proUnlocked但不对应真实StoreKit权益。独立重构可选择自己的容量政策，不能将本地Boolean描述为原版购买/恢复成功。 | 有意差异 / 缺少 |

## 最初拟定的实施切片（实施结果以上方Current为准）

1. **完整编辑与主附件语义**：建立15种论文类型和字段schema；独立DOI/ISBN/eprint；显示Standard/More/Other Filled/Custom；固定字段持久化；保留已有值。修复“替换PDF只追加”及退出前draftflush。在隔离库放同时带DOI+ISBN+eprint的文献，修改/清空/切类型/重启，验证所有原字段及新值。
2. **导入批次与冲突决策**：先prepare只读candidates，再Sheet勾选、预览和一次commit；统一PDF/BibTeX/RIS/DOI冲突skip/replace/openExisting/applyAll；取消前不写库/移动文件；补@string/#和ISBN提取。用真实结构的合成样本验证，不改原Lattice库。
3. **可独立使用的FileLibrary3.0**：State+RootBookmark+PlacementPolicy+Layout；明确NotAsked/Declined/Configured/Unavailable/LegacyConflict；全附件copy/move、Unsorted和按sidebar首文集；显式organize/rename；共享文件保护和失败回滚。所有文件fixture在独立目录，readonly源引用继续保护。
4. **侧栏完整组织**：Store层先校验depth/cycles/order，再NSOutlineView drag/drop、inline rename、tagcolor。持久化改父级和顺序，后代count/UI/filter用同一规则。
5. **真正兼容机器接口**：从官方CLI请求确定/实现search/ref/CSL/include/schema/status/capabilities/上传路由/UTF8limits/warnings；使用真实TCP逐个命令验证，不只调用router单测。原版API不可达不影响对自家隔离端口验证。
6. **可迁移数据闭环**：实现.lattice写出与附件打包；恢复secondary/shape图像的版本化契约；Zotero SQLite复制后只读导入，metadata-only不触发外部PDF授权；为notes/annotations/tags/collections/attachments全字段roundtrip留fixture。
7. **系统体验收口**：AppIntents/Shortcuts、扩展安装包与browser flow、语言/帮助/导览、多窗口活动焦点、按当前菜单校正快捷键，最后窗口截图与全路径交互对照。

## 原版未知项与最终收尾门槛

现有证据仍不能证明原版完整metadata来源优先级/取消调度、每种type的全部默认字段规则、OCR策略、FileLibrary内部placement所有状态、全部annotationimage/secondaryarchive布局、所有按钮像素/VoiceOver行为和AppIntent picker内部调用。当前重构已提供15type活动编辑、独立标识符/固定字段、安全placement与回滚，但这不把未知的原版算法变成已恢复。需要对应运行观察或更深入原生分析；不能用文件名、字符串命中或重构fixture替代。

“完整复刻”验收应以这些ID逐项记录原版证据、重构验证和差异决策。Current已实施项不应再按旧表误报缺失；构建与合成fixture也不能单独完成当前UI、浏览器安装、Shortcuts注册或原版算法等价验收。历史72paper样本只证明该源样本迁移的覆盖，不证明任意库或所有功能无损。

## 2026-10-18 API 实施增量

上表记录最初审计快照。随后按 E10 的实际 CLI 请求补了 `API01..API06` 的一组缺口：`/api/v1/search` 默认10/上限50、form query `+`空格解码、`/papers/by-citekey`精确且不区分大小写并保留歧义、`cslItem`、include opt-in、文集/标签对象、公开与connector双PDF路由、200,000,000字节上限、CLI所用capability名、作者string/array、UTF8请求上限、未找到文集warning且不自动创建、metadata enrichment后台pending并保护延迟期间本地修改。

独立库没有保存不透明provider CSL载荷，当前CSL对象由typed书目字段确定映射，不宣称恢复所有原始CSL扩展字段。未实现的plugin-hosting不在capabilities中冒报。`create-paper`收到本地pdfPath会明确warning并引导upload，尚未实现原版TrustedFolders原位授权。FileLibrary状态和自家机器CLI已在后续阶段实现，plugin-hosting仍未实现。真实TCP与安装版CLI验收结果记录在同目录 `API_COMPATIBILITY.md`，不要将实施记录读成所有API行为均与原版一致。

## 2026-10-18 文件库与原生设置实施增量

随后实现了FL01..FL06的主体功能：optional兼容配置、单root/bookmark/decline/legacyConflict、真实unavailable与修复、所有附件的copy/move、分组及两布局、future-only换根、显式organize/rename、readonly/shared引用保护、不覆盖IO及元数据写失败回滚；API状态和managed upload也统一到该FileLibraryService。Settings侧栏现为真实NSTableView+NSSplitViewController。独立FileLibrary fixtures最终11项全部通过。原版具体命名空间/所有内部placement状态仍未知，当前实现策略及证据边界见`FILE_LIBRARY_FINDINGS.md`。BK01 portable v2导出/恢复和BK04 Zotero读取/预览/持久化均已实施并有失败/清理fixture；当前UI仍由主任务最终验收。

## 2026-10-18 界面语言与多模板实施增量

ST01/EX04现已实现系统/简中/English设置、509对等资源key、SwiftUI locale与AppKit动态菜单/表头/字段/枚举翻译；按原版归档五字段保存所有MetadataTemplate，设置可增删改/选择/预览/恢复，保留独立annotation模板和旧库字符串兼容，模板CRUD使用durable写入。AppIntents查询真实模板列表并拒绝失效显式ID。Help完整正文、主题、搜索、快捷键表、Welcome和What's New均有独立编写的中英内容，已删除中文-only提示。用户文献/标签/文集/模板正文和机器字段不翻译。语言/模板回归6/6、归档回归14/14；完整窗口语言切换和系统菜单重启行为仍待主任务最终UI验收。字段依据与兼容策略见`LOCALIZATION_TEMPLATES.md`。
