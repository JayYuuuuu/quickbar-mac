import AppKit

/// 去水印那道工序两头的那颗小药丸。同一颗，看你人在哪儿：
///
/// · **在 Finder 里**选中了商品文件夹 → 「主图丢进 PS · 3 件 6 张」，点一下全打开；
/// · **在 Photoshop 里**还有没存回的图 → 「存回原位 · 还剩 12 张」，点一下把当前这张
///   拼合、按原路径覆盖存回、关掉（见 Core/Photoshop.swift）。
///
/// 【为什么是同一颗】它俩是一件事的两头：丢进去、改完存回来。分成两个浮窗只会让人
/// 多记一样东西，而这两个状态在时间上根本不重叠 —— 人不可能同时站在 Finder 和 PS 里。
///
/// 长相在 `UI/PillView.swift`（照着设计稿 `QuickBar 快捷条.dc.html` 的 `1d Pill` 做的），
/// 这里只管**什么时候出现、贴在哪儿、点下去干什么**。
///
/// 【只在"点了真的有事发生"的时候出现】Finder 那头的显示条件不是"在素材目录里"，而是
/// **选中的东西真的解析出了主图**（`MainImages.collect` 说有几张就是几张）；
/// PS 那头是**这一趟确实往里丢过图、还没全存回**（`Photoshop.remaining > 0`）。
/// 🔴 有意不加"必须在 `_采集` 树下"这种路径闸门：素材被复制到别处照样能用，
///    而看不见的显示条件只会变成"它怎么不出来"——那种问题从外面永远查不出。
///
/// 【四个不能踩的点】
/// 🔴 **问 Finder 要选中项的那一发不许在后台队列**：`NSAppleScript` 在非主线程上
///    **一声不响地返回空** —— 药丸从不出现、日志一行没有（2026-08-24 实测，白查了一轮）。
/// 🔴 **只在宿主应用在最前时轮询**，别的时候一个定时器都不留（这软件平时是零负载的）。
/// 🔴 **选中项没变就什么都不做**：变了才去数图（数图要 readdir，素材盘是 SMB，一次几十毫秒）。
/// 🔴 **PS 那头一发 AE 都不问**：心跳里绝不去问 Photoshop「你开着几个文档」——
///    它正压着模态框时那一发要等到它闲下来（实测能等 40 秒以上，见 Photoshop.swift 文件头）。
///    数字由 QuickBar 自己记（丢进去几张），每存回一张拿 PS 回的真实数校准一次。
final class MainImagesPill {

    /// 药丸此刻在替哪一头说话。
    private enum Mode { case finder, photoshop }

    static let shared = MainImagesPill()

    private var panel: NSPanel?
    private var pill: PillView?
    private var timer: Timer?
    /// 专门数图的串行队列（readdir，素材盘是 SMB）。
    private let probe = DispatchQueue(label: "quickbar.mainimages.probe", qos: .utility)
    private var probing = false

    /// 上一次看到的选中项（用来判"变没变"）。
    private var lastSelection: [String] = []
    /// 已经点过的那一组：点完不再为同一组选中项弹出来 —— 否则手还在那个位置、
    /// 药丸立刻又冒出来，很容易再点一下把同一批图重复丢进 PS。
    ///
    /// 🔴 **这条只该管一小会儿。** 第一版让它一直管到「选中项变了」为止，结果是
    ///    从 PS 回到访达、那个文件夹还选着，药丸就再也不出来了（用户 2026-08-25 反馈）。
    ///    现在三个条件任意一个成立就重新武装：**选中项换成了别的**（防重复那条使命就完成了，
    ///    这条最要紧 —— 少了它，切走再切回来还是不弹）、**从别的应用回到访达**
    ///    （那是明确的新回合，也正是「丢进 PS → 改完 → 回来」这条路），或者**过了 20 秒**。
    ///    不用更短的纯计时是因为 PS 冷启动能要十几秒 —— 那期间药丸弹回来，
    ///    再点一下 `remaining` 就会多记一遍，计数当场就错了。
    private var actedSelection: [String] = []
    private var actedAt = Date.distantPast
    private static let reArm: TimeInterval = 20
    /// 当前这组选中项对应的主图（点下去就开这些的父级路径）。
    private var pending: [String] = []
    private var mode: Mode = .finder
    /// 药丸上现在写着什么。用来判「要不要重画」。
    private var shownTitle = ""
    /// 贴着谁走。窗口一动就把药丸挪过去（见 Core/WindowFollow.swift）。
    private let follow = WindowFollow()

    // 访达那头：**有人动了才去问它**（见 `noteUserInput`）
    /// 上一次输入之后还没查过访达。
    private var selectionDirty = true
    private var lastFinderProbe = Date.distantPast
    private var inputProbe: DispatchWorkItem?
    /// 兜底轮询间隔。
    ///
    /// 事件 tap 看得见点击和按键，所以拖放（有 `leftMouseUp`）、右键、方向键、打字选中
    /// 全都不用轮询也能覆盖；别的应用「在访达中显示」某个文件会把访达激活，激活通知也接住了。
    /// **真正漏掉的只有一类**：脚本 `tell application "Finder" to select …`，
    /// 而且访达当时已经在最前。就为这一类留着这条慢轮询。
    ///
    /// 🔴 **它只负责「药丸出现得早一点」，不再负责正确性** —— 点下去那一刻会现查一次
    ///    （见 `act`），所以哪怕这里漏了，也不会拿过期的路径去开图。正因为如此它才敢放到 30 秒：
    ///    30 秒一次 ≈ 0.1% 单核，而原来每 1.5 秒一次是 1.6%。
    private static let finderFallbackPoll: TimeInterval = 30
    /// 输入之后隔多久去问一次。太短会在连点里问好几遍，太长人就觉得"慢半拍"。
    private static let inputDebounce: TimeInterval = 0.12

    // 进出节奏（设计稿「实现侧 · 进出节奏」那张便签）
    /// 进场前先等一下，等完再确认条件仍成立 —— 心跳 1.5 秒一跳，不等的话
    /// 鼠标扫过一串文件夹就会连闪好几颗。
    private static let enterDelay: TimeInterval = 0.4
    /// 同一个宿主窗口这么久之内不重播进场动画，只把文字淡一下。
    private static let calmWindow: TimeInterval = 3
    private var pendingShow: DispatchWorkItem?
    private var shownAt = Date.distantPast
    private var shownHost = ""
    /// 存完最后一张之后「都存回了」停留多久。
    private static let doneLinger: TimeInterval = 0.6
    private var lastRemaining = 0
    private var doneTimer: Timer?

    private init() {}

    // MARK: - 生命周期

    func start() {
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
    ///    不在宿主里时这一跳只读一个属性就返回，代价接近零。
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

    /// 人敲了键 / 松开了鼠标。
    ///
    /// 【为什么用它当触发器】原来是每 1.5 秒无条件问一次访达「选中了什么」——
    /// 一次 AppleScript 往返约 24ms，**只要访达在最前就一直在花**（实测 1.6% 单核），
    /// 而且平均要等 0.75 秒才发现选中项变了，加上进场那 400ms，人点完到药丸浮出来要 1.2 秒。
    /// 两头都不划算。
    ///
    /// 访达里的选中项**只可能被点击或按键改变**，而事件 tap 本来就在看这两样。
    /// 于是改成：**没人动就一发 AE 都不发**；动了就防抖 120ms 之后查一次。
    /// 空闲开销归零，反应从 1.2 秒缩到约 0.5 秒。
    ///
    /// 🔴 **兜底轮询不能去掉**：脚本改选中、拖放落点、别的应用代为操作，tap 都看不到。
    ///    8 秒一次，是原来的 1/6。
    /// 🔴 **tap 没在跑时要退回原来的轮询**：人可以在菜单里「暂停触发」，那时候 tap 是关的，
    ///    只靠 8 秒兜底会让药丸慢得像坏了。
    func noteUserInput() {
        guard enabled, mode == .finder else { return }
        selectionDirty = true
        inputProbe?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        inputProbe = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputDebounce, execute: work)
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
            if mode != .finder {
                // 从别的应用回到访达 = 新回合：忘掉上一次的选中项（否则「没变」这条
                // 会让药丸不再出现），也把「点过了」这条解除。
                mode = .finder
                lastSelection = []
                selectionDirty = true
                actedSelection = []
            }
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
        guard photoshopSideEnabled else { hide(); return }
        let left = Photoshop.remaining

        // 最后一张存完的那一下：先说一句「都存回了」，停 0.6 秒再收 ——
        // 直接消失的话人不知道刚才那一下到底成没成。
        if left == 0 {
            if lastRemaining > 0, panel?.isVisible == true, doneTimer == nil {
                lastRemaining = 0
                show(title: "都存回了", style: .done, fraction: 1,
                     tip: "这一批的主图都按原路径存回去了。")
                doneTimer = Timer.scheduledTimer(withTimeInterval: Self.doneLinger, repeats: false) {
                    [weak self] _ in
                    self?.doneTimer = nil
                    self?.hide()
                }
                return
            }
            if doneTimer == nil { hide() }
            return
        }

        lastRemaining = left
        let key = KeySymbols.describe(
            flags: CGEventFlags(rawValue: UInt64(Store.shared.settings.psSaveBackModifierFlags)),
            keyCode: CGKeyCode(Store.shared.settings.psSaveBackKeyCode))
        show(title: Photoshop.busy ? "存回中…" : "存回原位 · 还剩 \(left) 张",
             style: Photoshop.busy ? .busy : .action,
             fraction: CGFloat(Photoshop.fraction),
             tip: "把 Photoshop 当前这张拼合、按它自己的原路径覆盖存回，然后关掉 —— "
                + "不用再在存储对话框里找那个素材文件夹。快捷键 \(key)。"
                + "不想要它浮出来：设置 → 素材批次里关掉。")
    }

    private func tickFinder() {
        guard finderSideEnabled else { hide(); return }
        guard !probing else { return }
        // 🔴 **没人动就不问访达**（见 `noteUserInput`）。三种情况才放行：
        //    有输入 / 兜底间隔到了 / 事件 tap 没在跑（那就退回原来的每跳都问）。
        let now = Date()
        let mustPoll = !EventTapService.shared.isRunning
        if !selectionDirty, !mustPoll, now.timeIntervalSince(lastFinderProbe) < Self.finderFallbackPoll {
            return
        }
        selectionDirty = false
        lastFinderProbe = now
        // 一直待在访达里没走开的话，20 秒之后也放行 —— 不然「点过一次就永远不出来」。
        if !actedSelection.isEmpty, now.timeIntervalSince(actedAt) > Self.reArm {
            actedSelection = []
        }
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
                // 🔴 **选中项已经换成别的了 → 防重复那条使命完成，当场清掉。**
                //    不清的话它会一直记着那一组路径：你切去别的文件夹、再切回来，
                //    照样撞上，药丸对那个文件夹**永远不出来**（2026-08-25 用户实测）。
                //    而「PS 里正开着它的图、回头再丢一次」恰恰是常事。
                self.actedSelection = []
                self.pending = paths
                // 一件商品开两张（3 比 4 一张、1 比 1 一张），所以「几件」和「几张」都得写；
                // 只选中一件、或者只选中单张图时两个数一样，那就只写张数。
                let title = images.count == products
                    ? "主图丢进 PS · \(images.count) 张"
                    : "主图丢进 PS · \(products) 件 \(images.count) 张"
                self.show(title: title, style: .action, fraction: 0,
                          tip: "把选中的商品文件夹里的「主图」全部在 Photoshop 里打开。"
                             + "不想要它浮出来：设置 → 素材批次里关掉。")
            }
        }
    }

    // MARK: - 出现和消失

    private func show(title: String, style: PillView.Style, fraction: CGFloat, tip: String) {
        // 贴谁走。幂等，换了宿主（访达 ↔ PS）也是在这儿切过去的 —— 放在下面那条
        // 提前返回**之前**：文案没变但宿主换了的时候，返回了就还贴在上一个窗口上。
        follow.follow(hostBundleID)
        // 宿主窗口进了程序坞，药丸不该还浮着（设计稿：宿主被遮挡/最小化即隐藏）。
        if follow.hostMinimized { hide(); return }

        let visible = panel?.isVisible == true
        if visible, title == shownTitle, style == currentStyle, abs(fraction - currentFraction) < 0.001 {
            return
        }
        currentStyle = style
        currentFraction = fraction
        shownTitle = title

        if visible {
            // 已经在屏幕上：只换内容，不重播进场（数字每存回一张就减一，重播会闪）。
            paint(title: title, style: style, fraction: fraction, tip: tip, animateText: true)
            return
        }

        // 🔴 **进场先等 400ms 再确认一次**：心跳 1.5 秒一跳、鼠标在 Finder 里扫过一串
        //    文件夹时选中项会连着变好几次，不等的话就是一串闪烁。等完之后条件不成立就不弹了。
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shownTitle == title else { return }
            self.reveal(title: title, style: style, fraction: fraction, tip: tip)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enterDelay, execute: work)
    }

    private var currentStyle: PillView.Style = .action
    private var currentFraction: CGFloat = 0

    private func reveal(title: String, style: PillView.Style, fraction: CGFloat, tip: String) {
        let panel = self.panel ?? makePanel()
        paint(title: title, style: style, fraction: fraction, tip: tip, animateText: false)
        place(panel)

        // 抖动保护：同一个宿主窗口 3 秒内不重播进场动画 —— 存回一张、药丸收掉又回来，
        // 每次都淡入一遍会像在闪。
        let calm = shownHost == hostBundleID && Date().timeIntervalSince(shownAt) < Self.calmWindow
        shownHost = hostBundleID
        shownAt = Date()

        if calm {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            // 进：opacity 0→1 + y +4→0，0.18s ease-out（设计稿「进出节奏」）
            let target = panel.frame.origin
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: target.x, y: target.y - 4))
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(target)
            }
        }
        // 唯一的观测口：这颗药丸弹在哪儿、写着什么。屏幕截不到的时候（远程排查）就靠它，
        // 而「它怎么没出来」正是最常见的一类提问。
        Notify.log("药丸 \(title) @ \(Int(panel.frame.origin.x)),\(Int(panel.frame.origin.y))")
    }

    private func paint(title: String, style: PillView.Style, fraction: CGFloat,
                       tip: String, animateText: Bool) {
        guard let panel, let pill else { return }
        pill.toolTip = tip
        pill.set(title: title, style: style, fraction: fraction, animateText: animateText)
        let size = pill.intrinsicContentSize
        if panel.frame.size != size {
            panel.setContentSize(size)
            place(panel)
        }
    }

    private func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        inputProbe?.cancel()
        inputProbe = nil
        doneTimer?.invalidate()
        doneTimer = nil
        shownTitle = ""
        follow.stop()          // 药丸不在屏幕上就没人需要知道窗口动了，回到零负载
        guard let panel, panel.isVisible else { return }
        // 出：opacity 1→0 + scale 1→.985，0.14s ease-in。**不做位移** —— 收起来的东西
        // 再把视线往下拉一下是白拉（设计稿「进出节奏」）。
        pill?.layer?.transform = CATransform3DMakeScale(0.985, 0.985, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let panel = self?.panel, panel.alphaValue < 0.01 else { return }
            panel.orderOut(nil)
            self?.pill?.layer?.transform = CATransform3DIdentity
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: PillView.height),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // 🔴 `.transient` 不能加：那会让它在宿主前台时也被系统收走。
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PillView(frame: NSRect(x: 0, y: 0, width: 180, height: PillView.height))
        view.onClick = { [weak self] in self?.act() }
        p.contentView = view

        panel = p
        pill = view
        return p
    }

    private func act() {
        switch mode {
        case .finder:
            // 🔴 **点下去这一刻现查一次。** 药丸上那组路径是上一次探测留下的；
            //    中间要是被脚本改过选中项，照着旧的开就是**开错东西** ——
            //    那比"慢半拍"严重得多。一发 AppleScript 约 24ms，人主动点的，无感。
            //    查到不一样就按**现在真正选中的**来（人的意图是"把我选中的这些丢进去"），
            //    数量对不上也不危险：`openInPhotoshop` 超过 30 张本来就会再问一声。
            //    拿不到（访达一个窗口都没有）才退回药丸上那组，绝不让这一下"没反应"。
            let fresh = FinderService.shared.selectionNow()
            let paths = fresh.isEmpty ? pending : fresh
            actedSelection = paths
            actedAt = Date()
            lastSelection = paths
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
        if follow.hostMinimized { hide(); return }
        place(panel)
    }

    /// 锚点来自设计稿「实现侧 · 附着与数据」：
    /// **访达 = 窗口右下角内侧 (−12, −12)；PS = 窗口下缘中线上方 10**
    /// （PS 右下是图层面板、左下是缩放比例，中间那条状态栏才是空的）。
    ///
    /// 坐标换算在 `WindowFollow` 里做（AX 是主屏左上角原点、y 向下）；这儿只管贴哪个角，
    /// 最后一定要夹回可见区域 —— 窗口被拖到屏幕边上时，药丸会算到屏幕外面去。
    private func place(_ panel: NSPanel) {
        let size = panel.frame.size
        var origin: NSPoint
        // 正在跟的那个窗口优先（通知回调里它已经是最新的），还没开始跟就现查一次
        if let rect = follow.frame ?? WindowFollow.frontWindowFrame(of: hostBundleID) {
            origin = mode == .finder
                ? NSPoint(x: rect.maxX - size.width - 12, y: rect.minY + 12)
                : NSPoint(x: rect.midX - size.width / 2, y: rect.minY + 10)
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
