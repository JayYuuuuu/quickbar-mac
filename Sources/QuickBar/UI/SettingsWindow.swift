import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗。非性能路径，用 SwiftUI 省一半代码。
final class SettingsWindowController: NSWindowController {

    convenience init(section: SettingsSection = .items) {
        let hosting = NSHostingController(rootView: SettingsView(initialSection: section))
        let window = NSWindow(contentViewController: hosting)
        window.title = "QuickBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 520))
        window.minSize = NSSize(width: 640, height: 460)
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case items, material, trigger, permissions, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .items: return "条目"
        case .material: return "素材批次"
        case .trigger: return "触发"
        case .permissions: return "权限"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .items: return "folder"
        case .material: return "shippingbox"
        case .trigger: return "cursorarrow.click.2"
        case .permissions: return "lock.shield"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var store = Store.shared
    @State private var section: SettingsSection
    @State private var missingPermissions = Permissions.Kind.allCases.filter { !Permissions.isGranted($0) }

    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(initialSection: SettingsSection) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            // 刻意不用 NavigationSplitView：它的侧边栏能拖到折叠，
            // 而恢复它要靠「显示」菜单——后台程序没有菜单栏，折叠了就回不来了。
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SidebarRow(
                        section: item,
                        selected: section == item,
                        // 只有必需的三项缺了才点橙点；通知是可选的，不该常驻一个警告。
                        warning: item == .permissions && missingPermissions.contains { $0.isRequired }
                    ) { section = item }
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 172)
            .background(VisualEffect(material: .sidebar))

            Divider()

            Group {
                switch section {
                case .items: ItemsPane(store: store)
                case .material: MaterialPane(store: store)
                case .trigger: TriggerPane(store: store)
                case .permissions: PermissionsPane(missing: $missingPermissions)
                case .general: GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onReceive(heartbeat) { _ in
            missingPermissions = Permissions.Kind.allCases.filter { !Permissions.isGranted($0) }
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let warning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .frame(width: 17)
                Text(section.title)
                Spacer()
                if warning {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 侧边栏那层材质，SwiftUI 没有等价物，包一下原生的。
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - 条目

private struct ItemsPane: View {
    @ObservedObject var store: Store
    @State private var selection = Set<QuickItem.ID>()
    @State private var unavailable = 0

    var body: some View {
        VStack(spacing: 0) {
            // 设计稿 2a：一行结论（条目总数）+ 右侧一句「怎么排序」，没有别的说明文字。
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("快捷条里的条目 · \(store.items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("\(store.folders.count) 个文件夹 · \(store.apps.count) 个应用。快捷条按这个顺序显示。")
                if unavailable > 0 {
                    Text("\(unavailable) 项找不到")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                        .help("外置盘没接上时也会这样。QuickBar 只标记不删除，接回去就恢复。")
                }
                Spacer()
                Text("拖动排序")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .help("拖动行首那个把手就能排序，顺序即快捷条里的顺序。")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 9)

            List(selection: $selection) {
                ForEach($store.items) { $item in
                    ItemRow(item: $item)
                        .tag(item.id)
                }
                .onMove { source, destination in
                    store.items.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { store.items.remove(atOffsets: $0) }
            }
            .listStyle(.bordered)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 20)
            .onDeleteCommand(perform: removeSelected)

            // 设计稿 2a：底下是两个写清楚的按钮，不是 ＋/－ 图标 ——
            // 「＋」要人猜点了会怎样，而这里本来就有地方把话写完。
            HStack(spacing: 8) {
                Button("添加文件夹…") { addFolder() }
                Button("添加应用…") { addApp() }
                Button("移除") { removeSelected() }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("也可以把文件夹或应用直接拖进来")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .onAppear { Availability.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .quickBarAvailabilityChanged)) { _ in
            unavailable = Availability.shared.unavailableCount
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { store.add(url: url) }
                }
            }
            return true
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要加进快捷条的文件夹"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { store.add(url: $0) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加"
        panel.message = "选择要加进快捷条的应用"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { store.add(url: $0) }
    }

    private func removeSelected() {
        store.items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }
}

private struct ItemRow: View {
    @Binding var item: QuickItem

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isHovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // 把手只是「这一行能拖」的提示 —— SwiftUI 的 List 整行都可拖，
            // 但不给个抓手人根本不会去试（设计稿 2a）。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 11)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 15, height: 15)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .frame(maxWidth: 220)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    // 点到别处也要收尾。少了这条，输入框会永远留在编辑态，
                    // 而编辑态又把悬停按钮藏起来了——结果这一行再也改不了名。
                    .onChange(of: focused) { hasFocus in
                        if !hasFocus, isEditing { commit() }
                    }
            } else {
                Text(item.name)
                    .onTapGesture(count: 2, perform: beginEditing)
                    .help(item.isRenamed ? "原名：\(item.originalName)" : item.path)
            }

            Spacer(minLength: 8)

            // 悬停才出现，平时这一行只有名称和路径（设计稿 2a 的便签）
            if isHovering, !isEditing {
                Button("重命名…", action: beginEditing)
                    .controlSize(.small)
                    .help("只改快捷条上的显示名，不动文件夹本身")
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                .controlSize(.small)
            } else if isEditing {
                Text("↩ 确认 · ⎋ 取消")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else if let note = Availability.shared.state(of: item).label {
                badge(note, .orange)
                    .help("QuickBar 只标记不删除——外置盘接回去就自动恢复。")
            } else if item.kind == .app, Actions.isRunning(item) {
                badge("运行中", .green).help("点它会切到前台，不会新开一个。")
            } else {
                Text(item.compactPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.path)
            }
        }
        .frame(height: 26)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("重命名…", action: beginEditing)
            if item.isRenamed {
                Button("恢复原名「\(item.originalName)」") { item.name = item.originalName }
            }
            Divider()
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    /// 状态徽标：一个词 + 一点底色。比一句话快得多，也不占一整行。
    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }

    private func beginEditing() {
        draft = item.name
        isEditing = true
        // 等 TextField 真正出现再抢焦点，否则这一拍焦点会落空。
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmed.isEmpty ? item.originalName : trimmed
        isEditing = false
    }
}

// MARK: - 触发

private struct TriggerPane: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            Section("唤出快捷条") {
                ForEach(TriggerMode.allCases, id: \.self) { mode in
                    HStack {
                        Button {
                            store.settings.trigger = mode
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: store.settings.trigger == mode
                                      ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(store.settings.trigger == mode ? Color.accentColor : .secondary)
                                Text(mode.label)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(mode.note)

                        Spacer()

                        if mode == .doubleCommand {
                            Text("默认")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        } else if mode == .modifierDoubleClick {
                            Picker("", selection: $store.settings.modifier) {
                                ForEach(TriggerModifier.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 168)
                            .help("按住这个键再双击才会弹出快捷条。")
                        } else if mode == .bareDoubleClick {
                            Text("易误触发")
                                .font(.caption).bold().foregroundStyle(.orange)
                                .help(mode.note)
                        }
                    }
                }
            }

            Section {
                LabeledContent("跳到 Finder 当前文件夹") {
                    Text(KeySymbols.describe(
                        flags: CGEventFlags(rawValue: UInt64(store.settings.jumpModifierFlags)),
                        keyCode: CGKeyCode(store.settings.jumpKeyCode)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .help("只在检测到文件面板时才拦截；其他场合这个键仍然是各应用自己的功能。")
                }
                LabeledContent("在 PS 里存回原位") {
                    Text(KeySymbols.describe(
                        flags: CGEventFlags(rawValue: UInt64(store.settings.psSaveBackModifierFlags)),
                        keyCode: CGKeyCode(store.settings.psSaveBackKeyCode)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .help("把 Photoshop 当前那张拼合、按原路径覆盖存回、关掉。只在 Photoshop 在最前时才拦截。开关在「素材批次」那一页。")
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("固定，不可修改")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .help("这两个键都只在特定场合才拦截（文件面板 / Photoshop 在最前），别处照旧是各应用自己的功能，所以没做成可改的。")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

/// 设计稿 2d：**必需组是实色卡片 + 左侧一条 3pt 状态色条**（三项齐了色条转绿），
/// **可选组是虚线框、没有色条、字也淡**。形态差异本身就说清了「这一项不一样」，
/// 不用再写一句「通知是可选的」。
private struct PermissionsPane: View {
    @Binding var missing: [Permissions.Kind]

    private var missingRequired: Int { missing.filter(\.isRequired).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(missingRequired == 0 ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(missingRequired == 0 ? "全部就绪" : "还差 \(missingRequired) 项授权")
                        .font(.system(size: 17, weight: .semibold))
                }

                group(title: "必需 · 缺一项就不能用", kinds: Permissions.Kind.core, required: true)
                group(title: "可选 · 不影响任何功能",
                      kinds: Permissions.Kind.allCases.filter { !$0.isRequired }, required: false)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func group(title: String, kinds: [Permissions.Kind], required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                if required {
                    // 3pt 状态色条：一眼看出这一组整体到齐没有，不用逐行数
                    Rectangle()
                        .fill(missingRequired == 0 ? Color.green : Color.orange)
                        .frame(width: 3)
                }
                VStack(spacing: 0) {
                    ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Divider() }
                        PermissionRow(kind: kind, granted: !missing.contains(kind))
                    }
                }
            }
            .background(required ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.separator,
                                  style: required ? StrokeStyle(lineWidth: 0.5)
                                                  : StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let granted: Bool

    /// 可选授权（通知）缺了只是灰的，不是橙的——颜色本身就是「这算不算坏」。
    private var missingTint: Color { kind.isRequired ? .orange : .secondary }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(kind.title)
                .font(.system(size: 13))
                .foregroundStyle(kind.isRequired ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer()
            // 状态用徽标不用句子（这个软件的界面规矩）
            Text(granted ? "已授权" : "未授权")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(granted ? Color.green : missingTint)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background((granted ? Color.green : missingTint).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 5))
            if !granted {
                Button("去授权") { Permissions.request(kind) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .help(kind.why)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }
}

// MARK: - 素材批次

/// 对接「AI 电商内容助手」的素材下载单：把最近派的批次目录直接摆到快捷条上。
///
/// 界面上什么都不用填：服务器地址写死在 MaterialFeed.server，口令由 build.sh
/// 构建时内置（见 MaterialFeed.builtInKey）。连不通什么全压在底下那一行状态里，
/// 不在界面上铺说明——真要解释的进 help tip。
private struct MaterialPane: View {

    /// 「存回原位」那个键长什么样。设置里改不了（跟「跳到 Finder 当前」一样是固定键），
    /// 但页面上必须写出来 —— 一个按不出来的快捷键等于没有。
    private var psKey: String {
        KeySymbols.describe(
            flags: CGEventFlags(rawValue: UInt64(store.settings.psSaveBackModifierFlags)),
            keyCode: CGKeyCode(store.settings.psSaveBackKeyCode))
    }

    @ObservedObject var store: Store
    @State private var status = MaterialFeed.shared.statusText
    @State private var age = ""

    var body: some View {
        Form {
            Section {
                Toggle("把最近的素材下载批次放进快捷条", isOn: Binding(
                    get: { store.settings.materialFeedEnabled },
                    set: { store.settings.materialFeedEnabled = $0; MaterialFeed.shared.start() }
                ))
                .help("素材落在 <采集根>/<品牌>/<时间戳_批次>/，每派一单就换一个新目录，手工加书签跟不上，所以由服务器喂。")

                // 正常发布的包口令是构建时内置的，这一栏根本不出现——少一处能填错的地方。
                // 只有自己编的、没内置口令的包才需要手填。
                // 逐字符触发同步会在打字过程中发一串必然 401 的请求，所以只在回车时才试；
                // 不按回车也行，底下「立即同步」是同一个动作。
                if MaterialFeed.builtInKey.isEmpty {
                    SecureField("密码", text: Binding(
                        get: { store.settings.materialFeedKey },
                        set: { store.settings.materialFeedKey = $0 }
                    ))
                    .disabled(!store.settings.materialFeedEnabled)
                    .onSubmit { MaterialFeed.shared.start() }
                    .help("团队内部那一串。它只能读「批次落在哪个目录、下完没有」，派单、重下、回写都够不着。")
                }

                Toggle("下完了通知我", isOn: Binding(
                    get: { store.settings.materialFeedNotify },
                    set: { store.settings.materialFeedNotify = $0 }
                ))
                .disabled(!store.settings.materialFeedEnabled)
                .help("点通知直接在 Finder 里打开那个批次目录。")

                Toggle("在 Finder 侧栏里放一个「\(BatchLinks.dirName)」", isOn: Binding(
                    get: { store.settings.batchLinksEnabled },
                    set: { store.settings.batchLinksEnabled = $0; BatchLinks.sync([]); MaterialFeed.shared.start() }
                ))
                .disabled(!store.settings.materialFeedEnabled)
                .help("在家目录建 ~/\(BatchLinks.dirName)/，里面是最近 12 批的替身，跟着服务器自动更新。把这个目录拖进 Finder 侧栏一次，以后点开就是最新那几批。里面只放替身，删掉不影响真素材。")

            } header: {
                Text("素材批次")
            }

            // 设计稿 2b：去水印那两条单独成节 —— 它们跟上面「把批次放进快捷条」
            // 不是一回事，混在一张卡里读起来像同一组开关。
            Section {
                Toggle("在 Finder 里选中商品文件夹时浮出「主图丢进 PS」", isOn: Binding(
                    get: { store.settings.mainImagesPillEnabled },
                    set: { store.settings.mainImagesPillEnabled = $0; MainImagesPill.shared.reload() }
                ))
                .help("选中之后旁边浮一颗小按钮，点一下那几件的「主图」全部在 Photoshop 里打开（去水印那一步）。只在真的解析出主图时才出现；关掉之后菜单栏那一项照旧能用。")

                Toggle(isOn: Binding(
                    get: { store.settings.psSaveBackEnabled },
                    set: { store.settings.psSaveBackEnabled = $0; MainImagesPill.shared.reload() }
                )) {
                    HStack(spacing: 7) {
                        Text("在 PS 里按 \(psKey) 把改完的这张覆盖存回原位")
                        // 🔴 全软件唯一的资损级提示：**一行、橙色、带边框**，原因全进 tip。
                        //    别再加第二处文字说明（设计稿 2b 的便签）。
                        Text("会覆盖原图")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                            }
                    }
                }
                .help("Photoshop 当前这张会被拼合，按它自己的原始路径覆盖写回，然后关掉——省掉每张都要在存储对话框里翻回 /Volumes/…/批次/商品/主图/ 那一趟，也就不用再记手上这张是哪件商品的。只认 jpg 和 png；这个键只在 Photoshop 在最前时才拦截。原图会被改完的这版替掉，没有撤销。开着的时候 PS 里还会浮出一颗「存回原位 · 还剩 N 张」。")
            } header: {
                Text("去水印工序")
            } footer: {
                HStack(spacing: 8) {
                    Button("立即同步") {
                        MaterialFeed.shared.start()
                    }
                    .disabled(!store.settings.materialFeedEnabled)
                    Button("打开那个目录") { BatchLinks.revealInFinder() }
                        .disabled(!store.settings.materialFeedEnabled || !store.settings.batchLinksEnabled)
                    Spacer()
                    // 一行结论：通道活着没有、手上有几批。别的都进 tip。
                    Text(footerStatus)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .help("同步不成功时这里会写原因；快捷条上那份批次列表照旧用缓存，不会空掉。")
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            status = MaterialFeed.shared.statusText
            age = MaterialPane.age(of: MaterialFeed.shared.lastSyncAt)
        }
    }

    private var footerStatus: String {
        let count = MaterialFeed.shared.items.count
        var text = age.isEmpty ? status : "\(status) · \(age)"
        if count > 0 { text += " · \(count) 个批次" }
        return text
    }

    /// 「多久以前同步的」——比一个绝对时间戳好读，也顺便让人看出通道是不是停了。
    static func age(of date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}

// MARK: - 通用

private struct GeneralPane: View {
    @ObservedObject var store: Store
    @State private var updateStatus = Updater.shared.statusText

    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动，静默运行", isOn: Binding(
                    get: { store.settings.launchAtLogin },
                    set: { store.settings.launchAtLogin = $0; LoginItem.set($0) }
                ))
                .help("用 SMAppService 注册，不写 LaunchAgent 配置文件。")
            }

            Section("文件面板") {
                Toggle("记住文件面板尺寸", isOn: $store.settings.rememberPanelSize)
                    .help("普通面板即时套用；Chrome 这类 sheet 面板由系统偏好承载，下次打开生效。")
                if let size = store.settings.panelSize {
                    // 设计稿 2e：记住的尺寸旁边给一条出路。没有「忘掉」的话，
                    // 想回到系统默认只能去翻配置文件 —— 那等于没有退路。
                    LabeledContent("记住的尺寸") {
                        HStack(spacing: 8) {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                            Button("忘掉") { store.settings.panelSize = nil }
                                .controlSize(.small)
                                .help("忘掉之后面板恢复系统默认尺寸；下次你再拉一次就又记住了。")
                        }
                    }
                }
            }

            Section("Finder 窗口") {
                Toggle("新窗口沿用记住的尺寸", isOn: $store.settings.rememberFinderWindowSize)
                    .help("Finder 的尺寸按文件夹逐个记在 .DS_Store 里，新建的目录和网络卷上的目录没有记录，一律开成 960×492。开着就在这种窗口出现时改成你最后拉过的尺寸，别的尺寸不碰。")
                if let size = store.settings.finderWindowSize {
                    LabeledContent("记住的尺寸") {
                        HStack(spacing: 8) {
                            Text("\(Int(size.width)) × \(Int(size.height))")
                            Button("忘掉") { store.settings.finderWindowSize = nil }
                                .controlSize(.small)
                                .help("忘掉之后新窗口回到 Finder 自己的 960×492；下次你手动拉一次就又记住了。")
                        }
                    }
                } else {
                    LabeledContent("记住的尺寸", value: "还没有")
                        .help("手动拉一次 Finder 窗口就记下来了。")
                }
            }

            Section("更新") {
                Toggle("自动检查更新", isOn: $store.settings.autoUpdate)
                Toggle("静默安装，不打断我", isOn: $store.settings.autoUpdateSilently)
                    .disabled(!store.settings.autoUpdate)
                    .help("下载完直接替换并重启。QuickBar 没有窗口，重启对你是无感的。")
                LabeledContent("当前版本") {
                    HStack(spacing: 8) {
                        Text(Updater.shared.currentVersion)
                        Button("立即检查更新") { Updater.shared.check(userInitiated: true) }
                            .controlSize(.small)
                        Text(updateStatus)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateStatus = Updater.shared.statusText
        }
    }
}
