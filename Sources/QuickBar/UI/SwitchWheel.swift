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

    private init() {}

    var isShowing: Bool { panel?.isVisible == true }

    // MARK: - 弹出

    func show() {
        let mouse = NSEvent.mouseLocation
        round &+= 1
        let myRound = round

        targets = WindowSwitch.shared.targets()
        selected = nil

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
        hide()
        guard let lane else { return }

        if let target = targets[lane] {
            Notify.log("三向甩✓ 切到 \(target.caption(lane))：\(target.label)(\(target.pid))")
            WindowSwitch.activate(pid: target.pid)
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
        if let last = lastMouse, abs(last.x - mouse.x) < 1, abs(last.y - mouse.y) < 1 { return }
        lastMouse = mouse
        let lane = WheelGeo.lane(at: mouse, center: origin)
        guard lane != selected else { return }
        selected = lane
        view?.update(targets: targets, selected: lane)
    }

    /// 方向键也能选。
    ///
    /// 🔴 **这条不是锦上添花**：主场景是「文档里 ⌘C 复制，切到浏览器 ⌘V 粘贴」——
    /// 按 ⌘C 的时候两只手都在键盘上，鼠标离得远。只有鼠标能选的话，这个功能在它
    /// 最该派上用场的那一刻正好用不了。
    func select(_ lane: SwitchLane?) {
        guard isShowing else { return }
        selected = lane
        view?.update(targets: targets, selected: lane)
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

        paint.frame = bounds
        paint.autoresizingMask = [.width, .height]
        addSubview(paint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func update(targets: [SwitchLane: SwitchTarget], selected: SwitchLane?) {
        paint.targets = targets
        paint.selected = selected
        paint.needsDisplay = true
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
