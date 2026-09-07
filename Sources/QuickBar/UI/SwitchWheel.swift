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
        // 面板按 anchor（原点盘的中心）摆到鼠标上，不是按面板中心 —— 理由见 WheelGeo.anchor。
        let anchor = WheelGeo.anchor
        let frame = clamp(NSRect(x: mouse.x - anchor.x, y: mouse.y - anchor.y,
                                 width: WheelGeo.panelSize.width, height: WheelGeo.panelSize.height),
                          near: mouse)
        origin = CGPoint(x: frame.minX + anchor.x, y: frame.minY + anchor.y)
        panel.setFrame(frame, display: false)
        view?.update(targets: targets, selected: nil)
        panel.orderFrontRegardless()

        lastMouse = mouse
        playEntrance()
        startTicking()
        fetchDetails(round: myRound)
    }

    /// 入场：**从 anchor 那一点撑开**，不是从面板中心 —— 人的视线就落在鼠标那儿。
    /// 🔴 只给 70ms。在一秒出头的手势里占 7%，实测不拖手感；再长就开始有「等它」的感觉。
    private func playEntrance() {
        guard let layer = view?.layer else { return }
        let ap = CGPoint(x: WheelGeo.anchor.x / WheelGeo.panelSize.width,
                         y: WheelGeo.anchor.y / WheelGeo.panelSize.height)
        // 改 anchorPoint 会把 layer 挪走，position 要跟着补回来。
        layer.anchorPoint = ap
        layer.position = CGPoint(x: layer.bounds.width * ap.x, y: layer.bounds.height * ap.y)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        for a in [scale, fade] {
            a.duration = 0.07
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: a.keyPath)
        }
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
        let anchor = ListGeo.anchor(list.count, from: lane)
        let frame = clamp(NSRect(x: mouse.x - anchor.x, y: mouse.y - anchor.y,
                                 width: size.width, height: size.height), near: mouse)
        listOrigin = CGPoint(x: frame.minX + anchor.x, y: frame.minY + anchor.y)
        lastMouse = mouse
        panel?.setFrame(frame, display: true)
        view?.update(lane: lane, members: list, index: 0)
        crossFade(0.09)
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
        // 收回不做形变，直接交叉回去 —— 人这会儿是在改主意，形变只会挡路。
        crossFade(0.06)
    }

    /// 摊开 / 收回时的交叉淡入。
    /// 🔴 **面板的位置不跟着淡** —— frame 已经按 anchor 反推过，屏幕上那个点（鼠标）是不动的，
    /// 所以人看到的是「这一翼原地长成了一列」，不是「换了个东西」。
    private func crossFade(_ duration: CFTimeInterval) {
        guard let layer = view?.layer else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.25
        a.toValue = 1
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "opacity")
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
            case .down: memberIndex = min(memberIndex + 1, max(ListGeo.lastSelectable(members.count), 0))
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

/// 三向路标的**轮廓和判定是同一套数**。
///
/// 【为什么是这个形状】（设计稿 `design/QuickBar 三向甩.dc.html`）
/// 不再是三个格子，而是整块玻璃切成**一支双头箭头 ＋ 中间升起的尖塔**：
/// 左右两翼收成实体箭尖，上方那一类从箭杆里长出来。
/// 🔴 **塔的两条斜边就是 55° / 125° 判定边界本身** —— 看到的边和算出来的边是同一条线，
/// 指哪就落哪。方向暗示做进轮廓里，不靠额外画箭头；箭尖同时说明「这一翼一直延伸到屏幕那一侧」。
///
/// 🔴 **那四个塔顶/塔根的点必须现算，不能手抄常量。** 设计稿上手画的顶点写着
/// `238,9`，实测它到 anchor 是 **120.21°**，而不是稿子自己声称的 125°（塔根那两个是对的：
/// 125.34° / 54.66°）。抄下来就会漂，漂的表现是「看着指着一格、松手切去别处」——
/// 人只会觉得它很随机。稿子最后一条实现侧也是这么要求的。
/// `Packaging/VerifyWheelGeo.sh` 里有一条断言专门盯这个。
enum WheelGeo {
    static let panelSize = CGSize(width: 660, height: 222)

    /// 判定原点 = 原点盘的中心（AppKit 坐标，原点在左下）。
    /// 🔴 **不是面板的几何中心**（那是 (330,111)），差 56pt：塔压在上半部，箭杆在下半部，
    /// 而左右两翼必须跟原点同高。摆窗口时按它反推 frame，被 clamp 推回屏幕之后再从新 frame 反推回来。
    static let anchor = CGPoint(x: 330, y: 55)

    /// 箭杆的上边缘，也是塔根所在的高度。
    static let shaftTop: CGFloat = 110
    /// 原点盘直径。它的半径同时就是判定死区。
    static let disc: CGFloat = 46
    /// 四根辐条的长度（±55° / ±125° 四条判定边界的可见部分）。
    static let spoke: CGFloat = 67
    /// 箭尖那个钝尖的竖直高度。
    static let tipHeight: CGFloat = 14
    /// 箭尖根部相对面板左右边缘的内缩。
    static let tipInset: CGFloat = 12
    /// 塔顶两个外角的 45° 切角深度。
    static let cut: CGFloat = 9

    /// 扇区边界角。右 110° · 上 70° · 左 110° · 下 70°（取消）。
    /// 🔴 **不是四等分**：左右两翼视觉上一直延伸到屏幕两侧，上面那座塔只在中间。
    /// 四等分的话「往右上一甩」会落进「上」，跟眼睛看到的对不上。
    static let edge: CGFloat = 55

    // MARK: 由 anchor 和 55° 推出来的点

    /// 贴着判定线、在高度 y 上的 x。塔的斜边和两翼的上下沿走的就是它。
    ///
    /// 🔴 **按「到 anchor 的距离」算，不能直接代角度。** 四条边界是 ±55° / ±125°：
    /// anchor 上方那两条是 55°/125°，下方是 −55°/−125°。直接把 125° 代进公式，
    /// 在 anchor **下方**会把左边界算到右边去（断言当场抓到：翼下沿左算出 −55°）。
    /// 左右只由 `left` 决定，跟在 anchor 上边还是下边无关。
    static func edgeX(atY y: CGFloat, left: Bool) -> CGFloat {
        let cot = cos(edge * .pi / 180) / sin(edge * .pi / 180)
        let d = abs(y - anchor.y) * cot
        return left ? anchor.x - d : anchor.x + d
    }

    private static var cutY: CGFloat { panelSize.height - cut }

    /// 塔：从 anchor 起，沿两条判定线上去，顶上切两个 45° 角。
    static var towerPath: NSBezierPath {
        let p = NSBezierPath()
        p.move(to: anchor)
        p.line(to: CGPoint(x: edgeX(atY: shaftTop, left: true), y: shaftTop))
        p.line(to: CGPoint(x: edgeX(atY: cutY, left: true), y: cutY))
        p.line(to: CGPoint(x: edgeX(atY: cutY, left: true) + cut, y: panelSize.height))
        p.line(to: CGPoint(x: edgeX(atY: cutY, left: false) - cut, y: panelSize.height))
        p.line(to: CGPoint(x: edgeX(atY: cutY, left: false), y: cutY))
        p.line(to: CGPoint(x: edgeX(atY: shaftTop, left: false), y: shaftTop))
        p.close()
        return p
    }

    /// 一翼：从 anchor 沿两条判定线摊到箭杆的上下边，末端收成钝尖。
    static func wingPath(left: Bool) -> NSBezierPath {
        let w = panelSize.width
        let outer: CGFloat = left ? 0 : w
        let shoulder: CGFloat = left ? tipInset : w - tipInset
        let p = NSBezierPath()
        p.move(to: anchor)
        p.line(to: CGPoint(x: edgeX(atY: shaftTop, left: left), y: shaftTop))
        p.line(to: CGPoint(x: shoulder, y: shaftTop))
        p.line(to: CGPoint(x: outer, y: anchor.y + tipHeight / 2))
        p.line(to: CGPoint(x: outer, y: anchor.y - tipHeight / 2))
        p.line(to: CGPoint(x: shoulder, y: 0))
        p.line(to: CGPoint(x: edgeX(atY: 0, left: left), y: 0))
        p.close()
        return p
    }

    /// 塔在高度 y 上的可视宽度。**这不是审美选择，是 70° 扇区在那个高度上的真实宽度。**
    static func towerWidth(atY y: CGFloat) -> CGFloat {
        max(edgeX(atY: y, left: false) - edgeX(atY: y, left: true), 0)
    }

    static func path(for lane: SwitchLane) -> NSBezierPath {
        switch lane {
        case .browser: return wingPath(left: true)
        case .finder: return wingPath(left: false)
        case .document: return towerPath
        }
    }

    /// 整块玻璃的外轮廓 = 三块的并集，14 个顶点。用作毛玻璃的遮罩。
    static var outline: NSBezierPath {
        let w = panelSize.width, h = panelSize.height
        let lc = edgeX(atY: cutY, left: true), rc = edgeX(atY: cutY, left: false)
        let pts: [CGPoint] = [
            CGPoint(x: lc + cut, y: h), CGPoint(x: rc - cut, y: h),
            CGPoint(x: rc, y: cutY),
            CGPoint(x: edgeX(atY: shaftTop, left: false), y: shaftTop),
            CGPoint(x: w - tipInset, y: shaftTop),
            CGPoint(x: w, y: anchor.y + tipHeight / 2),
            CGPoint(x: w, y: anchor.y - tipHeight / 2),
            CGPoint(x: w - tipInset, y: 0),
            CGPoint(x: tipInset, y: 0),
            CGPoint(x: 0, y: anchor.y - tipHeight / 2),
            CGPoint(x: 0, y: anchor.y + tipHeight / 2),
            CGPoint(x: tipInset, y: shaftTop),
            CGPoint(x: edgeX(atY: shaftTop, left: true), y: shaftTop),
            CGPoint(x: lc, y: cutY),
        ]
        let p = NSBezierPath()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.line(to: pt) }
        p.close()
        return p
    }

    /// 屏幕坐标（y 向上）→ 哪一格。`center` 是 anchor 落在屏幕上的那个点。
    ///
    /// 轮廓已经严格贴着扇区，所以这里**只算角度**，不再需要「先矩形命中再角度」那套补丁：
    /// 可视范围不可能超出自己那个扇区。原点盘的半径就是死区。
    static func lane(at p: CGPoint, center: CGPoint) -> SwitchLane? {
        let dx = p.x - center.x, dy = p.y - center.y
        guard hypot(dx, dy) >= disc / 2 else { return nil }
        let deg = atan2(dy, dx) * 180 / .pi
        switch deg {
        case -edge..<edge: return .finder                       // 右 110°
        case edge..<(180 - edge): return .document              // 上 70°
        case (180 - edge)...180, -180 ..< -(180 - edge): return .browser   // 左 110°
        default: return nil                                     // 下 70° = 取消
        }
    }
}

/// 展开之后那一列的版式和判定。跟 `WheelGeo` 一样，**两件事在同一处算**。
enum ListGeo {
    static let width: CGFloat = 460
    static let rowH: CGFloat = 36
    static let headerH: CGFloat = 26
    static let pad: CGFloat = 8
    /// 来路那枚箭尖的深度。面板因此比内容区宽出这么多。
    static let tip: CGFloat = 14
    /// 再多就超出屏幕了，而且十几行也不是「甩一下」该干的事。
    static let maxRows = 12

    static func rows(_ count: Int) -> Int { min(max(count, 1), maxRows) }
    /// 超过 12 个时，最后一行让给「还有 N 个」——它不可选。
    static func truncated(_ count: Int) -> Bool { count > maxRows }
    /// 能选到的最大下标。截断时最后一行不算。
    static func lastSelectable(_ count: Int) -> Int {
        truncated(count) ? maxRows - 2 : rows(count) - 1
    }

    /// 内容区在面板里的左边距：从左翼来的话左边要留出箭尖。
    static func inset(from lane: SwitchLane) -> CGFloat { lane == .browser ? tip : 0 }

    static func panelSize(_ count: Int) -> CGSize {
        CGSize(width: width + tip, height: pad * 2 + headerH + CGFloat(rows(count)) * rowH)
    }

    /// 🔴 **anchor 是第一行的中心**，也就是「展开那一刻鼠标在哪」。
    /// 这样展开**不改变默认选中的是谁** —— 手不动还是那一类里最近的那个，
    /// 往下移才是第二个、第三个。展开只是把更多选项排在下面，不是换了一套东西。
    static func anchor(_ count: Int, from lane: SwitchLane) -> CGPoint {
        CGPoint(x: inset(from: lane) + width / 2,
                y: panelSize(count).height - pad - headerH - rowH / 2)
    }

    static func rowRect(_ index: Int, count: Int, from lane: SwitchLane) -> CGRect {
        let h = panelSize(count).height
        return CGRect(x: inset(from: lane) + pad, y: h - pad - headerH - CGFloat(index + 1) * rowH,
                      width: width - pad * 2, height: rowH)
    }

    /// 🔴 **列表左边（或右边、上边）留一枚箭尖，位置正对第一行的中心。**
    /// 它是「这一列是从那一翼长出来的」的唯一记号 —— 上一个状态的形状痕迹留在下一个状态里，
    /// 人就不会觉得界面被换掉了。访达在右翼所以箭尖镜像朝右，文档在上翼所以挪到顶边中点。
    static func outline(from lane: SwitchLane, count: Int) -> NSBezierPath {
        let size = panelSize(count)
        let a = anchor(count, from: lane)
        let r: CGFloat = 14
        let body: NSRect
        switch lane {
        case .browser: body = NSRect(x: tip, y: 0, width: width, height: size.height)
        case .finder: body = NSRect(x: 0, y: 0, width: width, height: size.height)
        case .document: body = NSRect(x: 0, y: 0, width: width, height: size.height - tip)
        }
        let path = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        let nib = NSBezierPath()
        switch lane {
        case .browser:
            nib.move(to: CGPoint(x: 0, y: a.y))
            nib.line(to: CGPoint(x: tip, y: a.y + tip))
            nib.line(to: CGPoint(x: tip, y: a.y - tip))
        case .finder:
            nib.move(to: CGPoint(x: size.width, y: a.y))
            nib.line(to: CGPoint(x: width, y: a.y + tip))
            nib.line(to: CGPoint(x: width, y: a.y - tip))
        case .document:
            nib.move(to: CGPoint(x: width / 2, y: size.height))
            nib.line(to: CGPoint(x: width / 2 - tip, y: size.height - tip))
            nib.line(to: CGPoint(x: width / 2 + tip, y: size.height - tip))
        }
        nib.close()
        path.append(nib)
        return path
    }

    /// 屏幕坐标 → 第几行。`center` 是 anchor 落在屏幕上的那个点。
    static func index(at p: CGPoint, center: CGPoint, count: Int) -> Int {
        let steps = Int(((center.y - p.y) / rowH).rounded())
        return min(max(steps, 0), max(lastSelectable(count), 0))
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
        applyMask(WheelGeo.outline, size: WheelGeo.panelSize)
    }

    func update(lane: SwitchLane, members: [SwitchTarget], index: Int) {
        paint.isHidden = true
        listPaint.isHidden = false
        listPaint.lane = lane
        listPaint.members = members
        listPaint.index = index
        listPaint.needsDisplay = true
        applyMask(ListGeo.outline(from: lane, count: members.count),
                  size: ListGeo.panelSize(members.count))
    }

    /// 🔴 **异形玻璃靠 `maskImage`，不能靠 `cornerRadius`。**
    /// 轮廓不是矩形，圆角那条路只能做矩形；而 `NSVisualEffectView` 的遮罩是
    /// 「哪儿不透明哪儿就有玻璃」，任意路径都行。
    /// 遮罩图的尺寸必须跟视图一样大、`capInsets` 留零，否则它会被九宫格拉伸。
    private func applyMask(_ path: NSBezierPath, size: CGSize) {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsetsZero
        backdrop.maskImage = image
    }
}

/// 展开之后那一列：一行一个落点。
private final class ListView: NSView {

    var lane: SwitchLane = .browser
    var members: [SwitchTarget] = []
    var index = 0

    override var isFlipped: Bool { false }

    /// 🔴 **那一列只在它能区分行与行的时候才存在。** 访达的窗口没有店名，
    /// 一整列破折号白占 76pt 还把文件夹名挤到右边去；同一个 WPS 里的几个文档，
    /// 那一列会是三个一模一样的名字。都是「有一列」比「没有」更糟。
    private var showsBadge: Bool {
        Set(members.map { $0.badge ?? "" }).count > 1
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 软件里真会出现的弱化文字用这一档，不用 `tertiaryLabelColor`。
    private var dim: NSColor {
        isDark ? NSColor(calibratedWhite: 0.74, alpha: 1) : NSColor(calibratedWhite: 0.36, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = ListGeo.inset(from: lane)
        let shown = ListGeo.rows(members.count)
        drawText("\(lane.title) · \(members.count) 个",
                 in: NSRect(x: inset + ListGeo.pad + 12, y: bounds.height - ListGeo.pad - 20,
                            width: ListGeo.width - ListGeo.pad * 2 - 24, height: 16),
                 font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)

        for i in 0..<shown {
            let r = ListGeo.rowRect(i, count: members.count, from: lane)
            // 🔴 截断行不可选：让人选中一行「什么都不会发生」的提示，比不给这行还糟。
            if ListGeo.truncated(members.count) && i == shown - 1 {
                drawTruncatedRow(r, remaining: members.count - i)
                continue
            }
            drawRow(r, members[i], on: i == index)
        }
    }

    private func drawRow(_ r: NSRect, _ m: SwitchTarget, on: Bool) {
        if on {
            NSColor.controlAccentColor.setFill()
            // 相邻两行的选中块之间要留 2pt 缝，不然连成一片认不出边界。
            NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1), xRadius: 9, yRadius: 9).fill()
        }

        var x = r.minX + 10
        if let icon = m.icon {
            icon.draw(in: NSRect(x: x, y: r.midY - 9, width: 18, height: 18),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        x += 18 + 9

        // 🔴 **店名列是这一版的主角**：眼睛顺着左边那条竖线往下扫的就是它，
        //    人脑子里想的是「去 C店 那个」。所以它是主字，窗口标题降成副字。
        if showsBadge {
            let badgeW: CGFloat = 76
            let named = !(m.badge ?? "").isEmpty
            // 没认出来写「未认出」，不写破折号 —— 一个破折号看不出是「没有店名」还是「店名就叫这个」。
            drawText(named ? m.badge! : "未认出",
                     in: NSRect(x: x, y: r.midY - 8, width: badgeW, height: 17),
                     font: .systemFont(ofSize: 13, weight: .semibold),
                     color: on ? .white : (named ? .labelColor : dim))
            x += badgeW + 10
        }

        drawText(m.label,
                 in: NSRect(x: x, y: r.midY - 8, width: r.maxX - 10 - x, height: 16),
                 font: .systemFont(ofSize: showsBadge ? 12 : 12.5,
                                   weight: showsBadge ? .regular : .medium),
                 color: on ? NSColor.white.withAlphaComponent(0.88)
                           : (showsBadge ? .secondaryLabelColor : .labelColor))
    }

    /// 超过 12 个时最后一行：斜纹底 + 「还有 N 个」。
    private func drawTruncatedRow(_ r: NSRect, remaining: Int) {
        let textRect = NSRect(x: r.minX + 14, y: r.midY - 8, width: r.width - 28, height: 16)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1), xRadius: 9, yRadius: 9)
        // 那行字要真的掏空，别让斜纹压过去（跟空态那块是同一条）。
        clip.append(NSBezierPath(roundedRect: textRect.insetBy(dx: -6, dy: -3), xRadius: 6, yRadius: 6))
        clip.windingRule = .evenOdd
        clip.addClip()
        NSColor.labelColor.withAlphaComponent(0.55).setStroke()
        let hatch = NSBezierPath()
        hatch.lineWidth = 1
        var x = r.minX - r.height
        while x < r.maxX {
            hatch.move(to: CGPoint(x: x, y: r.minY))
            hatch.line(to: CGPoint(x: x + r.height, y: r.maxY))
            x += 8
        }
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()

        drawText("还有 \(remaining) 个 · 松手回去再甩一次", in: textRect,
                 font: .systemFont(ofSize: 12, weight: .medium), color: dim)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}

/// 三向路标：两翼 + 尖塔 + 原点盘。只管画。
///
/// 🔴 **没有悬停态，也没有按下态** —— 面板 `ignoresMouseEvents`，QuickBar 也从来不是活跃应用。
/// 全部反馈只有「选中 / 未选中」这一种差别，别照着别的浮窗补 hover。
private final class CellsView: NSView {

    var targets: [SwitchLane: SwitchTarget] = [:]
    var selected: SwitchLane?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawTopHighlight()
        for lane in SwitchLane.allCases { drawLane(lane) }
        drawSpokes()
        drawOrigin()
    }

    /// 沿轮廓顶部一道内高光。**没有 1pt 描边** —— 玻璃是靠遮罩剪出来的，
    /// 描边会连着被剪掉；玻璃提到 .88 + 这道高光 + 窗口阴影，比描边更立得住。
    private func drawTopHighlight() {
        NSGraphicsContext.saveGraphicsState()
        WheelGeo.outline.addClip()
        let top = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        NSColor.white.withAlphaComponent(isDark ? 0.13 : 0.8).setFill()
        top.fill()
        let shaft = NSRect(x: 0, y: WheelGeo.shaftTop - 1, width: bounds.width, height: 1)
        NSColor.white.withAlphaComponent(isDark ? 0.07 : 0.45).setFill()
        shaft.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 软件里真会出现的弱化文字用这一档，不用 `tertiaryLabelColor`。
    /// 空态本来就是「区分得不够」，再用最弱的墨等于没改。
    private var dim: NSColor {
        isDark ? NSColor(calibratedWhite: 0.74, alpha: 1) : NSColor(calibratedWhite: 0.36, alpha: 1)
    }

    private func drawLane(_ lane: SwitchLane) {
        let path = WheelGeo.path(for: lane)
        let target = targets[lane]
        // 访达永远「有」：一个窗口都没开时甩过去也会给你开一个，所以它没有空态。
        let has = target != nil || lane == .finder
        let on = selected == lane

        if on {
            // 🔴 选中 = **整个扇区**实色填充，从原点一直填到箭尖。面积是旧版那个格子的两倍多，
            //    在 PS 的深色画布上余光扫一眼就分得出 —— 玻璃灰底做不到（药丸那次踩过）。
            (has ? NSColor.controlAccentColor : NSColor.systemGray).setFill()
            path.fill()
        }
        if !has {
            // 🔴 空态不再靠「把图标调淡」：换成另一种物体 —— 1pt 斜纹掏空。
            //    斜纹是「这块是空的」，比一个淡了的实心块清楚一个量级。
            //    🔴 **那一行字要真的掏空**，不能让斜纹压过去 —— 压上去就成了「看不清的空态」，
            //    比看得清的弱化态还糟。
            drawHatch(in: path, light: on, hole: emptyTextRect(lane))
        }
        drawText(lane, on: on, has: has)
    }

    /// 135°、1pt、8pt 周期的斜纹。`hole` 那一块挖空，留给那行字。
    private func drawHatch(in path: NSBezierPath, light: Bool, hole: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let clip = path.copy() as! NSBezierPath
        clip.append(NSBezierPath(roundedRect: hole.insetBy(dx: -9, dy: -4), xRadius: 7, yRadius: 7))
        clip.windingRule = .evenOdd          // 内圈被挖掉
        clip.addClip()
        (light ? NSColor.white : NSColor.labelColor).withAlphaComponent(0.55).setStroke()
        let hatch = NSBezierPath()
        hatch.lineWidth = 1
        let span = bounds.width + bounds.height
        var x = -bounds.height
        while x < span {
            hatch.move(to: CGPoint(x: x, y: 0))
            hatch.line(to: CGPoint(x: x + bounds.height, y: bounds.height))
            x += 8
        }
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: 文字

    /// 🔴 **主字是店名，副字才是窗口标题** —— 方向已经说明了这是浏览器那一翼，
    /// 「浏览器」三个字不配当主字；人脑子里想的是「去 C店 那个」。
    /// 没有店名时主字退回窗口标题、副字写类名。
    private func drawText(_ lane: SwitchLane, on: Bool, has: Bool) {
        let target = targets[lane]
        let primary: String
        let secondary: String
        if !has {
            primary = lane.emptyHint
            secondary = ""
        } else if let badge = target?.badge, !badge.isEmpty {
            primary = badge
            secondary = target?.label ?? ""
        } else if lane == .finder && target == nil {
            primary = "打开访达"
            secondary = "访达 · 没开着窗口"
        } else {
            primary = target?.label ?? lane.title
            secondary = lane.title
        }

        let fg: NSColor = on ? .white : (has ? .labelColor : dim)
        let sub: NSColor = on ? NSColor.white.withAlphaComponent(0.78) : (has ? .secondaryLabelColor : dim)

        switch lane {
        case .document: drawTower(target, primary, secondary, fg, sub, on: on, has: has)
        case .browser: drawWing(target, primary, secondary, fg, sub, left: true, has: has)
        case .finder: drawWing(target, primary, secondary, fg, sub, left: false, has: has)
        }
    }

    /// 空态那一行字的位置。**画斜纹和画字用的是同一个 rect** ——
    /// 分成两处算，挖出来的洞迟早跟字错开。
    private func emptyTextRect(_ lane: SwitchLane) -> NSRect {
        switch lane {
        case .document:
            let w = WheelGeo.towerWidth(atY: 166) - 20
            return NSRect(x: WheelGeo.anchor.x - w / 2, y: 158, width: w, height: 17)
        case .browser, .finder:
            let left = lane == .browser
            let inner = WheelGeo.edgeX(atY: WheelGeo.shaftTop, left: left)
            let outer: CGFloat = left ? WheelGeo.tipInset : bounds.width - WheelGeo.tipInset
            let lo = min(inner, outer) + 16, hi = max(inner, outer) - 16
            return NSRect(x: lo, y: WheelGeo.anchor.y - 8, width: hi - lo, height: 17)
        }
    }

    private func drawWing(_ target: SwitchTarget?, _ primary: String, _ secondary: String,
                          _ fg: NSColor, _ sub: NSColor, left: Bool, has: Bool) {
        let a = WheelGeo.anchor
        // 可用横向范围：箭尖根部 → 塔根。两边各留一点内边距。
        let inner = WheelGeo.edgeX(atY: WheelGeo.shaftTop, left: left)
        let outer: CGFloat = left ? WheelGeo.tipInset : bounds.width - WheelGeo.tipInset
        let lo = min(inner, outer) + 16, hi = max(inner, outer) - 16
        var x = lo
        var width = hi - lo

        if has, let icon = target?.icon {
            let box = NSRect(x: left ? lo : hi - 24, y: a.y - 12, width: 24, height: 24)
            icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
            if left { x = box.maxX + 10 }
            width -= 34
        }
        let align: NSTextAlignment = left ? .left : .right
        if secondary.isEmpty {
            text(primary, emptyTextRect(left ? .browser : .finder),
                 .systemFont(ofSize: 12, weight: .medium), fg, .center)
        } else {
            text(primary, NSRect(x: x, y: a.y + 1, width: width, height: 18),
                 .systemFont(ofSize: 13, weight: .semibold), fg, align)
            text(secondary, NSRect(x: x, y: a.y - 17, width: width, height: 16),
                 .systemFont(ofSize: 11, weight: .medium), sub, align)
        }
    }

    /// 🔴 **塔里的字必须居中 + 定宽截断**：塔的可视宽度随高度收窄（那是 70° 扇区在每个
    /// 高度上的真实宽度），左对齐会顶出扇区。主字 132、副字 112 —— 这两个数是量着塔算的。
    private func drawTower(_ target: SwitchTarget?, _ primary: String, _ secondary: String,
                           _ fg: NSColor, _ sub: NSColor, on: Bool, has: Bool) {
        let cx = WheelGeo.anchor.x
        // 🔴 **每一行的宽度按它所在高度现算**，不写死。设计稿给的 132/112 是按稿子上那座
        //    更窄的塔（顶宽 178）量的；我们的塔严格贴着 55°，顶宽 234，写死那两个数会白白
        //    把文件名截掉一截。留 10pt 余量，字仍然不会顶出斜边。
        func band(_ y: CGFloat) -> CGFloat { WheelGeo.towerWidth(atY: y) - 20 }

        if has, let icon = target?.icon {
            icon.draw(in: NSRect(x: cx - 11, y: 194, width: 22, height: 22),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        if secondary.isEmpty {
            text(primary, emptyTextRect(.document),
                 .systemFont(ofSize: 12, weight: .medium), fg, .center)
        } else {
            let w1 = band(172), w2 = band(152)
            text(primary, NSRect(x: cx - w1 / 2, y: 168, width: w1, height: 18),
                 .systemFont(ofSize: 13, weight: .semibold), fg, .center)
            text(secondary, NSRect(x: cx - w2 / 2, y: 150, width: w2, height: 16),
                 .systemFont(ofSize: 11, weight: .medium), sub, .center)
        }
    }

    // MARK: 原点盘与辐条

    /// 四根辐条 = 四条判定边界的可见部分。**一直在，不做出现/消失动画**；
    /// 选中那一翼上的两根翻白，另两根保持原色。
    private func drawSpokes() {
        let a = WheelGeo.anchor
        let base = NSColor.labelColor.withAlphaComponent(isDark ? 0.18 : 0.16)
        for deg in [WheelGeo.edge, 180 - WheelGeo.edge, -(180 - WheelGeo.edge), -WheelGeo.edge] {
            let r = deg * .pi / 180
            let onSelected: Bool
            switch selected {
            case .browser: onSelected = deg == 180 - WheelGeo.edge || deg == -(180 - WheelGeo.edge)
            case .finder: onSelected = deg == WheelGeo.edge || deg == -WheelGeo.edge
            case .document: onSelected = deg == WheelGeo.edge || deg == 180 - WheelGeo.edge
            case nil: onSelected = false
            }
            (onSelected ? NSColor.white.withAlphaComponent(0.34) : base).setStroke()
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: CGPoint(x: a.x + cos(r) * WheelGeo.disc / 2, y: a.y + sin(r) * WheelGeo.disc / 2))
            line.line(to: CGPoint(x: a.x + cos(r) * WheelGeo.spoke, y: a.y + sin(r) * WheelGeo.spoke))
            line.stroke()
        }
    }

    /// 原点盘 = 取消 = anchor。
    /// 🔴 **选中别处时它变空框**：填充撤掉、十字缩小。它是原点，不是第四个选项 ——
    /// 已经选了别处时它就该退场。
    private func drawOrigin() {
        let a = WheelGeo.anchor
        let d = WheelGeo.disc
        let box = NSRect(x: a.x - d / 2, y: a.y - d / 2, width: d, height: d)
        let circle = NSBezierPath(ovalIn: box)
        let idle = selected == nil

        if idle {
            (isDark ? NSColor(calibratedWhite: 0.26, alpha: 1) : NSColor(calibratedWhite: 0.92, alpha: 1)).setFill()
            circle.fill()
        }
        NSColor.labelColor.withAlphaComponent(idle ? 0.16 : 0.30).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let arm: CGFloat = idle ? 9 : 7
        let cross = NSBezierPath()
        cross.lineWidth = idle ? 1.5 : 1
        cross.move(to: CGPoint(x: a.x - arm, y: a.y)); cross.line(to: CGPoint(x: a.x + arm, y: a.y))
        cross.move(to: CGPoint(x: a.x, y: a.y - arm)); cross.line(to: CGPoint(x: a.x, y: a.y + arm))
        (idle ? dim : NSColor.labelColor.withAlphaComponent(0.34)).setStroke()
        cross.stroke()
    }

    private func text(_ str: String, _ rect: NSRect, _ font: NSFont, _ color: NSColor,
                      _ align: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        (str as NSString).draw(in: rect, withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }
}
