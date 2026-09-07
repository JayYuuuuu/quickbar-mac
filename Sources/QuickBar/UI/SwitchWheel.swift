import AppKit

/// 三向甩的那块浮窗：按住 ⌥ 敲一下 Tab 弹出，手往一个方向甩，松开 ⌥ 切过去。
///
/// 【为什么它一个鼠标事件都不接】`ignoresMouseEvents = true` —— 选中哪一格纯靠算角度。
/// 好处是它永远不抢焦点、不挡住底下的点击，松手就消失；桌面浮窗那个「站在内容区上一定挡东西」
/// 的老问题在这里根本不存在。（这条是从 PortManager 的轮盘上抄过来的形，不是抄它的样子。）
///
/// 【层级】`.screenSaver` + `.fullScreenAuxiliary`：**全屏应用之上也要叫得出来** ——
/// 而那正是最需要切换的时候。普通 `.floating` 会被全屏窗口盖住。
@MainActor
final class SwitchWheel {
    static let shared = SwitchWheel()

    private var panel: NSPanel?
    private var view: WheelView?
    private var ticker: Timer?
    private var origin = CGPoint.zero
    private var targets: [SwitchLane: SwitchTarget] = [:]
    private var selected: SwitchLane?
    /// 这一轮的序号，异步补标题回来时用它认「还是不是同一次弹出」。
    private var round = 0
    /// 上一跳鼠标在哪。**鼠标没动就不重算** —— 不然键盘选的方向会被每 1/60 秒一次的
    /// 鼠标判定当场抹掉（手在键盘上时鼠标停在中心，算出来永远是「取消」）。
    private var lastMouse: CGPoint?

    // 展开态（甩到一格停住不松手，那一类摊开成一列）
    private var expandedLane: SwitchLane?
    private var members: [SwitchTarget] = []
    private var memberIndex = 0
    /// 展开之后判定用的原点 = 第一行的中心。
    private var listOrigin = CGPoint.zero
    /// 手停在当前这一格上多久了。
    private var hoverSince = CFAbsoluteTimeGetCurrent()
    /// 正在后台取成员的那一格，别重复发。
    private var expanding: SwitchLane?

    /// 停多久才摊开。太短会「只是路过也弹一堆东西出来」，太长人以为它不支持。
    private static let expandDelay: CFTimeInterval = 0.45

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    // MARK: - 弹出

    func show() {
        let mouse = NSEvent.mouseLocation
        round &+= 1
        let myRound = round

        targets = WindowSwitch.shared.targets()
        selected = nil
        expandedLane = nil
        members = []
        memberIndex = 0
        expanding = nil
        hoverSince = CFAbsoluteTimeGetCurrent()

        let panel = ensurePanel()
        // 面板按 anchor（「取消」块的中心）摆到鼠标上，不是按面板中心 —— 理由见 WheelGeo.anchor。
        let anchor = WheelGeo.anchor
        let frame = clamp(NSRect(x: mouse.x - anchor.x, y: mouse.y - anchor.y,
                                 width: WheelGeo.panelSize.width, height: WheelGeo.panelSize.height),
                          near: mouse)
        origin = CGPoint(x: frame.minX + anchor.x, y: frame.minY + anchor.y)
        panel.setFrame(frame, display: false)
        view?.update(targets: targets, selected: nil)
        panel.orderFrontRegardless()

        lastMouse = mouse
        startTicking()
        fetchDetails(round: myRound)
    }

    /// 松开修饰键：切过去。
    func commit() {
        guard isShowing else { return }
        let lane = selected
        let expanded = expandedLane
        let picked = members.indices.contains(memberIndex) ? members[memberIndex] : nil
        hide()

        // 摊开着的时候，选的是那一列里的某一行，不是格子本身。
        if let expanded, let picked {
            Notify.log("三向甩✓ 摊开的 \(expanded.title) 里选了 \(picked.badge ?? "—")：\(picked.label)(\(picked.pid))")
            WindowSwitch.activate(picked)
            return
        }

        guard let lane else { return }
        if let target = targets[lane] {
            Notify.log("三向甩✓ 切到 \(target.caption(lane))：\(target.label)(\(target.pid))")
            WindowSwitch.activate(target)
        } else if lane == .finder {
            // 访达一个窗口都没开也要给人开一个，否则就是「甩了没反应」。
            WindowSwitch.activateFinder()
        }
    }

    func cancel() { hide() }

    private func hide() {
        ticker?.invalidate()
        ticker = nil
        panel?.orderOut(nil)
    }

    // MARK: - 跟着鼠标走

    /// 🔴 **有界定时器，不是永动循环**：只在面板浮着的那一两秒里跑，松手即停。
    /// 用它而不是全局鼠标监听，是为了绕开「鼠标事件要不要额外权限」这个没量过的问题。
    private func startTicking() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard isShowing else { return }
        let mouse = NSEvent.mouseLocation
        let moved = lastMouse.map { abs($0.x - mouse.x) >= 1 || abs($0.y - mouse.y) >= 1 } ?? true
        if moved { lastMouse = mouse }

        // 摊开着：上下选行；横向移出去就当人改主意了，收回三格。
        if let lane = expandedLane {
            guard moved else { return }
            if ListGeo.leftList(mouse, center: listOrigin) {
                collapse(back: lane)
                return
            }
            let i = ListGeo.index(at: mouse, center: listOrigin, count: members.count)
            guard i != memberIndex else { return }
            memberIndex = i
            view?.update(lane: lane, members: members, index: i)
            return
        }

        if moved {
            let lane = WheelGeo.lane(at: mouse, center: origin)
            if lane != selected {
                selected = lane
                hoverSince = CFAbsoluteTimeGetCurrent()
                view?.update(targets: targets, selected: lane)
            }
        }

        // 停住不动够久 → 把这一类摊开。
        if let lane = selected, expanding == nil,
           CFAbsoluteTimeGetCurrent() - hoverSince > Self.expandDelay {
            beginExpand(lane)
        }
    }

    // MARK: - 摊开 / 收回

    /// 🔴 **成员列表在后台读**：要枚举 AX 窗口、还要读「窗口」菜单，都是跨进程 IPC。
    /// 读完回来才换版式；这中间人要是把手移开了，就当没发生过。
    private func beginExpand(_ lane: SwitchLane) {
        expanding = lane
        let myRound = round
        let apps = WindowSwitch.shared.apps(of: lane)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = WindowSwitch.members(of: lane, apps: apps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.round == myRound, self.isShowing,
                          self.selected == lane, self.expandedLane == nil else { return }
                    // 只有一个成员时摊开跟不摊开是同一件事，别白闪一下。
                    guard list.count >= 2 else { return }
                    self.showList(lane, list)
                }
            }
        }
    }

    private func showList(_ lane: SwitchLane, _ list: [SwitchTarget]) {
        members = list
        memberIndex = 0
        expandedLane = lane

        // 第一行落在鼠标现在这儿 —— 手不动选的还是原来那个，往下移才是第二个。
        let mouse = NSEvent.mouseLocation
        let size = ListGeo.panelSize(list.count)
        let anchor = ListGeo.anchor(list.count)
        let frame = clamp(NSRect(x: mouse.x - anchor.x, y: mouse.y - anchor.y,
                                 width: size.width, height: size.height), near: mouse)
        listOrigin = CGPoint(x: frame.minX + anchor.x, y: frame.minY + anchor.y)
        lastMouse = mouse
        panel?.setFrame(frame, display: true)
        view?.update(lane: lane, members: list, index: 0)
        Notify.log("三向甩▸ 摊开 \(lane.title) \(list.count) 个：" +
                   list.prefix(6).map { "\($0.badge ?? "—")/\($0.label)" }.joined(separator: " | "))
    }

    private func collapse(back lane: SwitchLane) {
        expandedLane = nil
        members = []
        memberIndex = 0
        // 收回之后允许再摊开一次 —— 人横向甩出去往往只是想换一格。
        expanding = nil
        hoverSince = CFAbsoluteTimeGetCurrent()

        let mouse = NSEvent.mouseLocation
        let anchor = WheelGeo.anchor
        let frame = clamp(NSRect(x: mouse.x - anchor.x, y: mouse.y - anchor.y,
                                 width: WheelGeo.panelSize.width, height: WheelGeo.panelSize.height),
                          near: mouse)
        origin = CGPoint(x: frame.minX + anchor.x, y: frame.minY + anchor.y)
        selected = WheelGeo.lane(at: mouse, center: origin)
        panel?.setFrame(frame, display: true)
        view?.update(targets: targets, selected: selected)
    }

    /// 方向键也能选。
    ///
    /// 🔴 **这条不是锦上添花**：主场景是「文档里 ⌘C 复制，切到浏览器 ⌘V 粘贴」——
    /// 按 ⌘C 的时候两只手都在键盘上，鼠标离得远。只有鼠标能选的话，这个功能在它
    /// 最该派上用场的那一刻正好用不了。
    func press(_ arrow: Keyboard.SwitchArrow) {
        guard isShowing else { return }
        // 摊开着的时候方向键换意思：↑↓ 在列表里走，← 收回三格。
        if let expanded = expandedLane {
            switch arrow {
            case .up: memberIndex = max(memberIndex - 1, 0)
            case .down: memberIndex = min(memberIndex + 1, max(members.count - 1, 0))
            case .left: collapse(back: expanded); return
            case .right: return
            }
            view?.update(lane: expanded, members: members, index: memberIndex)
            return
        }
        selected = arrow.lane
        hoverSince = CFAbsoluteTimeGetCurrent()
        view?.update(targets: targets, selected: selected)
    }

    // MARK: - 标题

    /// 三格的窗口标题和店名都在后台读，读到了再换上去。**弹出这一路上不能等它** ——
    /// AX 是跨进程 IPC，对面卡住就跟着卡，而这个面板的全部价值就在于「按下就在」。
    private func fetchDetails(round myRound: Int) {
        let snapshot = targets
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var titles: [SwitchLane: String] = [:]
            var badges: [SwitchLane: String] = [:]
            for (lane, target) in snapshot {
                if let raw = WindowSwitch.windowTitle(pid: target.pid) {
                    titles[lane] = WindowSwitch.trim(raw, appName: target.appName)
                }
                if lane == .browser, let label = BrowserPorts.info(pid: target.pid)?.label {
                    badges[lane] = label
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.round == myRound, self.isShowing else { return }
                    for (lane, title) in titles { self.targets[lane]?.windowTitle = title }
                    for (lane, badge) in badges { self.targets[lane]?.badge = badge }
                    self.view?.update(targets: self.targets, selected: self.selected)
                    // 🔴 唯一的观测口。这块浮窗**远程截不到屏**（ssh 里 screencapture 报错），
                    //    格子上到底写了什么、店名认没认出来，只能靠这一行看。
                    let dump = SwitchLane.allCases.compactMap { lane -> String? in
                        guard let t = self.targets[lane] else { return "\(lane.title)=—" }
                        return "\(t.caption(lane))=\(t.label)(\(t.pid))"
                    }.joined(separator: "  ")
                    Notify.log("三向甩→ \(dump)")
                }
            }
        }
    }

    // MARK: - 面板

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let v = WheelView(frame: NSRect(origin: .zero, size: WheelGeo.panelSize))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: WheelGeo.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        p.contentView = v
        panel = p
        view = v
        return p
    }

    /// 弹在鼠标位置，但整块要留在屏幕里 —— 贴边弹出会把一两格顶出屏幕，那两个方向就甩不到了。
    /// 被推回来之后判定原点跟着走（`origin` 从摆好的 frame 反推），所以推回来也不会指错格子。
    private func clamp(_ frame: NSRect, near point: CGPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        let m: CGFloat = 8
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX + m), visible.maxX - f.width - m)
        f.origin.y = min(max(f.minY, visible.minY + m), visible.maxY - f.height - m)
        return f
    }
}

// MARK: - 几何（纯函数，好验）

/// 版式和方向判定**在同一处**算。分成两处必然漂移，而漂移的表现是
/// 「看着指着左边那格，松手却切去了别处」——人只会觉得它随机。
enum WheelGeo {
    static let cell = CGSize(width: 200, height: 58)
    static let gap: CGFloat = 10
    static let pad: CGFloat = 14

    static var panelSize: CGSize {
        CGSize(width: cell.width * 3 + gap * 2 + pad * 2,
               height: cell.height * 2 + gap + pad * 2)
    }

    /// 🔴 **判定原点是「取消」那一块的中心，不是面板中心。**
    /// 布局是「左 / 取消 / 右」一行 + 「文档」压在上面一行，所以面板的几何中心
    /// 比取消块高出半格 —— 拿它当原点的话，人往**正左**甩，落点在左格上边缘之外，
    /// 看着指着那一格、算出来却不是它。面板也是按这个点摆的（见 `SwitchWheel.show`）。
    static var anchor: CGPoint {
        CGPoint(x: pad + cell.width * 1.5 + gap, y: pad + cell.height / 2)
    }

    /// 格子在面板坐标里的位置。上格在中间列的上一行，左右格和「取消」在下一行。
    static func rect(for lane: SwitchLane?) -> CGRect {
        let col: CGFloat, row: CGFloat
        switch lane {
        case .browser: col = 0; row = 0
        case .finder: col = 2; row = 0
        case .document: col = 1; row = 1
        case nil: col = 1; row = 0            // 中间那格 = 取消
        }
        return CGRect(x: pad + col * (cell.width + gap),
                      y: pad + row * (cell.height + gap),
                      width: cell.width, height: cell.height)
    }

    /// 「取消」画得比一格小一圈：它不是第四个选项，只是「手别动就什么都不发生」。
    static var cancelRect: CGRect {
        let c = rect(for: nil)
        return CGRect(x: c.midX - 44, y: c.midY - 17, width: 88, height: 34)
    }

    /// 屏幕坐标（y 向上）→ 哪一格。`center` 是 `anchor` 落在屏幕上的那个点。
    ///
    /// 两段判定，缺一不可：
    /// - 鼠标**还在面板上**时按格子的矩形算 —— 看到哪格亮就是哪格，一个像素都不差。
    /// - 甩出面板之后按角度算 —— 甩得快必然冲出去，那才是常态。
    static func lane(at p: CGPoint, center: CGPoint) -> SwitchLane? {
        let d = CGPoint(x: p.x - center.x + anchor.x, y: p.y - center.y + anchor.y)

        for lane in SwitchLane.allCases where rect(for: lane).contains(d) { return lane }
        if cancelRect.insetBy(dx: -8, dy: -6).contains(d) { return nil }

        let dx = p.x - center.x, dy = p.y - center.y
        let deg = atan2(dy, dx) * 180 / .pi          // -180…180，0 = 右
        // 🔴 **不是四等分**：左右两格视觉上各占面板三分之一宽、还一直延伸到屏幕两侧，
        //    上格只在中间那一列。四等分的话「往右上一甩」会落进「上」，跟眼睛看到的对不上
        //    （45° 正好压在分界线上，实测断言就是在这儿翻的）。把「上」收窄到 70°。
        switch deg {
        case -55..<55: return .finder                // 右
        case 55..<125: return .document              // 上
        case 125...180, -180 ..< -125: return .browser  // 左
        default: return nil                           // 下半区 = 取消
        }
    }
}

/// 展开之后那一列的版式和判定。跟 `WheelGeo` 一样，**两件事在同一处算**。
enum ListGeo {
    static let width: CGFloat = 460
    static let rowH: CGFloat = 36
    static let headerH: CGFloat = 26
    static let pad: CGFloat = 8
    /// 再多就超出屏幕了，而且十几行也不是「甩一下」该干的事。
    static let maxRows = 12

    static func rows(_ count: Int) -> Int { min(max(count, 1), maxRows) }

    static func panelSize(_ count: Int) -> CGSize {
        CGSize(width: width, height: pad * 2 + headerH + CGFloat(rows(count)) * rowH)
    }

    /// 🔴 **anchor 是第一行的中心**，也就是「展开那一刻鼠标在哪」。
    /// 这样展开**不改变默认选中的是谁** —— 手不动还是那一类里最近的那个，
    /// 往下移才是第二个、第三个。展开只是把更多选项排在下面，不是换了一套东西。
    static func anchor(_ count: Int) -> CGPoint {
        CGPoint(x: width / 2, y: panelSize(count).height - pad - headerH - rowH / 2)
    }

    static func rowRect(_ index: Int, count: Int) -> CGRect {
        let h = panelSize(count).height
        return CGRect(x: pad, y: h - pad - headerH - CGFloat(index + 1) * rowH,
                      width: width - pad * 2, height: rowH)
    }

    /// 屏幕坐标 → 第几行。`center` 是 anchor 落在屏幕上的那个点。
    static func index(at p: CGPoint, center: CGPoint, count: Int) -> Int {
        let steps = Int(((center.y - p.y) / rowH).rounded())
        return min(max(steps, 0), max(count - 1, 0))
    }

    /// 横向移出这么远就当人改主意了，收回三格。
    static func leftList(_ p: CGPoint, center: CGPoint) -> Bool {
        abs(p.x - center.x) > width / 2 + 60
    }
}

// MARK: - 画

private final class WheelView: NSView {

    static var panelSize: CGSize { WheelGeo.panelSize }

    private let backdrop = NSVisualEffectView()
    /// 🔴 **格子不能画在 `self` 上** —— AppKit 把子视图排在宿主自己的绘制**之上**，
    ///    毛玻璃那块子视图会把整块格子盖得一干二净（离屏渲染出来是一整块灰板，
    ///    实机上更看不出来）。这跟 `PillView` 那条「自绘的层不能直接 addSublayer」
    ///    是同一个坑的第二个版本：**顺序只由子视图数组说了算**，所以画的那半
    ///    必须是排在 `backdrop` 之后的另一个子视图。
    private let paint = CellsView()
    /// 展开之后那一列。跟三格是两块视图，靠 `hidden` 换 —— 同一块视图画两种版式，
    /// 迟早会在某个状态下画串。
    private let listPaint = ListView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 18
        backdrop.layer?.masksToBounds = true
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        for v in [paint as NSView, listPaint as NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        listPaint.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(targets: [SwitchLane: SwitchTarget], selected: SwitchLane?) {
        paint.isHidden = false
        listPaint.isHidden = true
        paint.targets = targets
        paint.selected = selected
        paint.needsDisplay = true
    }

    func update(lane: SwitchLane, members: [SwitchTarget], index: Int) {
        paint.isHidden = true
        listPaint.isHidden = false
        listPaint.lane = lane
        listPaint.members = members
        listPaint.index = index
        listPaint.needsDisplay = true
    }
}

/// 展开之后那一列：一行一个落点。
private final class ListView: NSView {

    var lane: SwitchLane = .browser
    var members: [SwitchTarget] = []
    var index = 0

    override var isFlipped: Bool { false }

    /// 🔴 **那一列只在它能区分行与行的时候才存在。** 访达的窗口没有店名，
    /// 一整列「—」白占 76pt 还把文件夹名挤到右边去；同一个 WPS 里的几个文档，
    /// 那一列会是三个一模一样的「wpsoffice」。都是"有一列"比"没有"更糟。
    private var showsBadge: Bool {
        Set(members.map { $0.badge ?? "" }).count > 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = ListGeo.rows(members.count)
        let title = "\(lane.title) · \(members.count) 个"
        drawText(title,
                 in: NSRect(x: ListGeo.pad + 12, y: bounds.height - ListGeo.pad - 20,
                            width: bounds.width - ListGeo.pad * 2 - 24, height: 16),
                 font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)

        for i in 0..<count {
            let r = ListGeo.rowRect(i, count: members.count)
            let m = members[i]
            let on = i == index

            if on {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1), xRadius: 8, yRadius: 8).fill()
            }

            var x = r.minX + 10
            if let icon = m.icon {
                icon.draw(in: NSRect(x: x, y: r.midY - 9, width: 18, height: 18),
                          from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            x += 18 + 9

            // 店名那一列固定宽度，好让眼睛顺着一条竖线往下扫 —— 那一列才是人真正在找的东西。
            if showsBadge {
                let badgeW: CGFloat = 76
                drawText(m.badge ?? "—",
                         in: NSRect(x: x, y: r.midY - 8, width: badgeW, height: 16),
                         font: .systemFont(ofSize: 12, weight: .semibold),
                         color: on ? .white : .labelColor)
                x += badgeW + 10
            }

            drawText(m.label,
                     in: NSRect(x: x, y: r.midY - 8, width: r.maxX - 10 - x, height: 16),
                     font: .systemFont(ofSize: 12, weight: showsBadge ? .regular : .medium),
                     color: on ? .white : .labelColor)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}

/// 三格 + 中间那个取消。只管画。
private final class CellsView: NSView {

    var targets: [SwitchLane: SwitchTarget] = [:]
    var selected: SwitchLane?

    override var isFlipped: Bool { false }

    private func rect(for lane: SwitchLane?) -> NSRect { WheelGeo.rect(for: lane) }

    override func draw(_ dirtyRect: NSRect) {
        for lane in SwitchLane.allCases { drawCell(lane) }
        drawCancel()
    }

    private func drawCell(_ lane: SwitchLane) {
        let r = rect(for: lane)
        let on = selected == lane
        let target = targets[lane]
        let has = target != nil || lane == .finder

        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        if on {
            (has ? NSColor.controlAccentColor : NSColor.systemGray).setFill()
            path.fill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        var textX = r.minX + 11
        if let icon = target?.icon {
            let box = NSRect(x: textX, y: r.midY - 12, width: 24, height: 24)
            icon.draw(in: box, from: .zero, operation: .sourceOver,
                      fraction: has ? 1.0 : 0.45, respectFlipped: true, hints: nil)
            textX = box.maxX + 8
        }
        let textW = r.maxX - 11 - textX
        guard textW > 20 else { return }

        let primary: NSColor = on ? .white : (has ? .labelColor : .tertiaryLabelColor)
        let secondary: NSColor = on ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor

        draw(target?.caption(lane) ?? lane.title,
             at: NSRect(x: textX, y: r.midY + 1, width: textW, height: 15),
             font: .systemFont(ofSize: 10.5, weight: .medium), color: secondary)
        draw(target?.label ?? lane.emptyHint,
             at: NSRect(x: textX, y: r.midY - 17, width: textW, height: 17),
             font: .systemFont(ofSize: 12.5, weight: .semibold), color: primary)
    }

    private func drawCancel() {
        let r = WheelGeo.cancelRect
        let on = selected == nil
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(on ? 0.13 : 0.05).setFill()
        path.fill()

        let color: NSColor = on ? .secondaryLabelColor : .tertiaryLabelColor
        draw("✕  取消", at: NSRect(x: r.minX, y: r.midY - 8, width: r.width, height: 17),
             font: .systemFont(ofSize: 12, weight: .medium), color: color, centered: true)
    }

    private func draw(_ text: String, at rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}
