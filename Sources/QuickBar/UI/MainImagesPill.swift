import AppKit

/// Finder 里选中商品文件夹时浮出来的那颗小药丸：**点一下，选中那几件的主图全进 Photoshop**。
///
/// 【为什么不是菜单栏那一项就够了】菜单栏要「移到屏幕顶上 → 点图标 → 在菜单里找那一项」，
/// 手离开刚刚选文件的地方跑一趟。选完就在旁边浮一颗按钮，是同一件事少走两步。
/// 菜单栏那一项保留：浮窗关掉了、或者想对当前窗口整批来一下时还得有个入口。
///
/// 【只在"点了真的有事发生"的时候出现】显示条件不是"在素材目录里"，而是
/// **选中的东西真的解析出了主图**（`MainImages.collect` 说有几张就是几张）。
/// 🔴 有意不加"必须在 `_采集` 树下"这种路径闸门：素材被复制到别处照样能用，
///    而看不见的显示条件只会变成"它怎么不出来"——那种问题从外面永远查不出。
///
/// 【三个不能踩的点】
/// 🔴 **问 Finder 要选中项的那一发不许在主线程**：AppleScript 一次几十毫秒，而双击 ⌘
///    的判定是在事件 tap 回调里按 `CFAbsoluteTimeGetCurrent()` 算间隔的——主线程被占住
///    会让回调晚到，间隔就量歪了。所以轮询整个跑在自己的串行队列上。
/// 🔴 **只在 Finder 在最前时轮询**，别的时候一个定时器都不留（这软件平时是零负载的）。
/// 🔴 **选中项没变就什么都不做**：变了才去数图（数图要 readdir，素材盘是 SMB，一次几十毫秒）。
final class MainImagesPill {

    static let shared = MainImagesPill()

    private var panel: NSPanel?
    private var button: NSButton?
    private var timer: Timer?
    /// 专门问 Finder 的串行队列（见文件头：不许在主线程问）。
    private let probe = DispatchQueue(label: "quickbar.mainimages.probe", qos: .utility)
    private var probing = false

    /// 上一次看到的选中项（用来判"变没变"）。
    private var lastSelection: [String] = []
    /// 已经点过的那一组：点完不再为同一组选中项弹出来，否则一点完它又冒出来，很容易重复丢一次。
    private var actedSelection: [String] = []
    /// 当前这组选中项对应的主图（点下去就开这些的父级路径）。
    private var pending: [String] = []

    private init() {}


    // MARK: - 生命周期

    func start() {
        // 切走的那一下立刻把药丸收掉（等下一次心跳要慢 1.5 秒，一颗浮窗压在别的 app 上很难看）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier != "com.apple.finder" { self?.leaveFinder() }
        }
        startHeartbeat()
    }

    /// 设置里改开关时调一下。
    func reload() {
        if enabled { startHeartbeat() } else { stopHeartbeat() }
    }

    private var enabled: Bool {
        Store.shared.settings.mainImagesPillEnabled
            && Permissions.isGranted(.automation)
            && NSWorkspace.shared.urlForApplication(withBundleIdentifier: MainImages.photoshopBundleID) != nil
    }

    /// 🔴 **心跳一直在跑，不靠「切到 Finder」那个通知来启动**。
    ///    第一版只在 `didActivateApplication` 里启动轮询 —— 结果是「Finder 本来就在最前面」
    ///    时（软件自动更新后重启、开机自启，都是这种）永远等不到那个通知，药丸从此不出现，
    ///    而且一声不响（2026-08-24 实测被这条坑了一轮）。现在改成：心跳自己看最前面是谁。
    ///    不在 Finder 时这一跳只读一个属性就返回，代价接近零；只有在 Finder 里才去问选中项。
    private func startHeartbeat() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
        leaveFinder()
    }

    /// 离开 Finder：收掉药丸，并且**忘掉上一次的选中项** —— 不忘的话回到 Finder 时
    /// 「选中项没变」这一条会让它不再出现。
    private func leaveFinder() {
        lastSelection = []
        hide()
    }

    // MARK: - 轮询

    private func tick() {
        guard enabled else { stopHeartbeat(); return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
            if !lastSelection.isEmpty || panel?.isVisible == true { leaveFinder() }
            return
        }
        guard !probing else { return }
        // 🔴 **问 Finder 这一发必须在主线程**。第一版为了不占主线程把它扔进了后台队列，
        //    结果是 `NSAppleScript` 一声不响地返回空 —— 药丸从不出现、日志一行都没有
        //    （2026-08-24 实测，白查了一轮）。它不是线程安全的，AE 的权限判定同理。
        //    代价是每 1.5 秒一次几十毫秒的主线程占用，而且**只在 Finder 在最前时**发生；
        //    真正重的那半（数图 = readdir，素材盘是 SMB）仍然留在后台队列。
        let paths = FinderService.shared.selectionNow()
        if paths == lastSelection { return }      // 选中项没变 → 连图都不用数
        lastSelection = paths
        guard !paths.isEmpty else { hide(); return }
        let acted = actedSelection
        probing = true
        probe.async { [weak self] in
            let images = MainImages.collect(from: Array(paths.prefix(200)))
            let folders = Set(images.map { $0.deletingLastPathComponent().path }).count
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard !images.isEmpty, paths != acted else { self.hide(); return }
                self.pending = paths
                self.show(count: images.count, folders: folders)
            }
        }
    }

    // MARK: - 那颗药丸

    private func show(count: Int, folders: Int) {
        // 每件只开首图，所以「几张」就是「几件」，不用两个数（`folders` 留着是为了万一 FIRST_ONLY 关掉）
        let title = count == folders ? "主图丢进 PS · \(count) 张" : "主图丢进 PS · \(folders) 件 \(count) 张"
        let panel = self.panel ?? makePanel()
        // 🔴 borderless 的 NSButton 用 title 时字色不跟 labelColor 走（暗色下会看不清），
        //    所以直接给 attributedTitle 钉住颜色和字体。
        button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        panel.setContentSize(NSSize(width: fittingWidth(for: title), height: 30))
        place(panel)
        panel.orderFrontRegardless()
        // 唯一的观测口：这颗药丸弹在哪儿、写着什么。屏幕截不到的时候（远程排查）就靠它，
        // 而「它怎么没出来」正是最常见的一类提问。只在选中项变了时才打，一次操作一行。
        NSLog("[QuickBar] 药丸 \(title) @ \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func fittingWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (title as NSString).size(withAttributes: [.font: font]).width
        return min(max(w + 26, 120), 320)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 🔴 `.transient` 不能加：那会让它在 Finder 前台时也被系统收走。
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .popover          // 跟随系统明暗，文字用 labelColor 两种外观都清楚
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 9
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.separatorColor.cgColor

        let b = NSButton(title: "", target: self, action: #selector(act))
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        b.contentTintColor = .labelColor
        b.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            b.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            b.topAnchor.constraint(equalTo: blur.topAnchor),
            b.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        b.toolTip = "把选中的商品文件夹里的「主图」全部在 Photoshop 里打开。不想要它浮出来：设置 → 素材批次里关掉。"

        p.contentView = blur
        panel = p
        button = b
        return p
    }

    @objc private func act() {
        let paths = pending
        actedSelection = paths
        hide()
        MainImages.openInPhotoshop(paths)
    }

    // MARK: - 摆哪儿

    /// 贴在 Finder 最前窗口的右下角内侧；拿不到窗口就贴当前屏幕右下。
    /// 🔴 AX 给的坐标是「主屏左上角为原点、y 向下」，AppKit 是「左下为原点、y 向上」，必须翻一次。
    ///    翻错了的表现是药丸跑到屏幕外（看着像"没弹出来"），所以最后一定要夹回可见区域。
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        var origin: NSPoint
        if let rect = finderWindowFrameInAppKit() {
            origin = NSPoint(x: rect.maxX - size.width - 18, y: rect.minY + 18)
        } else if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            origin = NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24)
        } else {
            origin = NSPoint(x: 200, y: 200)
        }
        // 夹回它所在那块屏幕的可见区域
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: origin.x, y: origin.y)) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func finderWindowFrameInAppKit() -> CGRect? {
        guard Permissions.isGranted(.accessibility),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        guard let win = AX.element(app, AXAttr.focusedWindow) ?? AX.elements(app, AXAttr.windows).first,
              let pos = AX.position(win), let sz = AX.size(win), sz.width > 120, sz.height > 80
        else { return nil }
        // 主屏（原点在 (0,0) 那块）的高度是两套坐标之间的换算基准
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return nil }
        let y = primary.frame.maxY - (pos.y + sz.height)
        return CGRect(x: pos.x, y: y, width: sz.width, height: sz.height)
    }
}
