# 官方 LatticeCLI 与独立 Swift API 兼容验证

2026-10-18，Asia/Shanghai。原版 Lattice 为3.0 (26)。原版 `status` 当前退出1、loopback不可达；本次没有开启其API、修改原版文库或设置。所有运行验收对象均是测试进程新建的独立LibraryStore、系统分配的loopback端口及合成PDF/文献。

## 先观察实际请求

`official-cli-wire-probe.json` 保存安装包中 `/Applications/Lattice.app/Contents/MacOS/LatticeCLI` 连自建无存储HTTP responder的合成请求。原版CLI的命令与路径关系：

| CLI命令 | 实际HTTP行为 |
|---|---|
| status | GET `/api/v1/status` |
| search | GET `/api/v1/search?q=...&limit=...`，空格编码为`+`，literal plus编码为`%2B` |
| get-paper | GET `/api/v1/papers/<UUID>`；重复include合并，`pdf_path`转换为`pdfPath` |
| get-paper-by-reference UUID | GET UUID详情 |
| get-paper-by-reference citekey | GET `/api/v1/papers/by-citekey?key=...`，读取`{papers:[...]}`，唯一时再GET UUID详情；零个/多个均拒绝 |
| get-csl-item | 同上解析引用，从UUID详情提取`cslItem`；**没有另造独立CSL HTTP路由** |
| collections / tags | GET `/api/v1/collections`或`/api/v1/tags`，stdout保留server返回的wrapper |
| lookup-metadata | GET `/api/v1/metadata?doi=...&arxivId=...&isbn=...&title=...` |
| create-paper | POST `/api/v1/papers`；数组形式的CLI authors最终归一为分号字符串，`--type`发为`paperType`。该次探针只向无存储responder发合成JSON，没有创建原版文献。 |

## 已实现

`Sources/PaperManager/Services/LocalAPIServer.swift`：

- 实际loopback TCP server、Origin校验、只读策略继续保留。
- 搜索默认10、最多50、空查询按添加日期倒序；搜索文档明确的title/authors/source/citekey/year。当前按各词匹配并忽略大小写/重音，这是确定的重构策略，未声称恢复原版matcher全部细节。
- citekey trim、不区分大小写的精确匹配，保留全部匹配让CLI识别歧义；无fuzzy回退。
- 轻量hit补齐authorsDisplay/paperType；详情补齐journal/volume/issue/pages/isbn/cslItem。
- include=library/collections/tags/abstract/pdfPath；未请求不返回这些顶层字段。文集和标签采用id/name/path/depth/colorHex对象；PDF只返回当前可读且解析成功的路径或null。
- status使用search/paper-detail/csl-item等真实能力名；写模式才声明create-paper，配置上传目录才声明pdf-upload；未实现plugin-hosting不冒报。
- Public `/api/v1/papers/<UUID>/pdf` 和旧 `/connector/papers/<UUID>/pdf` 均支持PUT；%PDF-与PDFKit校验、MIME、十进制200,000,000字节上限、无force返回409、成功reason=uploaded。force提升新PDF为primary同时保留旧只读来源引用，源字节不变。
- 创建支持作者string/array；标题/作者/摘要UTF8上限和文集标签数量/长度限制；未知文集仅warning，不自动创建；新tag可创建；replace只更新传入metadata并保留本地评分/备注/标注/附件/已有归属。
- enrich异步返回pending，延迟结果仅填缺项并使用最新记录，不覆盖期间本地编辑；stop取消挂起任务。

## 运行验证

`bash scripts/test-local-api.sh` 完成：**13 passed, 0 failed**。

1. 实际lsof检查只监听127.0.0.1，并检查其他loopback/LAN地址无法连接。
2. CLI/no-Origin、loopback、Chrome/Safari extension Origin和preflight。
3. 任意网页Origin不能读写。
4. 恶意长度、重复header、chunked、畸形frame、重复query不使server崩溃。
5. read-only限制；browser集成随LocalAPI启用，旧独立extension开关不再覆盖3.0策略。
6. 错MIME/坏PDF/无force冲突不落文件。
7. 分段PDF上传、主附件改变、原版只读来源保持且字节不变。
8. metadata replace保留notes/rating/annotations/attachments/omitted字段、合并现有membership并实际重读JSON。
9. 无效port不发生整数转换trap。
10. 搜索words/form空格、默认recent10/上限50、notes不进入公开搜索、exact-citekey、opt-in payload和CSL字段。
11. UTF8上限/非法策略/数组作者，missingcollection warning且没有新建文集。
12. Public PDF route成功、重复force保护、200,000,001长度在buffer前拒绝。
13. **真正执行已安装官方LatticeCLI**，强制`LATTICE_CLI_BASE_URL`为自建测试server、`LATTICE_CLI_READONLY=1`：status/search/get-paper/includes/get-by-reference/get-csl-item(UUID和citekey)/collections/tags均exit0且JSON正确；模糊键和重复exact键被CLI拒绝。

第13项若机器没有原版CLI会明确SKIP，不假报兼容。此次本机有CLI且该项实际PASS。测试保存的fixture和PDF都在临时独立目录，完成后删除；不读取原版用户文献。

## 尚存边界

CSL是根据独立库typed metadata生成的标准对象，不等于恢复不可见provider的原始扩展键；个人作者名拆分仍属重构策略。FileLibrary状态/统一布局已在后续切片实现并接上传路由，见`FILE_LIBRARY_FINDINGS.md`；TrustedFolders与原版browser插件分发仍未重建。`create-paper`带pdfPath会返回明确warning并引导upload，不假装已经bookmark原位授权。原版未就绪时无法新增对照它的写接口行为证据，409等冲突形态仍遵循既有实现和可用文档，不能声称所有错误JSON逐字相同。

本次改变范围仅LocalAPIServer和LocalAPITests及本目录证据文档；应用构建、原生UI和其他功能由主任务继续集成验收。
