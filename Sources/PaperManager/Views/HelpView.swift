import SwiftUI

enum PaperManagerAuxiliaryWindow {
    static let help = "papermanager-help"
    static let welcome = "papermanager-welcome"
    static let whatsNew = "papermanager-whats-new"
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
    @State private var selectedTopic: String? = "getting-started"
    @State private var search = ""

    private var filteredTopics: [PaperManagerHelpTopic] {
        guard !search.trimmed.isEmpty else { return PaperManagerHelpTopic.all }
        return PaperManagerHelpTopic.all.filter { topic in
            ([topic.title, PMLocalization.text(topic.title)] + topic.paragraphs + topic.paragraphs.map { PMLocalization.text($0) })
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var topic: PaperManagerHelpTopic? {
        filteredTopics.first { $0.id == selectedTopic } ?? filteredTopics.first
    }

    var body: some View {
        NavigationSplitView {
            List(filteredTopics, selection: $selectedTopic) { topic in
                Label(PMLocalization.text(topic.title), systemImage: topic.symbol).tag(topic.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $search, prompt: Text(PMLocalization.text("搜索帮助")))
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            ScrollView {
                if let topic {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(PMLocalization.text(topic.title), systemImage: topic.symbol)
                            .font(.title2.bold())
                        ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, text in
                            Text(PMLocalization.text(text)).fixedSize(horizontal: false, vertical: true)
                        }
                        if !topic.shortcuts.isEmpty {
                            Divider()
                            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                                ForEach(topic.shortcuts, id: \.action) { shortcut in
                                    GridRow {
                                        Text(PMLocalization.text(shortcut.action))
                                        Text(PMLocalization.text(shortcut.keys)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(28)
                    .textSelection(.enabled)
                } else {
                    ContentUnavailableView.search(text: search)
                        .padding(30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 500)
    }
}

private struct PaperManagerHelpTopic: Identifiable {
    struct Shortcut { let action: String; let keys: String }
    let id: String
    let title: String
    let symbol: String
    let paragraphs: [String]
    var shortcuts: [Shortcut] = []

    static let all: [PaperManagerHelpTopic] = [
        .init(id: "getting-started", title: "开始使用", symbol: "books.vertical", paragraphs: [
            "PaperManager 把文库、文献列表和检查器放在同一个窗口。左侧选择文集或标签，中间选择文献，右侧查看和编辑详细信息。",
            "使用工具栏的添加按钮，通过标识符查找文献，或手动建立一条记录。已有文件可以通过“文件 → 导入文件…”导入。",
            "工具栏的面板菜单分别控制文库侧栏和论文检查器。新手导览和更新说明可以随时从帮助菜单重新打开。"
        ]),
        .init(id: "import", title: "导入文献", symbol: "square.and.arrow.down", paragraphs: [
            "导入支持 PDF、BibTeX、RIS 和包含这些文件的文件夹。你也可以把文件拖到文献列表。",
            "先查看导入预览，再确认要导入的条目。遇到已有文献时，可以选择跳过、替换或打开已有记录；批量处理时可把同一选择应用到其余冲突。",
            "导入到当前选中的文集或标签时，新记录会加入这个目标。通过标识符添加需要网络连接；缺少可靠标识符时，可以先手动填写标题和作者。"
        ], shortcuts: [.init(action: "导入文件", keys: "⌘I"), .init(action: "通过标识符添加", keys: "⇧⌘D")]),
        .init(id: "collections", title: "文集与标签", symbol: "folder", paragraphs: [
            "一篇文献可以同时属于多个文集和标签。把文献拖到侧栏中的文集或标签，就能添加归属；也可以在检查器的文集和标签区域调整。",
            "文集最多支持三级。右键文集可以新建子文集、重命名、移到顶层或删除。拖动文集可以调整同级顺序，或移到其他文集下；会形成循环或超过三级的移动无法执行。",
            "父文集可选择是否包含子文集的文献。标签可以拖动排序，并通过右键菜单选择预设颜色或输入十六进制颜色。删除文集或标签会解除这些归属，保留文献记录。"
        ]),
        .init(id: "reading", title: "搜索与阅读", symbol: "doc.text.magnifyingglass", paragraphs: [
            "侧栏搜索可按标题、作者、来源和年份等信息查找文献。智能筛选帮助你找到未归类、缺少 PDF 或缺少标识符的记录。",
            "文献列表支持多选、列排序、列宽调整和列顺序调整。右键表头可以选择显示哪些列，并重置列设置。展开一篇文献，可以查看它的 PDF 和其他附件。",
            "在文献列表中，按回车打开 PDF，按空格快速预览。附件行也支持打开、预览和在访达中显示。默认 PDF 阅读器可在设置中更改。"
        ], shortcuts: [.init(action: "搜索文献", keys: "⌘F"), .init(action: "列表中打开 PDF", keys: "↩"), .init(action: "列表中快速预览", keys: "空格")]),
        .init(id: "metadata", title: "编辑与标注", symbol: "sidebar.right", paragraphs: [
            "在检查器中直接编辑标题、作者和引用字段，内容会自动保存。切换文献或退出应用会提交尚未完成自动保存的编辑。引用键根据元数据和设置中的格式更新。",
            "DOI、ISBN 和电子预印本编号独立保存。文献类型决定常用字段；其他已有值仍可在高级字段中编辑。展开更多字段并打开高级字段，可以把常用标准字段固定到更多字段，也可以添加和固定自定义字段。",
            "摘要、备注、评分、文集和标签都可以在检查器中维护。标注页可刷新已关联 PDF 中的高亮和批注，并将提取结果导出为文本。"
        ]),
        .init(id: "files", title: "文件库与附件", symbol: "externaldrive", paragraphs: [
            "文献记录和磁盘上的文件分别管理。你可以保留文件原位置，也可以在“设置 → 通用 → 文件库”中选择统一位置，设置复制或移动规则、分组和文件布局。",
            "更改文件库设置用于今后的操作。要处理已有附件，使用设置中的“应用到现有文献的文件…”或文献右键菜单中的整理操作。单独重命名可以使用右键菜单中的“按规则重命名文件…”。",
            "标记为只读引用的 Lattice 原文件保留在原位置，避免被整理、重命名或删除操作改动。替换主 PDF 会保留原有附件记录。删除文献时是否将自有附件移到废纸篓，由设置中的选项决定。"
        ]),
        .init(id: "export", title: "导出与模板", symbol: "square.and.arrow.up", paragraphs: [
            "选中文献后，从工具栏导出菜单或右键菜单导出 BibTeX、RIS 和详细文本。导出菜单也提供复制到剪贴板的操作。",
            "引用设置控制是否导出摘要、标签关键词、备注和自定义字段。其他非空的基本书目信息会随文献导出。引用键格式和元数据模板可以在设置中修改。",
            "详细文本使用当前元数据模板；包含标注时，标注内容使用标注模板。可以先在设置或检查器中的输出预览里检查结果。",
            "在“设置 → 模板”中选择、新建、复制、重命名或删除元数据模板。正文中的变量和条件块按文献内容渲染；恢复默认只重置当前正文，标注模板单独维护。"
        ], shortcuts: [.init(action: "导出 BibTeX", keys: "⌘E")]),
        .init(id: "backup", title: "备份与恢复", symbol: "clock.arrow.circlepath", paragraphs: [
            "在设置的备份页面导出 .papermanager 文库备份。启用“包含已链接的 PDF 和附件”后，备份会携带可访问的文件，便于迁移到其他位置。",
            "恢复备份会替换当前文库。请先检查目标文库并保留需要的数据，再选择备份文件恢复。文件无法访问时，查看操作结果中的提示。",
            "Lattice 备份使用专门的恢复入口；从 Lattice 读取元数据和恢复完整备份是两个不同操作。仅保存元数据的旧备份仍依赖其记录中的文件位置。",
            "从 Zotero 导入时，选择包含 zotero.sqlite 的数据文件夹，先读取并检查迁移预览。默认只导入元数据；复制 PDF 和外部链接文件分别需要明确选择，Zotero 原文件不会被移动或删除。"
        ]),
        .init(id: "automation", title: "本地 API", symbol: "network", paragraphs: [
            "在“设置 → 集成”的本地 API 页面启用服务后，本地连接器和命令行可以查询文库、读取文献和提交导入。页面会显示当前监听地址和运行状态。",
            "只读模式适合只查询文献的工具。需要添加或更新记录时，先关闭只读模式；不使用集成时可以关闭服务。",
            "浏览器和命令行添加的文件与本地导入共用已配置的文件库规则。API 操作结果会提示重复记录、未匹配的文集和文件处理情况。",
            "快捷指令中的“导出文献元数据”可选择文献和模板，并返回文本或复制到剪贴板。不指定模板时使用当前模板；标注内容由独立的包含标注选项控制。"
        ]),
        .init(id: "shortcuts", title: "键盘与窗口", symbol: "keyboard", paragraphs: [
            "文件和文库菜单的操作应用到当前活动的文库窗口。你可以打开多个窗口，在不同文集或搜索结果间工作。",
            "回车、空格和删除键的文献操作在列表获得焦点时生效；在文本字段中，这些按键用于正常编辑。面板显示状态可以从工具栏面板菜单或显示菜单调整。"
        ], shortcuts: [.init(action: "导入文件", keys: "⌘I"), .init(action: "搜索文献", keys: "⌘F"),
                       .init(action: "切换文库侧栏", keys: "⌃⌘S"), .init(action: "切换论文检查器", keys: "⌥⌘I"),
                       .init(action: "打开帮助", keys: "⌘?")])
    ]
}

struct PaperManagerWelcomeView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    private let pages: [(symbol: String, title: String, text: String, points: [String])] = [
        ("square.and.arrow.down", "建立你的文库", "从已有文件开始，或手动记录一篇文献。", [
            "按 ⌘I 导入 PDF、BibTeX、RIS 或文件夹。",
            "在预览中检查条目，决定如何处理重复记录。",
            "工具栏添加菜单支持标识符查找和手动添加。"
        ]),
        ("folder", "组织与阅读", "在文集、标签和文献列表之间完成日常整理。", [
            "把文献拖到文集或标签；文集支持三级层次。",
            "拖动文集和标签排序，右键标签调整颜色。",
            "在列表中按回车打开 PDF，按空格快速预览。"
        ]),
        ("pencil.and.list.clipboard", "记录与保存", "阅读时维护引用信息、笔记和标注。", [
            "检查器中的编辑自动保存，无需点击保存按钮。",
            "在高级字段中固定常用字段，或添加自定义字段。",
            "到设置中配置文件库，并定期导出带附件的备份。"
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "books.vertical").font(.system(size: 36)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(PMLocalization.text("欢迎使用 PaperManager")).font(.title.bold())
                    Text(PMLocalization.text("让文献、文件和阅读记录放在一起。")).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Label(PMLocalization.text(pages[step].title), systemImage: pages[step].symbol).font(.title2.bold())
                Text(PMLocalization.text(pages[step].text)).foregroundStyle(.secondary)
                ForEach(pages[step].points, id: \.self) { point in
                    Label(PMLocalization.text(point), systemImage: "checkmark.circle").fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Button(PMLocalization.text("稍后再看")) { dismissWindow(id: PaperManagerAuxiliaryWindow.welcome) }
                Spacer()
                Text(verbatim: "\(step + 1) / \(pages.count)").foregroundStyle(.secondary).monospacedDigit()
                if step > 0 { Button(PMLocalization.text("上一步")) { step -= 1 } }
                Button(PMLocalization.text(step == pages.count - 1 ? "开始使用" : "下一步")) {
                    if step == pages.count - 1 { dismissWindow(id: PaperManagerAuxiliaryWindow.welcome) }
                    else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 660, height: 480)
    }
}

struct PaperManagerWhatsNewView: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(PMLocalization.text("本次更新")).font(.largeTitle.bold())
            Text(PMLocalization.text("PaperManager 原生文库体验")).font(.headline).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    update("sidebar.left", title: "原生三栏与多窗口", text: "文库侧栏、文献表格和检查器使用原生窗口组件；菜单操作跟随当前文库窗口。")
                    update("text.badge.checkmark", title: "完整引用字段", text: "独立 DOI、ISBN 和预印本编号，15 种文献类型，高级字段、自定义字段和固定字段。")
                    update("folder.badge.gearshape", title: "整理与文件管理", text: "文集层级和标签拖动排序、自定义标签颜色，以及文件库整理和单独重命名。")
                    update("clock.arrow.circlepath", title: "导入与备份", text: "确认导入前预览重复记录；可选择把 PDF 和附件一起放进文库备份。")
                    update("globe", title: "双语与多模板", text: "界面和帮助可跟随系统或使用简体中文、English；元数据模板支持保存多套内容，并在导出和快捷指令中选择。")
                }
                .padding(.vertical, 4)
            }
            HStack {
                Text(PMLocalization.text("帮助菜单中可以重新打开导览和使用说明。"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(PMLocalization.text("完成")) { dismissWindow(id: PaperManagerAuxiliaryWindow.whatsNew) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 500)
    }

    private func update(_ symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(PMLocalization.text(title)).font(.headline)
                Text(PMLocalization.text(text)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
