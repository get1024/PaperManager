# 阅读预览与统计

## 参考研究（2026-10-28）

研究了 [Zotero Style](https://github.com/muisedestiny/zotero-style) 的实现机制，未复制插件代码或引入其运行时依赖。

- [`events.ts`](https://github.com/MuiseDestiny/zotero-style/blob/master/src/modules/events.ts)：每 10 秒访问 Zotero Reader 的页码、滚动位置和激活状态；长时间位置不变后停止累计，按页存时间。
- [`item.ts`](https://github.com/MuiseDestiny/zotero-style/blob/master/src/modules/item.ts)：将统计写入插件条目下面的 JSON 笔记。
- [`progress.ts`](https://github.com/MuiseDestiny/zotero-style/blob/master/src/modules/progress.ts)：将逐页数组绘制为透明度热图、柱形和百分比条。
- [README](https://github.com/MuiseDestiny/zotero-style#columns)：标题背景表示逐页停留时间，Progress 列表示逐页标注字数；不是自动推断的阅读完成百分比。

PaperManager 继续使用外部阅读器，无法直接获得上述 Zotero 内部事件。本版采用用户明确开始的会话计时和用户确认的进度，不生成虚构的逐页时间热图，也不将缩略图浏览视作已读。将来若某个外部阅读器提供可靠事件接口，可新增独立适配服务，经用户启用后提交统计；不需要把阅读器耦合进列表或检查器。

## 模块与数据

- `ReadingRecord`：累计秒数、0–1 进度、最近记录时间；作为 `Paper.reading` 可选字段兼容旧文库。
- `ReadingSessionService`：主线程会话状态，每 5 秒持久化；显式暂停、睡眠和正常退出提交尾段；使用单调时钟，忽略大于 15 秒的调度间隙并暂停。
- `LibraryStore.updateReading`：从最新 paper 合并字段，再走已有的原子事务。写失败暂停计时，保留待保存秒数供重试；删除记录后不能被计时器重新创建。
- `PDFPreviewService`：在后台借助 PDFKit 渲染单页，解析期间保留安全作用域访问；图像上限 320×440，页码限于文档范围。
- `PaperPDFPreview`：取消旧请求的 UI 回填；首尾页禁用对应的原生按钮；附件替换或论文切换回到首页。
- `PaperReadingView`：展示已保存时间、显式计时按钮和进度操作，独立于元数据文本草稿。

缩略图从附件读取，不修改 PDF。阅读记录随 JSON 与 `.papermanager` 备份保存；BibTeX/RIS 没有本应用阅读记录字段，不能用作完整阅读记录备份。计时为手动会话时长，不是精确注意力测量；关闭外部阅读器后需手动暂停。

## 验证

`scripts/test-reading.sh` 使用临时文库与合成三页 PDF，覆盖旧记录解码、时间累计、暂停／切换／调度间隙、并发草稿合并、失败恢复、落盘、进度边界和预览页范围。列表文字回归在 `scripts/test-native-table.sh` 中。完整发布验证见 `docs/releases/v1.1.0.md`。
