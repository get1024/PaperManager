# PaperManager 正式图标

正式方案为 **B「折页」米灰版**。暖米灰背景衬托象牙白纸面，珊瑚红内折面提供识别重点。图形通过纸面的展开与内折表达阅读和整理。

<img src="../../docs/images/app-icon.png" width="256" height="256" alt="PaperManager 正式图标：米灰底、象牙白折页与珊瑚红内折面">

## 资源

| 路径 | 用途 |
|---|---|
| `folded-field-greige.png` | 内置 imagegen 对选定 B 概念进行背景改色后的原始输出；1254 × 1254、RGB、不透明 |
| `prompt.txt` | 本次背景改色使用的提示词 |
| `AppIcon-1024.png` | 归一化为 1024 × 1024 的不透明方形母版，保留全幅米灰背景 |
| [`AppIcon.appiconset`](../../Sources/PaperManager/Resources/Assets.xcassets/AppIcon.appiconset) | 正式 macOS 资产目录；16、32、128、256、512 pt 各提供 @1x、@2x PNG，最大 1024 px |
| [`PaperManager.icns`](../PaperManager.icns) | 由同一套 PNG 封装的正式 macOS 图标资源 |
| [`app-icon.png`](../../docs/images/app-icon.png) | README 图标，与资产目录的 256 px 版本一致 |

原始蓝底 B 和另外三个方向保存在[图标设计探索](../../docs/design/icon-exploration/README.md)，作为设计过程记录。它们不是当前应用资源。

## 重新导出

在仓库根目录运行：

```sh
scripts/render-app-icon.sh
```

脚本从选定源图进行确定性归一化和尺寸导出。传统 macOS 图标使用透明画布、居中的圆角底板；1024 px 画布上的底板宽 824 px，较小版本按相同比例缩放。该留白用于使图标在 Dock 中的视觉尺寸与系统应用接近。

十张 PNG 由同一母版生成，没有为小尺寸另画图形。脚本同步导出资产目录、`.icns` 和 README 图标；应用构建链也会从相同 PNG 重新生成包内的 `Contents/Resources/PaperManager.icns`。

当前交付采用标准栅格 PNG 与 `.icns`，没有制作 Icon Composer 分层、深色或染色外观变体。

## 验证范围

资源尺寸、透明边缘、`.icns` 原生解码及已安装应用的系统图标解析均已检查，Dock 显示也经人工实机确认，结果见[验证记录](VALIDATION.md)。
