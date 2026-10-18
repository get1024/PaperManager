# File Library 3.0 重构实施与验证

2026-10-18。依据原版3.0包内当前Help/Localizable、REA保留类型，以及主任务本日实际General设置的AX/截图（私有`.build/qa-2026-10-18/lattice-general.ax.txt`）。原版文件夹、PDF、设置、数据库均未由本子任务改动。

原版明确声明：单一授权根、本地动作Do Nothing/Copy/Move、分组、独立Rename Rule、PDF/附件分开或每篇一文件夹；改根只影响今后文件、显式Apply才整理已有文件；无分组值进入Unsorted；按文集取侧栏顺序首个；本地动作不控制browser/Zotero/restore；只读来源和共享引用不能被破坏。实际General UI确认默认重命名格式`{year} - {authEtAl} - {title:50}`。这些是当前证据支持的契约，具体未恢复实现的部分仍需区分。

## 已实现的独立状态和业务

- `AppSettings.fileLibrary: FileLibraryPreferences?`为可选新增字段，旧JSON继续解码。未显式配置时只读解释旧`pdfOrganizationFolder`/`browserUploadFolder`：单路径继续使用，两条不同真实路径进入legacyConflict，不擅自选一条。
- 新preferences持久化decision、rootPath、security-scoped rootBookmark和layout。runtime状态notAsked/declined/configured/unavailable/legacyConflict每次根据实际bookmark和文件夹可读写性计算；坏bookmark不会悄悄退回字符串路径并假报可用。
- 所有新根由设置中的原生NSOpenPanel选择并保存bookmark。重置/拒绝只改变未来策略；既有Attachment路径和文件不动。
- `FileLibraryService.plan/execute`统一primary PDF和任意附件，保留扩展名、Unsorted及侧栏首文集选择。`managedImport:true`强制copy，用于browser/Zotero等，不受本地Move/Do Nothing影响。
- separate布局：primary=`root/group/name.pdf`，附件=`root/Attachments/group/PaperUUID/name.ext`；byPaper布局：两者`root/group/PaperUUID/name.ext`。**字面命名空间及UUID容器名是本重构的确定策略**，包内描述只证明分开/同容器语义，尚未证明原版精确命名完全一致。
- `filenameStem`支持原版当前format的year/authEtAl/title:N和常用书目变量；缺失必要变量保留原文件名。authEtAl渲染“姓氏 et al.”，属可解释的重构策略，精确大小写/姓氏规则仍可用进一步函数或受控运行证据校正。
- `LibraryStore.organizeFiles(paperIDs:)`和`renameFiles(paperIDs:)`返回FileOperationSummary。当前已管理文件显式整理时可以按新布局重定位，独立于本地Do Nothing；外部in-place文件则遵循当地Copy/Move/None政策。Native表格菜单已由核心UI子任务接入并先flush draft。
- 只读来源的move/rename被拒绝；全库其他记录/附件仍引用同一源时拒绝move/rename，copy可创建独立文件。源文件不会因无force上传或复制失败被删除。
- 目标路径必须位于授权根并拒绝symlink路径组件。copy用O_EXCL/O_NOFOLLOW创建目的文件并流式读写；同卷move用RENAME_EXCL，跨卷copy完成且源identity不变后才删源。目的地抢先出现时失败，不覆盖。
- 业务仅在文件操作成功后用可抛错的原子JSON写提交metadata；保存失败对已执行receipts回滚。同卷rollback保留inode；原位置出现新文件时保留副本并报错，不覆盖新文件。

## 原生设置与机器接口

Settings现在以NSSplitViewController承载左侧NSTableView和右侧NSHostingController，五pane为通用/引用/集成/备份/模板。General包含文件库状态、授权/修复/旧位置冲突选择、三种Picker、重命名和显式Apply。原版语言等更广泛的设置差异仍见FEATURE_CONTRACT。

LocalAPI status新增真实`fileLibrary`状态对象，configured且可访问才声明pdf-upload；公开和connector上传均经`attachManagedFile`统一分组/布局/规则。浏览器集成随LocalAPI启用，旧browserExtensionEnabled字段仅保留解码兼容，不再成为隐藏第二开关。metadata创建仍不自动读取任意pdfPath/TrustedFolders；该限制在warning中明确。

Backup pane已接主任务的portable `.papermanager`ZIP writer：包含PDF/附件开关、后台写/读、恢复前独立metadata备份、成功后比较真实持久化JSON。它不是原版`.lattice`writer；原版归档reader仍为单独入口。Zotero sheet由独立子任务提供，当前Settings已挂`ZoteroImportView(store:)`入口。

## 验证

`bash scripts/test-file-library.sh`：**11 passed, 0 failed**，最终一次覆盖同卷exclusive move与rollback。fixture均在临时独立目录，以合成文本/PDF名称验证文件字节，没有使用真实文献：

1. 旧settings解码、单根迁移、双根冲突、explicit decline优先。
2. 实际创建bookmark、失效/缺失根、重新授权恢复。
3. PDF与任意附件copy、Unsorted和separate布局、重读库验证路径。
4. 两种文件move、byPaper容器、关系插入序与侧栏顺序不同时选正确文集。
5. readonly源move/rename拒绝，copy不改变源字节或源权限标记。
6. 多文献共享源不能破坏其他关系。
7. 目的文件在plan后出现不覆盖；symlink不能把文件写出根。
8. rollback恢复源；plan后源内容变化会拒绝执行。
9. 模拟库写入失败，已移动文件恢复原位置且metadata关系不变。
10. 换根不自动动已有文件；显式Apply再使用新根/布局；本地None仍可整理已管理文件。
11. managed import即使本地Move也保留源；重命名token及缺必要值fallback。

集成期间`bash scripts/test-local-api.sh`：**13 passed, 0 failed**，含已安装官方LatticeCLI只读连接独立TCP服务，文件上传也使用新服务。随后新增exclusive文件IO和rollback仍由上述最终11项覆盖。主任务最终全套重跑负责最终集成快照。

原生Settings结构曾完成独立app构建/签名，输出`.build/file-library-validation/PaperManager.app`；之后backup/Zotero入口集成由主任务最终构建复验。此处不把构建当作已完成真人窗口像素/交互对版。

未恢复原版的所有3.0placement enum、跨进程cloud占位文件/设备断开/并发更新调度等内部状态。receipt和命名空间是本重构实现；不得凭同名功能声称原版源码已恢复。
