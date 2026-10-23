# 应用、数据与归档

## 正式应用

唯一正式应用是 `~/Applications/PaperManager.app`，`dist/PaperManager.app` 为指向它的符号链接。根目录 `Launch PaperManager.command` 负责启动。

构建和安装先在临时目录完成签名与校验，再替换应用。安装脚本将上一个正式版本压缩保存到 `LocalData/Backups/Applications/`，替换失败时回滚。

## 个人数据

- `~/Library/Application Support/PaperManager/CurrentLibrary/library.json`：当前文库；清理基线为 72 篇文献、5 个文集、32 个标签。
- 同目录 `PDFs/`：72 个独立 PDF。
- `LocalData/Library/`：此前迁移保留的独立文库和 PDF。
- `LocalData/Backups/`：可移植文库备份、旧文库与应用恢复包。

这些目录不进入 Git，也不作为缓存清除。当前文库偏好为 `PaperManager.PreferredLibraryPath`；启动脚本依次使用显式 `PAPERMANAGER_LIBRARY_PATH`、有效偏好、`LocalData/Library/library.json`，最后使用默认文库。

## 历史资料

2026-10-23 的完整清理前源码快照、未提交补丁、数据基线、历史逆向资料和截图位于项目旁：

```text
../PaperManager-LocalArchive/2026-10-23-cleanup/
  source-before.tar.gz
  working-tree-before.patch
  baseline.json
  ReverseEngineering/
  BuildEvidence/
  DiagnosticTools/
```

`ReverseEngineering/` 保持原目录结构，便于查阅相对引用。它不是当前构建或测试依赖；仓库文档仅记录当前结构与验证范围。更早的资料仍在 `../PaperManager-LocalArchive/2026-10-18/`。

## 可重建产物

`.build/` 为编译缓存、测试夹具和结果。`scripts/clean.sh` 保留 `.build/test-results/`，其余可重建内容删除；`scripts/clean.sh --all` 清除整个构建输出。新构建的临时目录由脚本退出处理自动移除。
