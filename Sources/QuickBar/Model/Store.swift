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
    /// 右侧那一行结论，由来源自己写死（素材批次用它印「7 件 · 08-20 13:05」）。
    /// 用户手动加的条目留空，右侧照旧显示紧凑路径。
    var subtitle: String?

    var url: URL { URL(fileURLWithPath: path) }

    /// 磁盘上的真实名字。重命名只改快捷条上的显示名，不碰文件系统。
    var originalName: String {
        kind == .app ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    var isRenamed: Bool { name != originalName }

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
    /// 连按两下 ⌘，完全不碰鼠标事件（默认）
    case doubleCommand
    /// 修饰键 + 双击，零误触发
    case modifierDoubleClick
    /// 只在桌面空白处双击
    case desktopDoubleClick
    /// 裸双击任意位置（会误触发，靠排除名单缓解）
    case bareDoubleClick

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
    var trigger: TriggerMode = .doubleCommand
    var modifier: TriggerModifier = .option
    /// 裸双击模式下不触发的应用 bundle id。
    var excludedBundleIDs: [String] = []

    /// 在文件面板里跳到 Finder 当前文件夹的快捷键（默认 ⌘G）。
    var jumpKeyCode: UInt16 = 5           // kVK_ANSI_G
    var jumpModifierFlags: UInt = UInt(CGEventFlags.maskCommand.rawValue)

    var rememberPanelSize: Bool = true
    /// 新开的 Finder 窗口沿用记住的尺寸。见 Core/FinderWindowService.swift。
    var rememberFinderWindowSize: Bool = true
    var launchAtLogin: Bool = true

    var autoUpdate: Bool = true
    var autoUpdateSilently: Bool = true

    // 素材批次（对接 AI 电商内容助手的素材下载单，见 Core/MaterialFeed.swift）。
    // 服务器地址写死在 MaterialFeed 里，不做成设置项——它只有一个值，
    // 摆出来只会多一处能填错的地方，还得配一句解释。
    var materialFeedEnabled: Bool = true
    /// 手填的口令。正常发布的包不用填——口令由 build.sh 内置在 Info.plist 里，
    /// 见 MaterialFeed.builtInKey。这里非空就优先用这里的。
    var materialFeedKey: String = ""
    var materialFeedNotify: Bool = true
    /// 在家目录维护一个 `~/最近素材批次/`（里面是最近几批的替身，拖进 Finder 侧栏用）。
    /// 见 Core/BatchLinks.swift。
    var batchLinksEnabled: Bool = true
    /// 在 Finder 里选中商品文件夹时，浮出一颗「主图丢进 PS」。见 UI/MainImagesPill.swift。
    var mainImagesPillEnabled: Bool = true
    /// 去水印那道工序的收尾：在 PS 里把当前这张按原路径覆盖存回并关掉。见 Core/Photoshop.swift。
    /// 一个开关同时管快捷键和那颗浮窗 —— 它们是同一件事的两个入口，分成两个只会多一处要解释的地方。
    var psSaveBackEnabled: Bool = true
    /// 存回原位的快捷键，默认 ⌃⌘S。**只在 Photoshop 在最前时拦截**，别处照旧是各应用自己的。
    var psSaveBackKeyCode: UInt16 = 1     // kVK_ANSI_S
    var psSaveBackModifierFlags: UInt = UInt(CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue)

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

    /// 记住的 Finder 窗口尺寸（全局一份）。
    var finderWindowWidth: Double = 0
    var finderWindowHeight: Double = 0

    var finderWindowSize: CGSize? {
        get {
            finderWindowWidth > 400 && finderWindowHeight > 300
                ? CGSize(width: finderWindowWidth, height: finderWindowHeight) : nil
        }
        set {
            finderWindowWidth = Double(newValue?.width ?? 0)
            finderWindowHeight = Double(newValue?.height ?? 0)
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
        if let d = try? Data(contentsOf: settingsURL), let v = Store.decodeSettings(d) {
            settings = v
        }
    }

    /// 🔴 老的 `settings.json` 必然缺新版本加的键，而 Swift 合成的 `Decodable`
    /// **碰到缺键会整个抛错**——哪怕那个属性写着默认值（实测 `keyNotFound`）。
    /// 外面再 `try?` 一兜，结果就是每加一个设置项，所有老用户的设置被悄悄清空一次：
    /// 1.6.0 加了三个键，触发方式、素材批次口令、记住的面板尺寸当场全没。
    ///
    /// 所以不能直接 decode：先把一份默认值编成 JSON，再把磁盘上那份盖上去，
    /// 缺什么补什么。以后再加键也不用管这里。
    ///
    /// （条目那边同理——给 `QuickItem` 加字段只能加 Optional 的，否则老 `items.json`
    /// 解不开会被换成一套默认条目。）
    private static func decodeSettings(_ data: Data) -> Settings? {
        let dec = JSONDecoder()
        guard let onDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encoded = try? JSONEncoder().encode(Settings()),
              var merged = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
        else { return try? dec.decode(Settings.self, from: data) }

        for (key, value) in onDisk { merged[key] = value }
        guard let patched = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? dec.decode(Settings.self, from: patched)
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
