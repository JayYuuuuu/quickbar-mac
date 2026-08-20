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
    case items, trigger, permissions, general
    var id: String { rawValue }

    var title: String {
        switch self {
        case .items: return "条目"
        case .trigger: return "触发"
        case .permissions: return "权限"
        case .general: return "通用"
        }
    }

    var symbol: String {
        switch self {
        case .items: return "folder"
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
                        warning: item == .permissions && !missingPermissions.isEmpty
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("条目").font(.headline)
                Text("\(store.folders.count) 个文件夹 · \(store.apps.count) 个应用")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("快捷条按这个顺序显示，拖动可以排序。")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

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
            .listStyle(.inset)
            .onDeleteCommand(perform: removeSelected)

            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("添加文件夹…") { addFolder() }
                    Button("添加应用…") { addApp() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 22)
                .help("添加文件夹或应用")

                Button { removeSelected() } label: {
                    Image(systemName: "minus").frame(width: 30, height: 22)
                }
                .disabled(selection.isEmpty)
                .help("移除选中的条目")

                Spacer()
                Text("也可以把文件夹或应用直接拖进来")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
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
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                .resizable().frame(width: 19, height: 19)

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

            if item.kind == .app, Actions.isRunning(item) {
                Circle().fill(.green).frame(width: 5, height: 5)
                    .help("已在运行")
            }

            Spacer()

            // 悬停才出现，平时不占视觉重量
            if isHovering, !isEditing {
                Button(action: beginEditing) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("重命名——只改快捷条上的显示名，不动文件夹本身")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }

            Text(item.compactPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(item.path)
        }
        .padding(.vertical, 2)
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

                        if mode == .modifierDoubleClick {
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

            Section("快捷键") {
                LabeledContent("跳到 Finder 当前文件夹") {
                    Text(KeySymbols.describe(
                        flags: CGEventFlags(rawValue: UInt64(store.settings.jumpModifierFlags)),
                        keyCode: CGKeyCode(store.settings.jumpKeyCode)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .help("只在检测到文件面板时才拦截；其他场合这个键仍然是各应用自己的功能。")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 权限

private struct PermissionsPane: View {
    @Binding var missing: [Permissions.Kind]

    var body: some View {
        Form {
            Section {
                ForEach(Permissions.Kind.allCases) { kind in
                    PermissionRow(kind: kind, granted: !missing.contains(kind))
                }
            } header: {
                Text("权限")
            } footer: {
                Text(missing.isEmpty ? "三项都在，功能完整。" : "缺少授权时相关功能会静默降级，不会报错打断你。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let granted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(kind.title)
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .font(.caption)
                .foregroundStyle(granted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                .help(kind.why)
            if !granted {
                Button("授权") { Permissions.request(kind) }
            }
        }
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
                    LabeledContent("当前记住的尺寸", value: "\(Int(size.width)) × \(Int(size.height))")
                }
            }

            Section("更新") {
                Toggle("自动检查更新", isOn: $store.settings.autoUpdate)
                Toggle("静默安装，不打断我", isOn: $store.settings.autoUpdateSilently)
                    .disabled(!store.settings.autoUpdate)
                    .help("下载完直接替换并重启。QuickBar 没有窗口，重启对你是无感的。")
                LabeledContent("当前版本", value: Updater.shared.currentVersion)
                HStack {
                    Button("立即检查更新") {
                        Updater.shared.check(userInitiated: true)
                    }
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateStatus = Updater.shared.statusText
        }
    }
}
