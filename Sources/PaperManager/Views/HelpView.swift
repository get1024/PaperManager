import AppKit
import SwiftUI

enum PaperManagerAuxiliaryWindow {
    static let library = "papermanager-library"
    static let help = "papermanager-help"
    static let welcome = "papermanager-welcome"
    static let whatsNew = "papermanager-whats-new"
}

extension Notification.Name {
    static let paperManagerImportRequested = Notification.Name("PaperManagerImportRequested")
}

/// Auxiliary windows do not own a library. Route their import request to one
/// existing library window, or consume it once when the shared App opens one.
@MainActor
final class PaperManagerLibraryWindowContext: ObservableObject {
    private static let contexts = NSHashTable<PaperManagerLibraryWindowContext>.weakObjects()
    static var importRequestedForNextWindow = false
    private(set) weak var window: NSWindow?

    init() { Self.contexts.add(self) }

    func attach(to window: NSWindow) -> Bool {
        self.window = window
        guard Self.importRequestedForNextWindow else { return false }
        Self.importRequestedForNextWindow = false
        return true
    }

    static var currentWindow: NSWindow? {
        let windows = contexts.allObjects.compactMap(\.window).filter { $0.isVisible || $0.isMiniaturized }
        if let main = NSApp.mainWindow, windows.contains(where: { $0 === main }) { return main }
        return NSApp.orderedWindows.first { candidate in windows.contains { $0 === candidate } }
            ?? windows.first
    }

    func acceptsImportRequest(target: Any?) -> Bool {
        guard let window else { return false }
        if let target = target as? NSWindow { return target === window }
        return Self.currentWindow === window
    }
}

struct PaperManagerAuxiliaryWelcomeView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PaperManagerWelcomeView(onImportFirst: {
            // Let the auxiliary guide close before presenting the main
            // window's native importer; all windows keep the App's one store.
            DispatchQueue.main.async {
                if let window = PaperManagerLibraryWindowContext.currentWindow {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    window.makeKeyAndOrderFront(nil)
                    NotificationCenter.default.post(name: .paperManagerImportRequested, object: window)
                } else {
                    PaperManagerLibraryWindowContext.importRequestedForNextWindow = true
                    openWindow(id: PaperManagerAuxiliaryWindow.library)
                }
            }
        })
    }
}

struct PaperManagerWelcomeLauncher: ViewModifier {
    @AppStorage("PaperManager.hasShownWelcome") private var hasShownWelcome = false
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            guard !hasShownWelcome else { return }
            hasShownWelcome = true
            openWindow(id: PaperManagerAuxiliaryWindow.welcome)
        }
    }
}

struct PaperManagerHelpView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTopic = "getting-started"

    private var topic: PaperManagerHelpTopic {
        PaperManagerHelpTopic.all.first { $0.id == selectedTopic } ?? PaperManagerHelpTopic.all[0]
    }

    var body: some View {
        NativeHelpContainer(selection: $selectedTopic, detail: AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(PMLocalization.text(topic.heading))
                        .font(.system(size: 18, weight: .bold))
                        .padding(.bottom, 10.5)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(topic.blocks.enumerated()), id: \.offset) { index, block in
                        helpBlock(block)
                            .padding(.top, index == 0 ? 0 : (block.isHeading ? 32 : 12))
                    }
                }
                .font(.system(size: 13, weight: .regular))
                .lineSpacing(8)
                .frame(maxWidth: 500, alignment: .topLeading)
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .textSelection(.enabled)
            }
            .id(selectedTopic)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colorScheme == .dark ? Color(red: 35 / 255, green: 36 / 255, blue: 40 / 255) : .white)
        ))
        .frame(minWidth: 720, minHeight: 500)
        .background(WindowChromeConfigurator { window in
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            let identifier = NSToolbar.Identifier("PaperManager.Help")
            if window.toolbar?.identifier != identifier {
                let toolbar = NSToolbar(identifier: identifier)
                toolbar.displayMode = .iconOnly
                toolbar.showsBaselineSeparator = false
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.isMovableByWindowBackground = true
        })
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private func helpBlock(_ block: PaperManagerHelpBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(PMLocalization.text(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        case .heading(let text):
            Text(PMLocalization.text(text))
                .font(.system(size: 18, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        case .bullets(let lines):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .top, spacing: 11) {
                        Text(verbatim: "•").frame(width: 5)
                        Text(PMLocalization.text(text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                }
            }
        case .tip(let text):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 17)).foregroundStyle(.yellow)
                    .padding(.top, 1)
                Text(PMLocalization.text(text)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(Color.yellow.opacity(colorScheme == .dark ? 0.10 : 0.08), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.yellow.opacity(0.35), lineWidth: 1))
        case .code(let text):
            Text(verbatim: text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        case .link(let title, let destination):
            Button { selectedTopic = destination } label: {
                HStack(spacing: 4) {
                    Text(PMLocalization.text(title))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.link)
        case .table(let headings, let rows):
            HelpReferenceTable(headings: headings, rows: rows)
        case .diagnostics:
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: versionInformation).font(.system(size: 12, design: .monospaced))
                Button(PMLocalization.text("复制版本信息")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(versionInformation, forType: .string)
                }
            }
        }
    }

    private var versionInformation: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "20261022"
        return "PaperManager \(version) (\(build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

private struct HelpReferenceTable: View {
    let headings: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow(alignment: .top) {
                ForEach(Array(headings.enumerated()), id: \.offset) { _, title in
                    Text(PMLocalization.text(title)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow(alignment: .top) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        Text(PMLocalization.text(value)).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

private enum PaperManagerHelpBlock {
    case paragraph(String)
    case heading(String)
    case bullets([String])
    case tip(String)
    case code(String)
    case link(String, String)
    case table([String], [[String]])
    case diagnostics

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }
}

private struct PaperManagerHelpTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let heading: String
    let blocks: [PaperManagerHelpBlock]

    static let all: [PaperManagerHelpTopic] = [
        .init(id: "getting-started", title: "快速开始", symbol: "sparkles", heading: "欢迎使用 PaperManager", blocks: [
            .paragraph("PaperManager 是一款 macOS 原生的文献管理工具。"),
            .heading("第一步：导入文献"),
            .paragraph("PaperManager 支持多种导入方式，让你快速建立文献库："),
            .bullets([
                "点击工具栏中的 + 并选择“导入文件…”，即可选择 PDF、BibTeX、RIS 文件或文件夹",
                "拖拽 PDF 文件或文件夹到文献列表",
                "通过 DOI、arXiv、ISBN 或标题查找文献"
            ]),
            .paragraph("确认导入前，可以预览条目并决定如何处理重复文献。自动补全元数据可在设置中调整。"),
            .link("了解更多导入方式", "import"),
            .tip("可以在设置 → 备份中选择从 Zotero 迁移现有文献库。"),
            .heading("第二步：浏览与整理"),
            .paragraph("使用文集、标签和评分来整理你的文献库："),
            .bullets(["创建文集，将相关文献归类到不同项目或主题", "为文献添加标签，支持自定义颜色", "使用星级评分标记重要文献"]),
            .tip("右键侧栏的“文集”或“标签”标题，即可新建文集或标签。"),
            .heading("第三步：导出引用"),
            .paragraph("选中文献后，可以导出 BibTeX、RIS，或使用模板生成包含笔记和标注的详细文本。"),
            .link("了解更多导出选项", "export"),
            .tip("在文献列表中按回车打开 PDF，按空格快速预览。")
        ]),
        .init(id: "import", title: "导入文献", symbol: "square.and.arrow.down", heading: "导入文件", blocks: [
            .paragraph("从 PDF、BibTeX、RIS 文件或文件夹中将文献添加到 PaperManager 文献库。"),
            .bullets([
                "点击工具栏 + 按钮并选择“导入文件…”，或按 ⌘I 打开文件选择器",
                "可以选择多个文件；文件夹中的可支持文件会展开为同一批次",
                "将 PDF 文件或文件夹直接拖到文献列表，也可以开始导入",
                "在预览中逐条勾选，检查标题、作者和来源，再确认导入",
                "检测到重复文献时，可以选择跳过、替换或打开已有记录，也可以把同一决策应用到其余冲突"
            ]),
            .tip("后台补全元数据使用“通用 → 更多选项 → 自动处理”中的设置；需要重新获取时，可选中文献后右键刷新元数据。"),
            .heading("通过标识符添加"),
            .bullets(["选择“文件 → 通过标识符添加…”，或按 ⇧⌘D", "输入 DOI、arXiv 编号、ISBN 或标题，检索需要网络连接", "在导入前检查候选信息和重复记录；缺少可靠标识符时也可手动添加"]),
            .heading("导入时自动归类"),
            .paragraph("当侧栏选中了某个文集或标签时，新导入的文献会加入这个目标。选择智能筛选时不会自动添加文集或标签。"),
            .tip("批量导入到特定文集时，先在侧栏选中目标文集，再执行导入。"),
            .link("了解文集与标签管理", "management")
        ]),
        .init(id: "management", title: "文献管理", symbol: "star", heading: "文集", blocks: [
            .bullets([
                "在侧栏创建、重命名或删除顶层文集",
                "使用“新建子文集”创建嵌套文集，整个层级最多三级",
                "拖拽文集可调整同级顺序；拖到另一个文集上可以设为子文集",
                "父文集可切换是否包含子文集中的文献",
                "拖拽文献到文集进行分配，一篇文献可以属于多个文集",
                "“未归类”智能筛选显示不属于任何文集的文献"
            ]),
            .heading("标签"),
            .bullets(["在侧栏创建、重命名或删除标签", "标签可拖拽排序，右键可选择颜色或输入十六进制颜色", "把文献拖到标签进行分配，一篇文献可以有多个标签"]),
            .heading("评分"),
            .bullets(["在检查器或文献列表中设置 1～5 星评分", "再次点击当前星级可以清除评分"]),
            .heading("智能筛选"),
            .table(["筛选", "说明"], [["全部文献", "整个文库"], ["未归类", "不在任何文集中的文献"], ["缺少 PDF", "没有主 PDF 的文献"], ["缺少标识符", "缺少 DOI、ISBN 和预印本编号的文献"]]),
            .heading("标注与元数据"),
            .bullets(["检查器中点击编辑按钮即可编辑标题、作者和引用字段；编辑会自动保存", "作者使用分号分隔，文献类型决定常用引用字段", "更多字段和高级字段支持固定字段、自定义字段", "标注页可刷新 PDF 中的高亮、批注和图形标注，并导出提取结果"]),
            .tip("元数据刷新和文件整理在后台执行。进度区可以取消操作；已经完成的项目会保留。")
        ]),
        .init(id: "files", title: "PaperManager 文件库", symbol: "folder", heading: "PaperManager 文件库", blocks: [
            .paragraph("在“设置 → 通用”中选择并授权文件库。它是整理文件、浏览器保存、Zotero 复制及恢复流程使用的统一位置。"),
            .bullets(["更改文件夹只影响今后的文件操作，已有文件保留原位置", "放入文件库的文件不会自动导入文献库", "也可以选择“将本地文件保留在原位置”，继续链接原文件"]),
            .heading("本地文件操作"),
            .bullets(["不做任何处理：保留原文件位置并建立链接", "复制：将文件复制到文件库，保留来源文件", "移动：将文件移到文件库；移动或复制前的确认可在更多选项中调整"]),
            .tip("已配置文件库时，浏览器保存、Zotero 复制和显式整理可以使用它，即使本地文件操作设为“不做任何处理”。"),
            .heading("文件布局与分组"),
            .bullets(["分开：主 PDF 和其他附件分别管理", "按文献：将每篇文献的主 PDF 与附件放在一个文件夹中", "可按年份、第一作者姓氏首字母或文集路径分组", "设置中的“应用到现有文献的文件…”会启动后台整理，可以查看进度并取消"]),
            .heading("重命名规则"),
            .code("{year} - {authEtAl} - {title:50}"),
            .paragraph("自动重命名使用设置中的格式。文献右键菜单还提供单独的按规则重命名和整理文件操作。"),
            .heading("附件与删除"),
            .bullets(["展开文献可查看附件，右键可以打开、快速预览、在访达中显示或移除关联", "删除文献时是否将自有附件移入废纸篓，由通用设置中的开关决定", "只读引用的 Lattice 来源文件保留原位置，整理、重命名和删除不会修改它们"])
        ]),
        .init(id: "citations", title: "引用相关", symbol: "key", heading: "Citekey 格式", blocks: [
            .paragraph("在“设置 → 引用”中配置引用键格式，并查看实时示例。"),
            .table(["变量", "说明", "示例"], [["{auth}", "第一作者姓氏（小写）", "einstein"], ["{author}", "第一作者姓氏（首字母大写）", "Einstein"], ["{year}", "完整发表年份", "1905"], ["{year2}", "两位年份", "05"], ["{titleWord}", "标题第一个有意义的词", "relativity"]]),
            .bullets(["文献的引用键用于显示、复制、搜索和导出", "修改格式或相关标题、作者、年份后，引用键会随之更新", "重复引用键会添加后缀，保持文库内唯一"]),
            .code("{auth}{year} → einstein1905"),
            .heading("导出字段"),
            .paragraph("四个独立复选框控制 BibTeX 和 RIS 是否包含摘要、标签关键词、备注和自定义字段。其他所有非空字段始终导出。"),
            .tip("导出字段开关只影响导出内容，不会删除或修改文献的元数据。")
        ]),
        .init(id: "export", title: "导出数据", symbol: "square.and.arrow.up", heading: "导出 BibTeX", blocks: [
            .paragraph("选中文献后，通过工具栏的导出按钮或按 ⌘E 保存 .bib 文件。导出菜单也提供 RIS 和复制到剪贴板。"),
            .bullets(["引用键使用文献当前维护的值", "BibTeX 和 RIS 共用“设置 → 引用”中的四项导出字段开关", "文献右键菜单可以直接复制 BibTeX、RIS 或详细文本"]),
            .tip("只想快速粘贴引用时，选中一篇或多篇文献，使用右键菜单中的复制操作。"),
            .heading("详细导出"),
            .paragraph("在工具栏导出菜单中选择“详细导出…”，再选择输出文件夹。每篇文献生成独立文件。"),
            .bullets(["没有标注图片时生成 .md 文件；有标注图片时生成 .textbundle", "内容由当前元数据模板和标注模板共同渲染", "文件名使用引用键，重名时自动追加编号", "遇到不可访问的标注图片等问题，会报告具体原因"]),
            .link("模板设置", "templates")
        ]),
        .init(id: "templates", title: "模板", symbol: "doc.text", heading: "概述", blocks: [
            .bullets(["模板用于详细导出和检查器中的输出预览", "两套独立正文：整篇文献的元数据模板，以及每条标注的标注模板", "在“设置 → 模板”中编辑，右上角按钮恢复默认正文", "展开“模板管理与预览”可选择、新建、复制、重命名或删除元数据模板"]),
            .heading("语法"),
            .table(["语法", "说明"], [["{{variable}}", "输出字段值，空字段输出空字符串"], ["{{#field}}…{{/field}}", "仅在 field 非空时输出块内内容，支持嵌套"]]),
            .paragraph("例如，仅在存在摘要时输出 Abstract 标题和正文："),
            .code("{{#abstract}}\n## Abstract\n{{abstract}}\n{{/abstract}}"),
            .heading("元数据模板变量"),
            .table(["变量", "说明"], [["{{title}}", "文献标题"], ["{{authors}}", "作者列表"], ["{{year}}", "发表年份"], ["{{journal}}", "期刊/来源"], ["{{doi}} / {{isbn}}", "DOI / ISBN"], ["{{abstract}} / {{notes}}", "摘要 / 备注"], ["{{citekey}} / {{bibtexKey}}", "引用键"], ["{{collections}}", "文集名称"], ["{{collectionPaths}}", "完整层级文集路径"], ["{{tags}}", "标签名称"], ["{{latticeURL}}", "指向当前文献的 PaperManager 链接"], ["{{pdfURL}}", "主 PDF 文件链接"], ["{{annotations}}", "标注模板渲染的内容"]]),
            .tip("层级文集路径使用 {{collectionPaths}}，保留旧模板变量 {{latticeURL}} 会生成 papermanager://paper/ 链接。"),
            .heading("标注模板变量"),
            .table(["变量", "说明"], [["{{type}}", "标注类型"], ["{{page}} / {{pageLabel}}", "页码 / 页标签"], ["{{selectedText}}", "选中文本"], ["{{note}}", "用户批注"], ["{{color}}", "标注颜色"], ["{{image}}", "标注图片路径"]])
        ]),
        .init(id: "backup", title: "备份与恢复", symbol: "archivebox", heading: "备份与恢复", blocks: [
            .paragraph("PaperManager 把文献元数据、标注、标签和文集保存在本地文库。备份导出为 .papermanager 归档，可用于迁移或恢复。"),
            .heading("创建备份"),
            .paragraph("前往“设置 → 备份”，点击“备份”并选择保存位置。开启“包含已链接的 PDF 和附件”时，归档会包含可访问文件的副本。"),
            .tip("不包含附件时，备份只保存文库数据，已有文件仍依赖原位置。"),
            .heading("从备份恢复"),
            .paragraph("点击“恢复”并选择备份。确认后，归档内容会替换当前文库；恢复前会保留一份当前文库的安全副本。"),
            .paragraph("“更多备份选项与文库信息”还提供专门的 Lattice 备份恢复入口，以及当前文库数量和文件位置。"),
            .heading("Zotero 迁移"),
            .paragraph("选择包含 zotero.sqlite 的数据文件夹，先读取并检查文献、文集、笔记和标注的迁移预览。"),
            .bullets(["默认只迁移元数据；复制 PDF 和外部链接文件需要分别选择", "复制 PDF 使用已授权的 PaperManager 文件库", "源 Zotero 数据和 PDF 保留原位置，不会被移动或删除", "文件库不可访问或存在旧路径冲突时，先在通用设置中处理"])
        ]),
        .init(id: "shortcuts-actions", title: "快捷指令", symbol: "iphone", heading: "导出文献元数据", blocks: [
            .paragraph("“导出文献元数据”需要使用完整 Apple 工具链生成快捷指令元数据后，才能由系统发现。当前安装版尚未验证系统发现；若快捷指令中没有此操作，请使用下方的脚本或链接方式。"),
            .bullets(["输出模式可以返回文本，或复制到剪贴板；默认为复制到剪贴板", "包含标注选项控制是否附带标注正文，图片标注使用文字占位符", "未选择模板时使用当前元数据模板，原文献和模板不会被修改"]),
            .tip("可以把返回的文本传给下一步操作，组合成自己的研究笔记流程。"),
            .heading("脚本与链接"),
            .paragraph("也可以组合“运行 Shell 脚本”和“打开 URL”，调用本地命令行或定位已有文献。"),
            .heading("查询文献元数据"),
            .paragraph("保持 PaperManager 运行并开启本地 API，再在 Shell 脚本中调用应用内的命令行工具。下面的查询不会修改文库。"),
            .code("\"$HOME/Applications/PaperManager.app/Contents/Helpers/PaperManagerCLI\" --read-only search --query \"attention\" --limit 5"),
            .paragraph("结果是 JSON，可以传给后续快捷指令操作。使用 get-paper --id <UUID> 获取文献详情；使用 get-csl-item --reference <UUID或引用键> 获取 CSL 元数据。"),
            .tip("客户端端口需要与“设置 → 集成”一致。使用非默认端口时，添加 --port 参数。"),
            .heading("打开已有文献"),
            .code("papermanager://paper/<paper-uuid>"),
            .paragraph("在“打开 URL”中传入文库中已有文献的 UUID，即可在 PaperManager 中选中它。元数据模板的 {{latticeURL}} 变量也会生成这种链接。"),
            .link("查看本地 API", "api")
        ]),
        .init(id: "api", title: "本地 API", symbol: "globe", heading: "概述", blocks: [
            .paragraph("PaperManager 提供本机 HTTP 接口，供脚本、命令行、MCP 和浏览器连接器查询文献及提交导入。"),
            .bullets(["在“设置 → 集成 → 本地 API”中启用或关闭服务", "监听地址为 127.0.0.1，端口以设置中的当前值为准", "API 端点位于 /api/v1 下，返回 JSON", "只读模式会禁止写入请求；查询文献不需要关闭只读模式"]),
            .link("打开浏览器扩展帮助", "browser"),
            .heading("基础地址"),
            .code("http://127.0.0.1:29467/api/v1"),
            .tip("修改端口后，同时更新外部客户端或浏览器连接器的配置。"),
            .heading("端点列表"),
            .table(["路径", "说明"], [["GET /status", "版本、功能和文件库状态"], ["GET /search?q=<query>&limit=<n>", "搜索文献"], ["GET /papers/<uuid>", "文献详情和 CSL 元数据"], ["GET /papers/by-citekey?key=<key>", "按引用键查询文献"], ["GET /collections", "文集列表"], ["GET /tags", "标签列表"], ["POST /papers", "创建文献，需允许写入"], ["PUT /papers/<uuid>/pdf", "附加 PDF，需允许写入并有可用文件库"]]),
            .heading("示例"),
            .code("curl \"http://127.0.0.1:29467/api/v1/status\"\n\ncurl \"http://127.0.0.1:29467/api/v1/search?q=attention&limit=5\""),
            .heading("AI 集成"),
            .paragraph("在“设置 → 集成”中打开 MCP 配置说明，或导出 Agent Skill。导出的连接配置使用当前端口，并默认只读。")
        ]),
        .init(id: "browser", title: "浏览器扩展", symbol: "puzzlepiece.extension", heading: "浏览器扩展", blocks: [
            .paragraph("PaperManager Connector 可读取当前网页的引用元数据，预览和编辑后保存到文库。先开启本地 API，并在连接器中使用相同端口。"),
            .bullets(["通过“设置 → 集成 → 更多集成选项 → 显示浏览器扩展…”找到随应用提供的扩展源码", "在开发者控制的 Chrome 或 Edge 中手动加载该文件夹；应用不会自动安装或授权扩展", "保存前可以编辑元数据，并选择多个文集和标签", "重复文献默认跳过；替换元数据和替换主 PDF 是独立选择", "上传 PDF 为可选操作；跨站 PDF 可先下载，再选择本地文件", "文件库不可用时可只保存元数据；旧路径冲突需要先在通用设置中解决", "只读模式会阻止创建文献和上传 PDF"]),
            .tip("扩展使用当前标签页授权。修改端口后，请同步修改连接器配置；不要把源代码文件夹当作已经启用的 Safari 扩展。"),
            .link("查看本地 API", "api")
        ]),
        .init(id: "shortcuts", title: "快捷键", symbol: "keyboard", heading: "快捷键", blocks: [
            .table(["快捷键", "操作"], [["⌘?", "打开手册"], ["⌘I", "导入文件"], ["⇧⌘D", "通过标识符添加"], ["⌘N", "新建窗口"], ["⌘E", "导出 BibTeX"], ["⌘,", "设置"], ["⌘F", "搜索文献"], ["⌃⌘S", "切换文库侧栏"], ["⌥⌘I", "切换检查器"], ["Return / Enter", "打开选中 PDF"], ["Space", "快速预览 PDF"], ["Delete / ⌫", "删除所选文献"], ["Escape", "取消或关闭对话框"]]),
            .tip("回车、空格和删除键的文献操作仅在列表获得焦点时生效；在文本输入框中用于正常编辑。")
        ]),
        .init(id: "support", title: "支持", symbol: "questionmark.circle", heading: "问题排查", blocks: [
            .paragraph("反馈问题时，请说明触发步骤、期望结果和实际结果，并附上 PaperManager 与 macOS 的版本。"),
            .tip("截图前可遮挡文献中的私密内容。不要为排查问题删除或覆盖原始文库。"),
            .heading("版本信息"),
            .diagnostics,
            .heading("常见问题"),
            .bullets(["PDF 无法打开：检查原文件是否仍在记录的位置，并尝试重新关联附件", "在线补全失败：检查网络和标识符，稍后可重新刷新元数据", "连接器无法连接：确认应用运行、本地 API 已启用且端口一致", "文件库不可访问：在通用设置中重新授权文件夹", "恢复或迁移前，先创建包含所需附件的备份"]),
            .link("备份与恢复", "backup")
        ])
    ]
}

private struct NativeHelpContainer: NSViewControllerRepresentable {
    @Binding var selection: String
    let detail: AnyView

    func makeNSViewController(context: Context) -> NativeHelpSplitController {
        NativeHelpSplitController(selection: $selection, detail: detail)
    }

    func updateNSViewController(_ controller: NativeHelpSplitController, context: Context) {
        controller.update(selection: $selection, detail: detail)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NativeHelpSplitController, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

private final class NativeHelpSplitController: NSSplitViewController {
    private let navigation = NativeHelpSidebarController()
    private let detail: NSHostingController<AnyView>

    init(selection: Binding<String>, detail: AnyView) {
        self.detail = NSHostingController(rootView: detail)
        self.detail.sizingOptions = []
        self.detail.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
        navigation.selection = selection
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = nil
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigation)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 200
        sidebar.canCollapse = false
        addSplitViewItem(sidebar)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
    }

    func update(selection: Binding<String>, detail: AnyView) {
        navigation.selection = selection
        navigation.reloadTopics()
        self.detail.rootView = detail
    }
}

private final class NativeHelpSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var selection: Binding<String>?
    private let table = NSTableView()

    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .sidebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.delegate = self
        table.dataSource = self
        let column = NSTableColumn(identifier: .init("help-topic"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        material.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 52),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12)
        ])
        view = material
        selectCurrentTopic()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { PaperManagerHelpTopic.all.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HelpNavigationRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard PaperManagerHelpTopic.all.indices.contains(row) else { return nil }
        let topic = PaperManagerHelpTopic.all[row]
        let title = PMLocalization.text(topic.title)
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: topic.symbol, accessibilityDescription: title) ?? NSImage())
        image.translatesAutoresizingMaskIntoConstraints = false
        image.contentTintColor = .systemBlue
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        cell.addSubview(image)
        cell.addSubview(label)
        cell.imageView = image
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard PaperManagerHelpTopic.all.indices.contains(table.selectedRow), let selection else { return }
        let id = PaperManagerHelpTopic.all[table.selectedRow].id
        if selection.wrappedValue != id { selection.wrappedValue = id }
    }

    private func selectCurrentTopic() {
        guard isViewLoaded, let selection,
              let row = PaperManagerHelpTopic.all.firstIndex(where: { $0.id == selection.wrappedValue }), row != table.selectedRow else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func reloadTopics() {
        guard isViewLoaded else { return }
        table.reloadData()
        selectCurrentTopic()
    }
}

private final class HelpNavigationRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}

struct PaperManagerWelcomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var step = 0
    var onImportFirst: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    private let pages: [(symbol: String, title: String, text: String, points: [String])] = [
        ("sparkles", "欢迎使用 PaperManager", "一款为 macOS 而生的文献管理器。", [
            "在原生三栏窗口中管理文献、附件和阅读笔记",
            "将 PDF 保存在你可控的文件夹中，并保留来源文件的选择",
            "通过命令行、本地 API 和 MCP 接入现有工作流"
        ]),
        ("square.and.arrow.down", "几秒钟导入文献", "导入单个 PDF 或整个文件夹，让 PaperManager 扫描处理。", [
            "一次性导入 PDF、BibTeX、RIS，或整个文件夹",
            "文件夹中的子文件夹也会一同扫描",
            "在“设置 → 备份”中使用 Zotero 迁移导入现有文库",
            "拖入文件、按标识符查找，或手动新建一条"
        ]),
        ("tray.full", "设置你的 PaperManager 文件库", "在掌控文件存放位置的同时，让文献和 PDF 保持井然有序。", [
            "在通用设置中选择并授权一个文件夹作为文件库",
            "可按年份、文集或作者首字母整理文件",
            "复制、移动和自动重命名规则由你选择",
            "你可以暂时跳过设置，现有文件保留原位置"
        ]),
        ("highlighter", "搭建你的研究工作流", "将高亮转换为适合你工作流的笔记和元数据。", [
            "从已关联的 PDF 中提取高亮和标注",
            "“详细导出”将文献及其标注导出为 Markdown 或 TextBundle",
            "使用模板调整笔记内容，或复制引用数据到其他应用"
        ]),
        ("square.and.arrow.up", "导出你需要的内容", "以标准格式分享参考文献，或即时复制。", [
            "选中文献后导出 BibTeX、RIS 或详细文本",
            "无需先保存文件，一键复制引用数据",
            "随时打开 PaperManager 手册查看分步指南"
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(PMLocalization.text("导览"))
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .frame(height: 24, alignment: .top)
                Spacer()
                Text(verbatim: "\(step + 1) / \(pages.count)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: -1)
                    .accessibilityIdentifier("welcome-step")
            }
            .frame(height: 24)
            ProgressView(value: Double(step + 1), total: Double(pages.count))
                .progressViewStyle(.linear)
                .frame(height: 8)
                .padding(.top, 16)

            HStack(alignment: .center, spacing: 14) {
                Image(systemName: pages[step].symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(PMLocalization.text(pages[step].title)).font(.system(size: 15, weight: .bold))
                    Text(PMLocalization.text(pages[step].text))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .offset(y: -5)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 52)
            .padding(.top, 26)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(pages[step].points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.blue).frame(width: 12).padding(.top, 2)
                        Text(PMLocalization.text(point)).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(6)
            .padding(.horizontal, 18)
            .padding(.top, 36.5)

            if step == 2 {
                fileLibraryWelcomeStatus.padding(.top, 26)
            }
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                if step == pages.count - 1 {
                    Button(PMLocalization.text("打开 PaperManager 手册")) {
                        openWindow(id: PaperManagerAuxiliaryWindow.help)
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button(PMLocalization.text("完成"), action: close)
                    if let onImportFirst {
                        Button(PMLocalization.text("导入第一篇文献")) {
                            close()
                            onImportFirst()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("welcome-import-first")
                    }
                } else {
                    Button(PMLocalization.text(step == 0 ? "关闭" : "返回")) {
                        if step == 0 { close() } else { step -= 1 }
                    }
                    Spacer()
                    Button(PMLocalization.text("继续")) { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("welcome-continue")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 640, height: 510)
    }

    @ViewBuilder
    private var fileLibraryWelcomeStatus: some View {
        let status = FileLibraryService.status(for: store.settings)
        if status.isAvailable {
            Label(PMLocalization.text("已配置 PaperManager 文件库。"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.green)
        } else {
            HStack {
                Button(PMLocalization.text("选择文件库…")) {
                    SettingsWindowCoordinator.shared.show(pane: "general")
                }
                Text(status.availability.label).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func close() {
        if let onClose { onClose() }
        else {
            dismiss()
            dismissWindow(id: PaperManagerAuxiliaryWindow.welcome)
        }
    }
}

struct PaperManagerWhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    var onOpenIntegrations: (() -> Void)? = nil
    var onOpenFileLayout: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "What's new")
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .frame(height: 24, alignment: .top)
                Spacer()
                Text(verbatim: "\(step + 1) / 2")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(y: -1)
            }
            .frame(height: 24)
            ProgressView(value: Double(step + 1), total: 2)
                .progressViewStyle(.linear)
                .frame(height: 8)
                .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: step == 0 ? "sparkles.rectangle.stack" : "folder.badge.gearshape")
                            .font(.system(size: 24)).foregroundStyle(.secondary)
                            .frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 9.5) {
                            Text(PMLocalization.text(step == 0 ? "AI × PaperManager" : "附件，归入 PaperManager 文件库"))
                                .font(.system(size: 14, weight: .bold))
                            Text(PMLocalization.text(step == 0
                                ? "PaperManagerCLI connects agents to your library via Skill or MCP."
                                : "PDF 与附件可分开存放，也可按文献归入同一文件夹。"))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .offset(y: -4)
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Spacer()
                        if let action = step == 0 ? onOpenIntegrations : onOpenFileLayout {
                            Button(PMLocalization.text(step == 0 ? "查看 AI 集成 →" : "查看文件布局 →"), action: action)
                                .buttonStyle(.link)
                        } else {
                            Button(PMLocalization.text(step == 0 ? "查看 AI 集成 →" : "查看文件布局 →")) {
                                SettingsWindowCoordinator.shared.show(pane: step == 0 ? "localAPI" : "general")
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(height: 24)
                    .padding(.top, 16.5)
                }
            }
            .padding(.top, 26)
            Spacer(minLength: 12)
            HStack {
                Button(PMLocalization.text(step == 0 ? "关闭" : "返回")) {
                    if step == 0 { close() } else { step = 0 }
                }
                .accessibilityIdentifier("whatsNew.backOrClose")
                Spacer()
                Button(PMLocalization.text(step == 0 ? "继续" : "完成")) {
                    if step == 0 { step = 1 } else { close() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(step == 0 ? "whatsNew.continue" : "whatsNew.done")
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 580, height: 340)
    }

    private func close() {
        if let onClose { onClose() }
        else {
            dismiss()
            dismissWindow(id: PaperManagerAuxiliaryWindow.whatsNew)
        }
    }
}
