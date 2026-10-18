# 本地应用、数据与清理记录

2026-10-18 清理后，工作目录只保留 `dist/PaperManager.app` 一个应用构建。根目录 `Launch PaperManager.command` 和 `scripts/run-reconstruction.command` 指向同一应用。

## 个人数据

- `LocalData/Library/library.json`：已迁移的 72 篇文献、5 个文集、32 个标签、2 条标注、1 个模板。
- `LocalData/Library/PDFs-2026-10-18/`：72 个独立 PDF，所有附件路径已更新并检查可读。
- `LocalData/Backups/PaperManager-72-paper-library.papermanager`：经过实际恢复验证的完整可移植备份。
- `LocalData/cleanup-manifest.json`：本机路径与数量记录。

`LocalData`、`dist`、`.build` 不纳入 Git。启动脚本在本地文库存在时使用它；新检出或直接打开应用时使用 Application Support 默认文库。已有默认文库未被覆盖。原版 Lattice 数据未被改动。

## 可恢复归档

旧内容移动到项目旁边的 `../PaperManager-LocalArchive/2026-10-18/`：

- `Build/`：旧构建、重复验证版、日志、REA/Ghidra/JDK 分析环境及原始 Lattice 备份。
- `RecoveredLattice/`：早期回收的原版资源与静态分析投影。
- `ReverseEngineering-2026-10-13/`、`ReverseEngineering-2026-10-18/`：原始抓取、JSON、反编译片段与私人运行证据。
- `AcceptanceLibrary/`：最后验收时使用的独立文库副本。
- `Handbook/`、`assets/`：旧需求稿和未使用的原始图像资料。

这些内容保存在本机，未永久删除，也未加入本次远程提交。当前报告中的旧路径是当时证据标识；查原始文件时按以上归档映射定位。日常开发只需当前仓库，不依赖该归档。
