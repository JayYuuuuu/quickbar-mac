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

/// 甩过去要落到哪儿。
///
/// 🔴 **落点不都是「一个进程」**，这是二级展开逼出来的：访达一个进程开着好几个窗口、
/// WPS 一个窗口里塞着好几个文档（它用标签页）。三种落点各有各的切法，见 `WindowSwitch.activate`。
struct SwitchTarget {
    enum Action: Equatable {
        /// 切到这个进程，落在它最前那个窗口上。
        case app
        /// 切到这个进程的第 N 个窗口（访达开好几个文件夹窗口时用）。
        case window(index: Int)
        /// 点这个应用「窗口」菜单里的那一项 —— WPS 那种标签页只能这么切（实测）。
        case document(menuTitle: String)
    }

    let pid: pid_t
    var action: Action = .app
    let appName: String
    let icon: NSImage?
    /// 窗口标题（异步补上）。5 个 Chrome 图标一模一样，**只有它能区分**，
    /// 所以这不是装饰，是这个功能能不能用的关键。
    var windowTitle: String?
    /// PortManager 里那个店名（「C店」「天猫」）。非 PortManager 管的浏览器没有。见 BrowserPorts。
    var badge: String?

    /// 格子上那行主字：有窗口标题就用标题，没有就退回应用名。
    var label: String {
        guard let t = windowTitle, !t.isEmpty else { return appName }
        return t
    }

    /// 格子上那行小灰字。**店名比「浏览器」三个字有用得多** —— 方向本来就说明了这是浏览器那格，
    /// 人真正要确认的是「这是哪个店」。
    func caption(_ lane: SwitchLane) -> String {
        guard let badge, !badge.isEmpty else { return lane.title }
        return "\(lane.title) · \(badge)"
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

    private func make(_ app: NSRunningApplication, action: SwitchTarget.Action = .app) -> SwitchTarget {
        SwitchTarget(pid: app.processIdentifier,
                     action: action,
                     appName: app.localizedName ?? "应用",
                     icon: app.icon,
                     windowTitle: nil)
    }

    // MARK: - 一格里的全部成员（停住展开时才算）

    /// 这一类里所有能去的地方，最近用过的排前面。
    ///
    /// 🔴 **这条路慢，只在人停住手要展开时才走** —— 它要枚举 AX 窗口、还要读 WPS 的「窗口」菜单，
    /// 都是跨进程 IPC。弹出那一路上一步都不能碰它（那条的全部价值是「按下就在」）。
    ///
    /// 三类各有各的展开口径，都是量出来的：
    /// - **浏览器**：一个实例一个进程（多 profile），所以按进程列，每个挂上店名。
    /// - **访达**：一个进程好几个窗口，所以按 AX 窗口列。实测 raise 第 2 个窗口之后
    ///   窗口顺序真的翻了 —— AX 的窗口数组就是 z 序。
    /// - **文档**：WPS 用标签页，两个文档只有一个 AX 窗口，但它的**「窗口」菜单**里两个都列着。
    ///   实测点那一项能切过去（qb.docx → qa.docx）。这是所有多文档应用的通用约定，
    ///   不用给 WPS 写特例；菜单里没有文档项的应用就退回按进程列。
    nonisolated static func members(of lane: SwitchLane, apps: [(pid: pid_t, name: String, icon: NSImage?)]) -> [SwitchTarget] {
        var out: [SwitchTarget] = []
        for app in apps {
            switch lane {
            case .browser:
                var t = SwitchTarget(pid: app.pid, action: .app, appName: app.name, icon: app.icon)
                t.windowTitle = windowTitle(pid: app.pid).map { trim($0, appName: app.name) }
                t.badge = BrowserPorts.info(pid: app.pid)?.label
                out.append(t)

            case .finder:
                let titles = windowTitles(pid: app.pid)
                if titles.isEmpty {
                    out.append(SwitchTarget(pid: app.pid, action: .app, appName: app.name, icon: app.icon))
                }
                for (i, title) in titles.enumerated() {
                    var t = SwitchTarget(pid: app.pid, action: .window(index: i), appName: app.name, icon: app.icon)
                    t.windowTitle = title
                    out.append(t)
                }

            case .document:
                let docs = documentMenuItems(pid: app.pid)
                if docs.isEmpty {
                    var t = SwitchTarget(pid: app.pid, action: .app, appName: app.name, icon: app.icon)
                    t.windowTitle = windowTitle(pid: app.pid).map { trim($0, appName: app.name) }
                    out.append(t)
                }
                for doc in docs {
                    var t = SwitchTarget(pid: app.pid, action: .document(menuTitle: doc.raw),
                                         appName: app.name, icon: app.icon)
                    t.windowTitle = doc.shown
                    t.badge = app.name
                    out.append(t)
                }
            }
        }
        return out
    }

    /// 一个进程的所有窗口标题，按 AX 的顺序（= z 序，最前的在最前面）。
    nonisolated static func windowTitles(pid: pid_t) -> [String] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.4)
        return AX.elements(ax, kAXWindowsAttribute as String).compactMap {
            let t = AX.string($0, kAXTitleAttribute as String)
            return (t?.isEmpty ?? true) ? nil : t
        }
    }

    /// 「窗口」菜单最底下那批文档项。
    ///
    /// 🔴 **认它们靠「在最后一条分隔线之后」**，不靠名字 —— 上面那些是「水平平铺」「层叠」
    /// 这类命令，各家应用各不相同，写死名单一定漏。菜单项名字前面还挂着序号（`1 qa.docx`），
    /// 点的时候要用带序号的原名，显示时才把它去掉。
    nonisolated static func documentMenuItems(pid: pid_t) -> [(raw: String, shown: String)] {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.6)
        guard let bar = AX.element(ax, kAXMenuBarAttribute as String) else { return [] }

        // 「窗口」菜单：中文系统叫「窗口」，英文的叫 Window。
        let names = ["窗口", "Window", "视窗"]
        var menu: AXUIElement?
        for item in AX.elements(bar, kAXChildrenAttribute as String) {
            guard let title = AX.string(item, kAXTitleAttribute as String), names.contains(title) else { continue }
            menu = AX.elements(item, kAXChildrenAttribute as String).first
            break
        }
        guard let menu else { return [] }

        var afterSeparator: [(String, String)] = []
        for item in AX.elements(menu, kAXChildrenAttribute as String) {
            let title = AX.string(item, kAXTitleAttribute as String)
            guard let title, !title.isEmpty else {          // 分隔线没有标题
                afterSeparator.removeAll()
                continue
            }
            // 去掉前面那个序号：「1 qa.docx」→「qa.docx」
            var shown = title
            if let space = title.firstIndex(of: " "),
               Int(title[title.startIndex..<space]) != nil {
                shown = String(title[title.index(after: space)...])
            }
            // 服务端读到的目录名和访达呈现的可能差一次归一化，这里只取最后一段做显示。
            if shown.hasPrefix("/") { shown = (shown as NSString).lastPathComponent }
            afterSeparator.append((title, shown))
        }
        // 只有两个以上才值得展开 —— 一个的时候展开跟不展开是同一件事。
        return afterSeparator.count >= 2 ? afterSeparator.map { (raw: $0.0, shown: $0.1) } : []
    }

    /// 这一类里所有活着的应用，MRU 顺序。
    func apps(of lane: SwitchLane) -> [(pid: pid_t, name: String, icon: NSImage?)] {
        var list = liveApps().filter { Self.lane(of: $0) == lane }
        if lane == .document, list.isEmpty {
            list = liveApps().filter { Self.lane(of: $0) == nil }
        }
        return list.map { ($0.processIdentifier, $0.localizedName ?? "应用", $0.icon) }
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
    /// 按落点的类型分三条路走。
    static func activate(_ target: SwitchTarget) {
        switch target.action {
        case .app:
            activate(pid: target.pid)
        case .window(let index):
            activate(pid: target.pid, windowIndex: index)
        case .document(let menuTitle):
            activate(pid: target.pid, menuTitle: menuTitle)
        }
    }

    /// 访达那种一个进程好几个窗口：raise 指定那个再把应用带到前台。
    /// 顺序不能反 —— 先 frontmost 的话人会先看到**上一个**窗口闪一下。
    static func activate(pid: pid_t, windowIndex: Int) {
        DispatchQueue.global(qos: .userInteractive).async {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.5)
            let windows = AX.elements(ax, kAXWindowsAttribute as String)
            if windowIndex < windows.count {
                AXUIElementPerformAction(windows[windowIndex], kAXRaiseAction as CFString)
            }
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            DispatchQueue.main.async {
                guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    /// WPS 那种标签页：点它「窗口」菜单里的那一项。
    /// 🔴 **要先把应用带到前台再点** —— 菜单栏是前台应用那份，不在前台时点不到。
    static func activate(pid: pid_t, menuTitle: String) {
        activate(pid: pid)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.25) {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.6)
            guard let bar = AX.element(ax, kAXMenuBarAttribute as String) else { return }
            let names = ["窗口", "Window", "视窗"]
            for item in AX.elements(bar, kAXChildrenAttribute as String) {
                guard let t = AX.string(item, kAXTitleAttribute as String), names.contains(t),
                      let menu = AX.elements(item, kAXChildrenAttribute as String).first else { continue }
                for entry in AX.elements(menu, kAXChildrenAttribute as String)
                where AX.string(entry, kAXTitleAttribute as String) == menuTitle {
                    AXUIElementPerformAction(entry, kAXPressAction as CFString)
                    return
                }
            }
        }
    }

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
