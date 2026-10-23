# PaperManager · 图标设计探索

2026-10-24 · 以下保留最初四个原创概念方向。以纸的结构、知识的整理和阅读时的展开为出发点，使用内置 imagegen 生成；没有复制参考作品的图像。

用户已选定 **B「折页」**，并将亮蓝色背景调整为米灰色。应用和首页已采用这一正式版本；下方蓝底 B 和其余三幅均为历史探索素材。[正式资源与复现方法](../../../App/IconSource/README.md)。

<img src="../../images/app-icon.png" width="256" alt="正式图标：米灰底、象牙白折页与珊瑚红内折面">

## B「折页」的设计基础

一张纸通过折叠形成可辨认的整体：象牙白承载纸的质感，珊瑚红让内折面成为记忆点。最初概念采用钴蓝背景；正式版本改用更温和的米灰背景，保留阅读与纸张的含义以及独立的折页轮廓。

## 最初四个方向

| A · 索引物 | B · 折页（蓝底概念） |
|:---:|:---:|
| <img src="01-index-object.png" width="240" alt="索引物概念"> | <img src="02-folded-field-source.png" width="240" alt="折页概念的干净方形源图"> |
| 深石墨托架、三层纸与朱红索引。功能含义直接，偏工业产品。 | 连续折页、蓝白对比与内折面。形状简洁，识别重点明确。 |
| **C · 色彩之间** | **D · 纸的回声** |
| <img src="03-color-relations.png" width="240" alt="色彩之间概念"> | <img src="04-paper-rhythm.png" width="240" alt="纸的回声概念"> |
| 青绿与朱砂橙交叠，以色块关系表达整理和关联。偏平面艺术。 | 六片书页围绕小赭黄书脊展开。偏艺术家书籍和纸雕塑。 |

打开 [preview.html](preview.html) 可查看正式米灰版，并比较历史概念在浅深背景及 16、32、64、160 px 下的显示效果。浏览器预览使用原图和 CSS 呈现，不是安装后的 Dock 截图。

## 研究依据与设计转译

以下是本次检索的原始来源；右栏是针对 PaperManager 的设计判断。

| 来源 | 取用的方法与本次转译 |
|---|---|
| [Vitsœ：Dieter Rams 的设计原则](https://www.vitsoe.com/us/about/good-design) | 关注可理解的结构与克制的形式。A 用少量纸片、托架和单个索引表达收纳。 |
| [Corraini：Munari《Libro illeggibile MN 1》](https://corraini.com/en/products/libro-illeggibile-mn-1) | 出版社介绍纸张可通过开本、颜色、切口和顺序传达信息。B、D 将纸自身的结构作为主体。 |
| [Albers Foundation：Interaction of Color](https://www.albersfoundation.org/alberses/teaching/interaction-of-color) | 研究颜色在相邻与交叠关系中的感知变化。C 用两个纸面与交叠区组织视觉，不沿用现成作品构图。 |
| [Apple：App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons) · [WWDC25 图标设计讲解](https://developer.apple.com/videos/play/wwdc2025/220/) | 用较少形状表达核心概念，保证主体居中与小尺寸识别；为后续系统遮罩和分层制作留出空间。 |

## 素材与验证状态

| 文件 | 用途 |
|---|---|
| `01-index-object.png` | A 概念原图，经过一次 imagegen 边缘精修 |
| `02-folded-field.png` | B 最初的圆角、透明外部概念图 |
| `02-folded-field-source.png` | B 经 imagegen 编辑的干净、不透明蓝底源图；保留作历史探索记录 |
| `03-color-relations.png` | C 概念原图 |
| `04-paper-rhythm.png` | D 概念原图 |
| `01-prompt.txt` 至 `04-prompt.txt`、`02-source-prompt.txt` | 实际生成与编辑提示词 |
| [manifest.json](manifest.json) | 原图尺寸、颜色模式、透明度范围和 SHA-256，以及正式资源的去向 |

已逐张检查实际 PNG。工具实际输出均为 **1254 × 1254**，没有遵守提示词中的 1024 尺寸。B 的方形源图为 RGB、完全不透明；其他概念图为 RGBA，部分底板接近不透明，外轮廓仍有轻微透明散点或毛边。

以上尺寸、哈希与透明度描述针对本目录保留的历史素材。最初探索阶段没有交付多尺寸资源或完成 Dock 验收；这些旧验证结果保留在 manifest 中，避免覆盖历史事实。

正式米灰版在独立目录保存母版，并导出 macOS 图标资源、`.icns` 和 README 图标。当前资源、导出方法与验证范围见[正式图标说明](../../../App/IconSource/README.md)。目前采用栅格资源，未制作 Icon Composer 分层、深色或染色外观变体。
