import AppKit
import ApplicationServices

/// 三向甩要切的那三类。方向是**固定**的 —— 固定才能闭着眼甩，
/// 这也是它跟「列一堆窗口让你挑」的根本区别。
enum SwitchLane: Int, CaseIterable {
    /// 左
    case browser = 0
    /// 上
    case document = 1
    /// 右
    case finder = 2

    var title: String {
        switch self {
        case .browser: return "浏览器"
        case .document: return "文档"
        case .finder: return "访达"
        }
    }

    /// 一格都没命中时那句灰字。
    var emptyHint: String {
        switch self {
        case .browser: return "没开着浏览器"
        case .document: return "没开着文档"
        case .finder: return "打开访达"
        }
    }
}

/// 甩过去要落到哪个进程上。
struct SwitchTarget {
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    /// 窗口标题（异步补上）。5 个 Chrome 图标一模一样，**只有它能区分**，
    /// 所以这不是装饰，是这个功能能不能用的关键。
    var windowTitle: String?

    /// 格子上那行主字：有窗口标题就用标题，没有就退回应用名。
    var label: String {
        guard let t = windowTitle, !t.isEmpty else { return appName }
        return t
    }
}

/// 「按住 ⌥ 敲一下 Tab，手往一个方向甩，松开 ⌥」——三类各自记着你上次在的那个。
///
/// 【为什么不是轮盘】PortManager 那个轮盘瓣数固定（就那八个店），所以能盲甩。
/// 这里要切的窗口数量天天变，十几瓣就没法盲甩了；而且这台机器上同时开着 **5 个 Chrome**，
/// 图标一模一样，光看图标分不出哪个是万相台哪个是 Gmail —— 所以格子上必须有标题，
/// 而三格固定方向 + 一行标题，才是既能盲甩又能确认的形状。
///
/// 【实测地基】（2026-09-07 mac24g / macOS 26.6.2）
/// 🔴 **切到「哪一个」Chrome 只能走辅助功能，不能走 bundle id。**
///    `Actions.launchOrActivate` 那条路是按 bundle id 找 `first`，5 个实例里它只会挑到同一个 ——
///    甩到浏览器十次有九次切错。实测把某个 pid 的 `AXFrontmost` 设成真，两次分别切到 21034（DMIT）
///    和 42519（万相台），**都精确对上了**。
/// 🔴 **窗口标题读得到**：一次列出 16 个程序的窗口标题（5 个 Chrome 分别停在 Gmail / 聚水潭 /
///    万相台 / DMIT，访达开着哪两个文件夹），只要辅助功能权限 —— QuickBar 早就有。
/// 🔴 **WPS 是标签页不是窗口**：开两个文档，系统只看到**一个** AX 窗口，
///    而且 `AXDocument` 是 missing value（拿不到文件路径）。所以「文档」这一格
///    只能落到应用上、切到它最前面那个文档；要列出它里面开着的每一个文档，
///    得读「窗口」菜单（实测那里两个都在、还带路径），那是下一步的事。
@MainActor
final class WindowSwitch {
    static let shared = WindowSwitch()

    /// 最近用过的进程，最新的在前。切换的落点全从这里挑。
    private var mru: [pid_t] = []
    private var started = false

    private init() {}

    // MARK: - 分类

    /// 浏览器。多开的 Chrome 实例是**各自独立的进程**（PortManager 那套多 profile），
    /// 所以这一类里往往有好几个，靠 MRU 排。
    private static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// 文档。白名单优先，没命中时下面有兜底（见 `target(for:)`）。
    private static let documentIDs: Set<String> = [
        "com.kingsoft.wpsoffice.mac",                                    // 这台机器上的「Word」其实是它
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.apple.iWork.Pages", "com.apple.iWork.Numbers", "com.apple.iWork.Keynote",
        "com.apple.Preview", "com.apple.TextEdit", "com.apple.Notes",
        "com.adobe.Acrobat.Pro", "com.adobe.Reader",
        "abnerworks.Typora", "md.obsidian", "com.microsoft.VSCode",
    ]

    private static let finderID = "com.apple.finder"

    /// 兜底那一格永远轮不到的：自己，以及纯后台的东西。
    private static func eligible(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && app.activationPolicy == .regular
            && !app.isTerminated
    }

    static func lane(of app: NSRunningApplication) -> SwitchLane? {
        guard let id = app.bundleIdentifier else { return nil }
        if id == finderID { return .finder }
        if browserIDs.contains(id) { return .browser }
        if documentIDs.contains(id) { return .document }
        return nil
    }

    // MARK: - 最近用过的

    func start() {
        guard !started else { return }
        started = true

        // 先拿一份初始顺序。系统不给「上次激活时间」，所以这份是无序的 ——
        // 人切过一次之后就准了，不值得为开头这几秒去猜。
        for app in NSWorkspace.shared.runningApplications where Self.eligible(app) {
            mru.append(app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            note(front.processIdentifier)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.eligible(app) else { return }
            MainActor.assumeIsolated { self?.note(app.processIdentifier) }
        }
    }

    private func note(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
        if mru.count > 40 { mru.removeLast(mru.count - 40) }
    }

    /// MRU 顺序的活着的应用。已经退出的顺手清掉。
    private func liveApps() -> [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        var alive: [pid_t] = []
        for pid in mru {
            guard let app = NSRunningApplication(processIdentifier: pid), Self.eligible(app) else { continue }
            alive.append(pid)
            out.append(app)
        }
        // MRU 里没有的（启动后新开的应用在 didActivate 之前不在表里）补到后面。
        for app in NSWorkspace.shared.runningApplications
        where Self.eligible(app) && !alive.contains(app.processIdentifier) {
            out.append(app)
        }
        mru = alive
        return out
    }

    // MARK: - 三格分别落到哪

    /// 一次算齐三格。
    ///
    /// 🔴 **当前在最前的那个要排除掉**：人在 Chrome A 里甩「浏览器」，
    /// 意思是「回到刚才那个 Chrome」，不是「原地不动」。排除之后同类里也能来回切。
    func targets() -> [SwitchLane: SwitchTarget] {
        let apps = liveApps()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var out: [SwitchLane: SwitchTarget] = [:]

        for lane in SwitchLane.allCases {
            let hit = apps.first { Self.lane(of: $0) == lane && $0.processIdentifier != frontPID }
                ?? apps.first { Self.lane(of: $0) == lane }
            if let app = hit {
                out[lane] = make(app)
            }
        }

        // 文档那一格的兜底：白名单一个都没开着时，退到「最近用过的、不属于另外两类的应用」。
        // 人在微信里复制一段字，甩「上」回到微信也是对的 —— 格子上写的是真实目标名，
        // 不会让人以为切去了别处。
        if out[.document] == nil,
           let fallback = apps.first(where: { Self.lane(of: $0) == nil && $0.processIdentifier != frontPID }) {
            out[.document] = make(fallback)
        }
        return out
    }

    private func make(_ app: NSRunningApplication) -> SwitchTarget {
        SwitchTarget(pid: app.processIdentifier,
                     appName: app.localizedName ?? "应用",
                     icon: app.icon,
                     windowTitle: nil)
    }

    // MARK: - 窗口标题（后台读，别挡住弹出）

    /// 🔴 **不要在弹出那一路上同步读**：AX 是跨进程 IPC，对面卡住就跟着卡，
    /// 而这个面板的全部价值就在于「按下就在」。先用应用名画出来，标题回来了再换。
    nonisolated static func windowTitle(pid: pid_t) -> String? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        let win = AX.element(ax, kAXFocusedWindowAttribute as String)
            ?? AX.element(ax, kAXMainWindowAttribute as String)
        guard let win, let raw = AX.string(win, kAXTitleAttribute as String) else { return nil }
        return raw.isEmpty ? nil : raw
    }

    /// 「货品全站推广_万相台无界版 - 内存用量高 - 951 MB - Google Chrome」这种尾巴，
    /// 三格都挂着同一串应用名只会把真正有用的那半挤出去。
    nonisolated static func trim(_ title: String, appName: String) -> String {
        var t = title
        for suffix in [" - \(appName)", " — \(appName)", " – \(appName)"] where t.hasSuffix(suffix) {
            t.removeLast(suffix.count)
        }
        return t.isEmpty ? title : t
    }

    // MARK: - 切过去

    /// 🔴 **辅助功能那条是主路，不是兜底。**
    /// `NSRunningApplication` 那套按 bundle id 找「第一个」，5 个 Chrome 里永远挑同一个；
    /// 而 `AXFrontmost` 是对着 pid 说话的，实测两次都精确切到了指定的那一个实例。
    /// 底下那几行是防「AX 恰好不灵」的保险，不影响主路。
    static func activate(pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.unhide()

        // macOS 14 起跨应用激活是协作式的，后台程序不 yield 会被静默忽略（见 Actions.swift）。
        if #available(macOS 14.0, *), let app {
            NSApp.yieldActivation(to: app)
        }

        // 🔴 **AX 那几发不能在主线程上打**：它是跨进程同步 IPC，对面压着模态框就一直不回，
        //    0.5 秒的超时会原样变成整个界面卡 0.5 秒 —— 而这正是人刚松手、最盯着屏幕的那一刻。
        //    （同 Photoshop.swift 那条「绝不在主线程上发 AE」。）
        DispatchQueue.global(qos: .userInteractive).async {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            if let win = AX.element(ax, kAXMainWindowAttribute as String)
                ?? AX.element(ax, kAXFocusedWindowAttribute as String) {
                AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            }
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

            // 没有窗口的应用（访达常常一个窗口都不开）AX 那条不够，补一刀。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard let app, !app.isActive else { return }
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    /// 访达一个窗口都没开时，甩「右」得给人开一个 —— 否则就是「点了没反应」。
    static func activateFinder() {
        let finder = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == finderID }
        if let finder {
            let ax = AXUIElementCreateApplication(finder.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            let hasWindow = !AX.elements(ax, kAXWindowsAttribute as String).isEmpty
            if hasWindow {
                activate(pid: finder.processIdentifier)
                return
            }
        }
        Actions.openFolder(NSHomeDirectory())
    }
}
