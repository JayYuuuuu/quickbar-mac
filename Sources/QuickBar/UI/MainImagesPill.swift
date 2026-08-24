import AppKit

/// 去水印那道工序两头的那颗小药丸。同一颗，看你人在哪儿：
///
/// · **在 Finder 里**选中了商品文件夹 → 「主图丢进 PS · N 张」，点一下全打开；
/// · **在 Photoshop 里**还有没存回的图 → 「存回原位 · 还剩 N 张」，点一下把当前这张
///   拼合、按原路径覆盖存回、关掉（见 Core/Photoshop.swift）。
///
/// 【为什么是同一颗】它俩是一件事的两头：丢进去、改完存回来。分成两个浮窗只会让人
/// 多记一样东西，而这两个状态在时间上根本不重叠 —— 人不可能同时站在 Finder 和 PS 里。
///
/// 【为什么不是菜单栏那一项就够了】菜单栏要「移到屏幕顶上 → 点图标 → 在菜单里找那一项」，
/// 手离开刚刚选文件的地方跑一趟。选完就在旁边浮一颗按钮，是同一件事少走两步。
/// 菜单栏那一项保留：浮窗关掉了、或者想对当前窗口整批来一下时还得有个入口。
///
/// 【只在"点了真的有事发生"的时候出现】Finder 那头的显示条件不是"在素材目录里"，而是
/// **选中的东西真的解析出了主图**（`MainImages.collect` 说有几张就是几张）；
/// PS 那头是**这一趟确实往里丢过图、还没全存回**（`Photoshop.remaining > 0`）。
/// 🔴 有意不加"必须在 `_采集` 树下"这种路径闸门：素材被复制到别处照样能用，
///    而看不见的显示条件只会变成"它怎么不出来"——那种问题从外面永远查不出。
///
/// 【三个不能踩的点】
/// 🔴 **问 Finder 要选中项的那一发不许在主线程**：AppleScript 一次几十毫秒，而双击 ⌘
///    的判定是在事件 tap 回调里按 `CFAbsoluteTimeGetCurrent()` 算间隔的——主线程被占住
///    会让回调晚到，间隔就量歪了。所以轮询整个跑在自己的串行队列上。
/// 🔴 **只在 Finder 在最前时轮询**，别的时候一个定时器都不留（这软件平时是零负载的）。
/// 🔴 **选中项没变就什么都不做**：变了才去数图（数图要 readdir，素材盘是 SMB，一次几十毫秒）。
/// 🔴 **PS 那头一发 AE 都不问**：心跳里绝不去问 Photoshop「你开着几个文档」——
///    它正压着模态框时那一发要等到它闲下来（实测能等 40 秒以上，见 Photoshop.swift 文件头）。
///    数字由 QuickBar 自己记（丢进去几张），每存回一张拿 PS 回的真实数校准一次。
final class MainImagesPill {

    /// 药丸此刻在替哪一头说话。
    private enum Mode { case finder, photoshop }

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
    private var mode: Mode = .finder
    /// 药丸上现在写着什么。用来判「要不要重画」（见 `show`）。
    private var shownTitle = ""
    /// 贴着谁走。窗口一动就把药丸挪过去（见 Core/WindowFollow.swift）。
    private let follow = WindowFollow()

    private init() {}


    // MARK: - 生命周期

    func start() {
        // 切走的那一下立刻把药丸收掉（等下一次心跳要慢 1.5 秒，一颗浮窗压在别的 app 上很难看）
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let front = app?.bundleIdentifier
            // Finder ↔ PS 之间来回切要立刻换一头（等 1.5 秒会看到上一头的药丸压在新窗口上）；
            // 切到别的应用一律收掉。
            if front == "com.apple.finder" || front == Photoshop.bundleID {
                self?.tick()
            } else {
                self?.leave()
            }
        }
        // 宿主窗口一动/一缩/一换，药丸立刻跟过去 —— 等 1.5 秒的心跳会看到它"掉队"。
        follow.onChange = { [weak self] in self?.reposition() }
        // 存回一张之后数字要立刻变（甚至归零收掉），等下一次心跳会让人以为没生效。
        Photoshop.onStateChanged = { [weak self] in
            guard let self, self.mode == .photoshop else { return }
            self.tick()
        }
        startHeartbeat()
    }

    /// 设置里改开关时调一下。
    func reload() {
        if enabled { startHeartbeat() } else { stopHeartbeat() }
    }

    /// 两头都要 PS 装着 —— 一头是往它里面丢，一头是跟它说话。
    private var finderSideEnabled: Bool {
        Store.shared.settings.mainImagesPillEnabled
            && Permissions.isGranted(.automation)
            && Photoshop.isInstalled
    }

    private var photoshopSideEnabled: Bool {
        Store.shared.settings.psSaveBackEnabled && Photoshop.isInstalled
    }

    private var enabled: Bool { finderSideEnabled || photoshopSideEnabled }

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
        leave()
    }

    /// 离开：收掉药丸，并且**忘掉上一次的选中项** —— 不忘的话回到 Finder 时
    /// 「选中项没变」这一条会让它不再出现。
    private func leave() {
        lastSelection = []
        hide()
    }

    /// 当前该贴着谁。
    private var hostBundleID: String {
        mode == .finder ? "com.apple.finder" : Photoshop.bundleID
    }

    // MARK: - 轮询

    private func tick() {
        guard enabled else { stopHeartbeat(); return }
        // 心跳只负责「别跑偏」：跟手是 WindowFollow 的推送在做，这里兜住漏掉的那些
        // （切空间、换显示器、窗口被别的程序移动）。可见时才算，两次 AX 读取。
        if panel?.isVisible == true { reposition() }
        switch NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
        case "com.apple.finder":
            // 从别处回到 Finder：**忘掉上一次的选中项**，否则「选中项没变」那一条
            // 会让药丸再也不出现（去 PS 改完图回来正是这条路）。
            if mode != .finder { mode = .finder; lastSelection = [] }
            tickFinder()
        case Photoshop.bundleID:
            if mode != .photoshop { mode = .photoshop; hide() }
            tickPhotoshop()
        default:
            if !lastSelection.isEmpty || panel?.isVisible == true { leave() }
        }
    }

    /// PS 这头一个字都不问它（见文件头最后一条），只看自己记的账。
    private func tickPhotoshop() {
        guard photoshopSideEnabled, Photoshop.remaining > 0 else { hide(); return }
        show(title: Photoshop.busy ? "存回中…" : "存回原位 · 还剩 \(Photoshop.remaining) 张",
             tip: "把 Photoshop 当前这张拼合、按它自己的原路径覆盖存回，然后关掉 —— "
                + "不用再在存储对话框里找那个素材文件夹。快捷键 "
                + KeySymbols.describe(
                    flags: CGEventFlags(rawValue: UInt64(Store.shared.settings.psSaveBackModifierFlags)),
                    keyCode: CGKeyCode(Store.shared.settings.psSaveBackKeyCode))
                + "。不想要它浮出来：设置 → 素材批次里关掉。")
    }

    private func tickFinder() {
        guard finderSideEnabled else { hide(); return }
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
            // 🔴 数「几件」要往上跳**两层**：图在 `<商品>/主图/` 和 `<商品>/主图1比1/` 里，
            //    只跳一层数出来的是子目录数（每件两个），写在药丸上就成了件数翻倍。
            let products = Set(images.map {
                $0.deletingLastPathComponent().deletingLastPathComponent().path
            }).count
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                guard self.mode == .finder else { return }
                guard !images.isEmpty, paths != acted else { self.hide(); return }
                self.pending = paths
                // 一件商品现在开两张（3 比 4 一张、1 比 1 一张），所以「几件」和「几张」都得写；
                // 只选中一件、或者只选中单张图时两个数一样，那就只写张数。
                let title = images.count == products
                    ? "主图丢进 PS · \(images.count) 张"
                    : "主图丢进 PS · \(products) 件 \(images.count) 张"
                self.show(title: title,
                          tip: "把选中的商品文件夹里的「主图」全部在 Photoshop 里打开。"
                             + "不想要它浮出来：设置 → 素材批次里关掉。")
            }
        }
    }

    // MARK: - 那颗药丸

    private func show(title: String, tip: String) {
        // 贴谁走。幂等，换了宿主（访达 ↔ PS）也是在这儿切过去的 —— 放在下面那条
        // 提前返回**之前**：文案没变但宿主换了的时候，返回了就还贴在上一个窗口上。
        follow.follow(hostBundleID)
        // 🔴 PS 那头是**每一跳都会调到这儿**的（数字来自本地记账，不问 PS）。
        //    文字没变、药丸还在屏幕上，就一个字都别动 —— 否则每 1.5 秒重摆一次窗口、刷一行日志。
        if title == shownTitle, panel?.isVisible == true { return }
        shownTitle = title
        let panel = self.panel ?? makePanel()
        button?.toolTip = tip
        button?.isEnabled = !(mode == .photoshop && Photoshop.busy)
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
        // 药丸不在屏幕上就没人需要知道窗口动了 —— 注册着的通知全撤掉，回到零负载。
        follow.stop()
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
        p.contentView = blur
        panel = p
        button = b
        return p
    }

    @objc private func act() {
        switch mode {
        case .finder:
            let paths = pending
            actedSelection = paths
            hide()
            MainImages.openInPhotoshop(paths)
        case .photoshop:
            // 不 hide()：存回是有来有回的，药丸要留着显示「存回中…」和剩下几张。
            Photoshop.saveBackFront()
        }
    }

    // MARK: - 摆哪儿

    /// 窗口动了就把药丸挪过去。药丸不在屏幕上时什么都不做。
    private func reposition() {
        guard let panel, panel.isVisible else { return }
        place(panel)
    }

    /// 贴在最前那个窗口的下缘内侧；拿不到窗口就贴当前屏幕右下。
    ///
    /// Finder 贴**右下角**（列表右边通常是空的）；PS 贴**下缘中间** ——
    /// 右下角是图层面板，左下角是缩放比例和文档大小，中间那条状态栏才是空的。
    ///
    /// 坐标换算在 `WindowFollow` 里做（AX 是主屏左上角原点、y 向下）；这儿只管贴哪个角，
    /// 最后一定要夹回可见区域 —— 窗口被拖到屏幕边上时，药丸会算到屏幕外面去。
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        var origin: NSPoint
        // 正在跟的那个窗口优先（通知回调里它已经是最新的），还没开始跟就现查一次
        if let rect = follow.frame ?? WindowFollow.frontWindowFrame(of: hostBundleID) {
            origin = mode == .finder
                ? NSPoint(x: rect.maxX - size.width - 18, y: rect.minY + 18)
                : NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 34)
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
        // 没挪窝就别叫 setFrameOrigin：拖窗时通知一秒好几十条，每条都重设一次
        // 会让这颗浮窗自己抖起来。
        guard origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin)
    }
}
