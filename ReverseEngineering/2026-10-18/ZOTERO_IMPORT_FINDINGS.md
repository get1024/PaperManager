# Zotero SQLite 迁移实现与验证

日期：2026-10-18。本次只使用合成 SQLite 数据，没有发现或打开用户真实 Zotero 文库，没有读取真实论文或同步服务。

## 实现范围

新增 `Sources/PaperManager/Services/ZoteroImportService.swift` 与独立原生 sheet `Views/ZoteroImportView.swift`。设置入口由 reference_contract 集成到 Backup pane。

服务接口：

```swift
ZoteroImportService.prepare(from: selectedURL, attachmentMode: .metadataOnly, settings: settings)
ZoteroImportService.prepare(from: selectedURL, attachmentMode: .copy(to: newOwnedDirectory, includeExternalLinkedFiles: false), settings: settings)
ZoteroImportService.persist(result, into: store) // MainActor, returns added count
ZoteroImportService.cleanupPreparedFiles(result, keepingReferencedBy: snapshot)
```

`prepare` 返回独立的 `LibrarySnapshot`、计数、warnings、来源记录 JSON、快照 SHA 和本批次 owned 目录；不改变 Store。Sheet 默认“不导入文件”，选择包含 `zotero.sqlite` 的文件夹后先读取、展示摘要与差异提醒，用户确认才调用 `persist`。

## 数据库与 WAL

- 源连接使用系统 SDK 的 SQLite3 `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`，并设置连接级 query_only；不 chmod、写入或 checkpoint 源数据库。
- 使用 `sqlite3_backup_init/step/finish` 把已提交的 WAL 内容一并读入新的私有快照。不使用 `immutable=1` 忽略 WAL，也不直接拼接复制 live DB/WAL。
- 仅对私有目标执行 `PRAGMA journal_mode=DELETE`，使随后只读重开不依赖临时 WAL；两个连接被延长生命周期至备份完成。
- 表和所有元数据从快照读取，临时快照在 prepare 返回后删除。快照失败/持续繁忙会返回错误，不退回有遗漏风险的裸文件复制。

参考结构为官方 [userdata.sql](https://github.com/zotero/zotero/blob/main/resource/schema/userdata.sql) 与 [system.sql](https://github.com/zotero/zotero/blob/main/resource/schema/system.sql)。没有复制 Zotero 的业务实现。

## 字段映射

- 解码 itemData → fields/fieldsCombined → itemDataValues；combined 表为空时仍保留基础字段与类型。
- 支持来源类型、作者/编辑/译者顺序与 corporate names；未映射的 creator role 和字段保留为自定义字段或完整原始来源记录。
- 保留文集父子与多重归属、标签和可解码的 synced tagColors、添加/修改日期。循环文集会在产生文件副本前失败。
- 源 `citationKey` 或 Extra 中的 `Citation Key:` 保留；缺省时用当前 CitekeyGenerator 规则，并处理同批次冲突。
- HTML 笔记按源内容保留，不冒充已经转换成 Markdown。附属于 PDF 的标注恢复到其父论文；保留选中文本、备注、颜色、页标签、pageIndex→一基页码。多矩形合并为包围框并给出提醒。
- 已删除项目不迁移；孤立记录、未知列、原始 annotation position JSON 留在本地来源记录。结构化模型不能表示的墨迹/图像几何明确 warning，不报告为已恢复原始批注图片。

`persist` 合并新记录，按稳定的 Zotero libraryID/key 派生 UUID 保持再次导入幂等，保留已有本地记录和用户设置；不静默覆盖不同 ID 的 DOI 冲突。来源记录存入目标文库旁 `ZoteroSources/<UUID>/source.json`（父目录 private 且 gitignored），原目标 JSON 在写入前另存备份。

最终快照通过 `LibraryStore.replaceSnapshotDurably` 原子写成功后才发布到内存；写入失败保留旧快照，并清理本次新建的来源记录目录。准备阶段的 PDF 副本仍由预览持有，允许重试或取消，不会在落盘失败时把来源 PDF 移动或删除。

## 附件与文件库契约

原 Lattice 3.0 捆绑 Help 明确：Without PDFs 保留 papers/collections/notes/annotations，不请求外部 linked-PDF 文件夹；Zotero 源 PDF 只拷贝，不移动或删除。配置文件库后复用现有组织与重命名规则。

- metadataOnly 分支不解析、打开或探测附件路径，结果中不附加来源 PDF 引用；来源附件记录仍保留。
- 拷贝模式要求新的 owned 目录；Sheet 只在已有授权文件库 root 下创建新 UUID namespace。没有 root 时仍可不导入文件，并提示在通用设置授权。
- `storage:<relative>` 仅解析到该数据目录的 `storage/<attachmentKey>/`；路径穿越与逃逸 symlink 会跳过。外部绝对 linked-file 路径需要单独 opt-in。`attachments:` 相对 linked-base 路径不猜测用户的独立 Zotero 偏好设置，明确跳过并提醒。
- 复用 `FileLibraryService.plan/execute(managedImport: true)`，在 owned namespace 内保留当前 layout/grouping/rename。临时 placement preferences 不沿用父 root 的 bookmark，返回 snapshot.settings 仍为原设置。
- 直接从 source 拷贝到最终 owned 路径一次，不再调用 attachManagedFile 二次拷贝。Local File Action 即使是 Move，Zotero 仍强制 Copy。
- owned 目录有本批次 token。取消/重选删除未提交批次，persist 后只保留目标文库仍引用的副本，跳过记录产生的副本会清理。已有库引用优先于清理，以保护部分保存失败时仍被使用的文件。

## 验证结果

`scripts/test-zotero-import.sh`：**14 passed, 0 failed**。使用真实 SQLite API 与活跃 WAL 合成源，并验证：

1. 只在 WAL 中提交的文献被读取；源 DB/WAL 字节与 0444 权限不变。
2. 作者顺序、个人/机构姓名、编辑译者、类型、额外字段与引用键。
3. 嵌套/多重文集、标签颜色和源日期。
4. 不导入文件时仍保留笔记与标注。
5. 稳定 ID 与未知列、原始标注位置 JSON 的保留。
6. storage 拷贝与外部/穿越/symlink 边界。
7. 显式允许外链后拷贝并保留来源。
8. 文件库布局/分组/命名、强制 Copy、预览清理与仍被引用副本保护。
9. 已有/符号链接目标拒绝覆盖。
10. deletedItems 排除，拷贝后源文件仍不变。
11. 循环文集在创建副本目录前失败。
12. 非 Zotero DB 拒绝读取。
13. 独立持久化合并、原记录保留、重复导入幂等和来源记录落盘。
14. 真实写盘失败保留当前文库与无关文件，只清理本次创建的来源记录目录。

新 View 与其模型/服务依赖已通过 macOS 26.5 SDK 的独立 Swift typecheck。测试编译会先快照源码，避免其他 agent 同时编辑共享文件导致 Swift `input modified` 中止。尚未使用真实用户文库，也没有把 typecheck 或合成测试当作原生 sheet 已完成交互验收。
