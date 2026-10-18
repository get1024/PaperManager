# 界面语言与多元数据模板

2026-10-18。原版字段来源为 `../2026-10-13/mcp/lattice-archive-structure.json` 中真实 schema-2 归档的 `metadataTemplates` 字段清单；语言入口来自当前原版设置和已发布资源。本轮没有修改原版偏好或文库，也没有将私人模板内容、论文或 PDF 放入仓库。

## 界面语言

`AppSettings.languageIdentifier` 支持 `system`、`zh-Hans`、`en`。SwiftUI Scene 和设置内容采用对应 locale；`PMLocalization` 明确读取两套语言资源，为 AppKit 菜单、表头、搜索框、检查器动态字段、枚举 label、提示及格式化文案提供同一选择。当前资源各 **509个唯一key**，机器 rawValue 不作为本地化结果保存。此前449key为第一轮快照，494key为完整Help阶段；均已被当前509key覆盖。

系统模式读取全局 macOS 首选语言，并不修改系统语言。设置选择写入当前应用自己的 AppleLanguages 覆盖；切回系统清除此应用覆盖。应用自有主界面即时更新，macOS 管理的系统菜单可能需重新打开应用，设置里明确提示。SwiftUI 字面量和程序拼接字符串分别由资源 locale 和 `PMLocalization.text/format` 处理。

主要覆盖包括主菜单、智能筛选、原生侧栏菜单、论文表头/右键菜单、检查器类型/标准字段/固定字段、五个设置pane、备份操作、模板管理、导入预览/重复处理、文件库询问、导入计数以及未保存草稿/写入失败提示。文献标题、作者、标签/文集/模板名称、模板正文、引用键和书目导出字段均保持原文；新建模板的初始名称属于应用文案，创建后作为用户数据保存。`{{type}}` 输出稳定小写 raw type，避免切换界面语言改变模板机器值。

Help现有**完整中英正文**，包含入门、导入、文集标签、搜索阅读、编辑标注、文件库、导出模板、备份/Zotero、本地API/Shortcuts和键盘窗口。正文、主题、快捷键说明、Welcome三步导览及What's New的固定内容均通过`PMLocalization.text`读取；英语帮助已独立撰写并删除“仅有中文文章”的提示。搜索同时匹配源key和当前语言正文，因此英文词可检索英文帮助。Help描述重构已实现的功能，不把说明文字当作原版代码证据，也不把Shortcuts说明当作系统已注册的证明。

动态UI文案只翻译固定格式和选项：例如导入/替换/跳过/失败计数、按钮的条件分支和文件库决策。状态中的文献标题、原始错误细节及网络提供商/操作系统返回文本保持原文，不把用户文本送进语言查找。整个界面仍需实际切换语言、重开窗口检查截断和焦点行为；资源完整性不能替代这一步。

`scripts/build-app.sh`复制所有`.lproj`到应用Resources；SwiftPM处理两套语言资源并通过`Bundle.module`读取，Xcode工程使用Localizable.strings的en/zh-Hans variant group。`scripts/check-project-membership.py`验证两资源和全部app源成员；`scripts/build-swiftpm.sh`显式使用CLT可运行的native engine。SwiftPM executable排除需要actool的图标catalog，应用图标仍由打包脚本/Xcode处理。仅复制资源或构建成功不能代替英文/中文实际窗口验收。

## 模板模型与兼容

真实原版归档每个模板的已观察字段为 `id`、`name`、`content`、`isDefault`、`dateCreated`。`MetadataTemplate` 按这五个字段建模；`LatticeArchiveService` 映射数组中每个实体，保留源 UUID/时间/默认标记，并继续在 raw sidecar 保留未建模字段。没有从旧 Help 或字符串猜测额外模板算法。

独立应用的 `LibrarySnapshot.metadataTemplates` 是 optional，`AppSettings.activeMetadataTemplateID` 也是 optional，以兼容旧 JSON。旧库的 `settings.metadataTemplate` 和 `settings.annotationTemplate` 两套字符串仍可分别使用：首次只读旧库不会写入迁移，元数据模板在内存中投影为稳定 UUID 的单个默认模板。其 epoch 时间明确是兼容占位，不声称为原版创建时间。首次编辑或选择才实体化数组，并同步旧 `settings.metadataTemplate` 字符串以保留旧导出调用的兼容性。

当前模板选择是独立应用自己的 `activeMetadataTemplateID`，不声称原版归档也包含这个字段。无选择时优先原版 `isDefault`，其次数组首项。设置支持选择、新增、复制、重命名、编辑正文、删除、当前正文恢复默认及预览；至少保留一个元数据模板。标注模板仍为独立全局字符串，不伪造原版未观察到的多标注模板实体。

`TemplateRenderer.renderMetadata(..., templateID:)` 支持指定实体；普通导出用当前选择。AppIntents 的动态 `TemplateEntity` 列表由对应子任务接入真实 UUID/name/content，明确指定已删除 ID 时拒绝，不静默改用另一模板。

模板CRUD现通过`LibraryStore.replaceSnapshotDurably`提交：原子落盘成功后才发布内存变更，磁盘写失败不会报告已保存。`PortableBackupService`的共享验证器拒绝重复模板ID；当前选择ID失效仍使用模型明确的default/first回退，而AppIntent显式传入不存在ID时继续报错。这两种入口语义不同，不把恢复默认选择误作用户明确选择成功。

## 验证

- `scripts/test-localization-templates.sh`：6/6。测试执行真实 `.app` 资源查找，证明 English/简中动态 enum 和格式字符串切换；用户数据/机器值不翻译；旧库兼容；模板 CRUD/独立正文/显式渲染；选择与源字段持久化；含两个模板及未知字段的合成 `.lattice` ZIP 读入。
- `scripts/test-lattice-archive.sh`：14/14。归档字段、原引用键/日期/评分/标注、metadata-only 与显式复制、已有目录/符号链接保护、损坏归档拒绝均通过。脚本读取固定源码快照，避免多任务同时编辑导致编译器输入变化。
- `scripts/test-metadata-intents.sh`：6/6，包括多模板动态查询、active/explicit渲染、已删ID拒绝；使用注入的clipboard sink。CLT下direct perform通过不等于Shortcuts平台注册。
- `scripts/test-import-backup.sh`：27/27，包含真实写盘失败的模板CRUD回滚和portable/legacy模板身份验证，详细边界见`RECONSTRUCTION_AUDIT.md`。
- 当前`plutil -lint`及资源一致性检查：两套509/509唯一key集合相同、无重复、格式占位符对应；English资源值不残留中文。Help固定文案均有English资源；用户文本不属于这项固定key审计。
- 完整Help阶段的冻结全app源码typecheck通过；集成阶段CLT SDK26.5显式SwiftPM native engine构建通过，app/CLI及双语resource bundle已检查；`.build/packaging-validation-20261018/PaperManager.app`通过应用及内嵌CLI签名、help/version/config和资源验证。PBX语法与33源/资源成员通过检查，**未运行完整Xcode build**。后续源码变更后的最终集成构建由主任务记录。

**currentUI = 待主任务最终验收。** 包括实际中英窗口、语言选择持久化、系统菜单重开、帮助搜索/排版及原生菜单/表头的当前显示。上述构建、固定资源检查和合成fixture均不代填UI验收结果。

所有 fixture 使用独立临时目录和合成内容；测试没有访问或修改真实 Lattice 文库。
