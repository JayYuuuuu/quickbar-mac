import AppKit
import Combine

// MARK: - 条目

/// 快捷条里的一项：要么是文件夹，要么是应用。
struct QuickItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case folder, app }

    var id: UUID = UUID()
    var kind: Kind
    /// 显示名。默认取路径最后一段，用户可以改。
    var name: String
    /// 文件夹是目录路径；应用是 .app 的路径。
    var path: String
    /// 应用才有，用来判断是否已在运行。
    var bundleID: String?

    var url: URL { URL(fileURLWithPath: path) }

    /// 路径在快捷条右侧的紧凑写法：家目录折成 ~，过长的中间省略。
    var compactPath: String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 4 else { return p }
        return "\(parts[0])/\(parts[1])/…/\(parts[parts.count - 2])"
    }

    static func folder(at url: URL) -> QuickItem {
        QuickItem(kind: .folder, name: url.lastPathComponent, path: url.path)
    }

    static func app(at url: URL) -> QuickItem {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return QuickItem(kind: .app, name: name, path: url.path, bundleID: bundle?.bundleIdentifier)
    }
}

// MARK: - 触发方式

enum TriggerMode: String, Codable, CaseIterable {
    /// 修饰键 + 双击（默认，零误触发）
    case modifierDoubleClick
    /// 只在桌面空白处双击
    case desktopDoubleClick
    /// 裸双击任意位置（会误触发，靠排除名单缓解）
    case bareDoubleClick
    /// 连按两下 ⌘，完全不碰鼠标事件
    case doubleCommand

    var label: String {
        switch self {
        case .modifierDoubleClick: return "修饰键 + 双击"
        case .desktopDoubleClick: return "双击桌面空白处"
        case .bareDoubleClick: return "裸双击任意位置"
        case .doubleCommand: return "连按两下 ⌘"
        }
    }

    var note: String {
        switch self {
        case .modifierDoubleClick: return "按住修饰键再双击，不会和任何已有操作冲突。"
        case .desktopDoubleClick: return "最安全，但别的应用全屏时用不了，得先回桌面。"
        case .bareDoubleClick: return "双击在 macOS 里到处有语义（文本选词、Finder 打开、标题栏最大化），必然会误触发。"
        case .doubleCommand: return "完全不碰鼠标事件，零冲突；快捷条弹在鼠标位置。"
        }
    }
}

/// 触发用的修饰键。
enum TriggerModifier: String, Codable, CaseIterable {
    case option, control, command, function

    var label: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .function: return "fn"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .command: return .maskCommand
        case .function: return .maskSecondaryFn
        }
    }

    /// 除自己以外的其他修饰键，用来排除「⌥⌘双击」这类组合。
    static let allFlags: CGEventFlags = [.maskAlternate, .maskControl, .maskCommand, .maskShift]
}

// MARK: - 偏好设置

struct Settings: Codable {
    var trigger: TriggerMode = .modifierDoubleClick
    var modifier: TriggerModifier = .option
    /// 裸双击模式下不触发的应用 bundle id。
    var excludedBundleIDs: [String] = []

    /// 在文件面板里跳到 Finder 当前文件夹的快捷键（默认 ⌘G）。
    var jumpKeyCode: UInt16 = 5           // kVK_ANSI_G
    var jumpModifierFlags: UInt = UInt(CGEventFlags.maskCommand.rawValue)

    var rememberPanelSize: Bool = true
    var launchAtLogin: Bool = true

    var autoUpdate: Bool = true
    var autoUpdateSilently: Bool = true

    /// 记住的文件面板尺寸（全局一份）。
    var panelWidth: Double = 0
    var panelHeight: Double = 0

    var panelSize: CGSize? {
        get { panelWidth > 200 && panelHeight > 200 ? CGSize(width: panelWidth, height: panelHeight) : nil }
        set {
            panelWidth = Double(newValue?.width ?? 0)
            panelHeight = Double(newValue?.height ?? 0)
        }
    }
}

// MARK: - 存储

/// 条目和设置的唯一事实源。写盘是防抖的，避免拖排序时疯狂写文件。
final class Store: ObservableObject {
    static let shared = Store()

    @Published var items: [QuickItem] = [] { didSet { scheduleSave() } }
    @Published var settings = Settings() { didSet { scheduleSave() } }

    private let dir: URL
    private var saveTimer: Timer?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("QuickBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private var itemsURL: URL { dir.appendingPathComponent("items.json") }
    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: itemsURL), let v = try? dec.decode([QuickItem].self, from: d) {
            items = v
        } else {
            items = Store.defaultItems()
        }
        if let d = try? Data(contentsOf: settingsURL), let v = try? dec.decode(Settings.self, from: d) {
            settings = v
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(items).write(to: itemsURL, options: .atomic)
        try? enc.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// 首次启动给几个几乎人人都要的文件夹，省得面对一张空列表。
    private static func defaultItems() -> [QuickItem] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        return dirs.compactMap { d in
            guard let url = fm.urls(for: d, in: .userDomainMask).first else { return nil }
            var item = QuickItem.folder(at: url)
            item.name = ["Downloads": "下载", "Desktop": "桌面", "Documents": "文稿"][url.lastPathComponent]
                ?? url.lastPathComponent
            return item
        }
    }

    // MARK: 便捷操作

    func add(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let item: QuickItem = url.pathExtension == "app" ? .app(at: url) : (isDir.boolValue ? .folder(at: url) : .folder(at: url.deletingLastPathComponent()))
        guard !items.contains(where: { $0.path == item.path }) else { return }
        items.append(item)
    }

    var folders: [QuickItem] { items.filter { $0.kind == .folder } }
    var apps: [QuickItem] { items.filter { $0.kind == .app } }
}
