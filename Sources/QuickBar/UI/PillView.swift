import AppKit

/// 那颗药丸长什么样。**只管画，不管什么时候出现** —— 那半在 `MainImagesPill`。
///
/// 版式来自设计稿 `design/QuickBar 快捷条.dc.html` 的 `1d Pill`：
/// 高 32、圆角 10、1px 边框、12.5pt semibold、左右内边距 14、间距 7、宽度 120–320 夹取。
///
/// 🔴 **可点态一律「实色强调填充 + 白字 + 前导 5pt 白点」，不用毛玻璃。**
///    这是拿实拍改出来的结论：玻璃灰底浮在 Photoshop 的深色画布上会**完全糊掉** ——
///    人眼扫过去只看到一小块比背景稍亮的雾，根本注意不到那儿有个按钮。
///    **只有不可点的「存回中…」才降成中性玻璃** —— 灰掉本身就是「现在别点」的信号。
///
/// 【为什么不是 NSButton】要改的东西超出了它肯给的范围：悬停是整块填充提亮 16%、
/// 按下是压暗 18% 再缩到 0.97、进行中底边还有一条流动的线。用 `NSButton` 拼这些
/// 等于跟它的绘制打架，自绘反而短。
///
/// 【三条实测】
/// 🔴 **`NSTrackingArea` 必须用 `.activeAlways`**：药丸挂在 `.nonactivatingPanel` 上，
///    QuickBar 自己从来不是活跃应用，`.activeInKeyWindow` / `.activeInActiveApp` 一个鼠标事件都收不到，
///    表现是"悬停态永远不出现"。
/// 🔴 **进度线宽度用 `bounds` 现算，不能存**：药丸宽度随文案变（中文字数不固定），
///    存下来的旧宽度会让那条线冒出圆角外面。
/// 🔴 **改颜色要包在 `CATransaction` 里关掉隐式动画**：layer 的 `borderColor` / `backgroundColor`
///    默认带 0.25 秒淡入，悬停进出会拖出一条尾巴，看着像卡。
final class PillView: NSView {

    enum Style {
        /// 可以点：实色强调填充。
        case action
        /// 正在干活，不可点：降成中性玻璃 + 底边一条流动的线。
        case busy
        /// 干完了那 0.6 秒：绿色实底 + 对勾，随后整颗收走。
        case done
    }

    static let height: CGFloat = 32
    static let corner: CGFloat = 10
    static let padH: CGFloat = 14
    static let gap: CGFloat = 7
    static let dotSize: CGFloat = 5
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 320
    static let font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    var onClick: (() -> Void)?

    /// 只有「存回中」那一态用得到它 —— 别的时候整块被 `fill` 盖住。
    private let blur = NSVisualEffectView()
    /// 🔴 **所有自绘的层都挂在这个视图上，不能直接挂在 `self.layer` 上。**
    ///    AppKit 会把**子视图的 layer 排到手动 `addSublayer` 的层上面**，
    ///    于是毛玻璃反过来盖住了实色填充 —— 表现是药丸永远是玻璃灰底配白字，
    ///    在浅色访达里几乎看不清（1.15.1 实拍翻车）。
    ///    做成一个排在 `blur` 之后的子视图，顺序就由子视图数组说了算，稳。
    private let paint = NSView()
    /// 实色填充（强调色 / 绿色）。
    private let fill = CALayer()
    /// 悬停提亮 / 按下压暗，盖在 `fill` 上的一层。
    private let overlay = CALayer()
    /// 顶部 1px 内高光。设计稿只要这一条立体感，不加别的。
    private let innerTop = CALayer()
    /// 前导那颗 5pt 圆点。
    private let dot = CALayer()
    /// 进度：底边一条 2pt 的线。设计稿的原话是「底边描边着色，不加进度条控件」。
    private let progress = CALayer()
    /// 进行中：同一条位置上的流动渐变。
    private let flow = CAGradientLayer()

    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()

    private var style: Style = .action
    private var fraction: CGFloat = 0
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    private var labelLeadingDot: NSLayoutConstraint!
    private var labelLeadingCheck: NSLayoutConstraint!

    // MARK: - 组装

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.corner
        layer?.borderWidth = 1

        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        paint.wantsLayer = true
        paint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paint)                       // 必须排在 blur 之后
        for l in [fill, overlay, innerTop, dot, progress, flow] { paint.layer?.addSublayer(l) }
        dot.cornerRadius = Self.dotSize / 2
        overlay.opacity = 0
        progress.opacity = 0
        flow.opacity = 0
        flow.startPoint = CGPoint(x: 0, y: 0.5)
        flow.endPoint = CGPoint(x: 1, y: 0.5)

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        check.contentTintColor = .white
        check.isHidden = true
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        // 🔴 文字淡入淡出是往 `label.layer` 上挂 `CATransition` 的，
        //    不显式开 `wantsLayer` 那个 layer 就是 nil —— 动画一声不响地不发生。
        label.wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        labelLeadingDot = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.padH + Self.dotSize + Self.gap)
        labelLeadingCheck = label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6)

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            paint.leadingAnchor.constraint(equalTo: leadingAnchor),
            paint.trailingAnchor.constraint(equalTo: trailingAnchor),
            paint.topAnchor.constraint(equalTo: topAnchor),
            paint.bottomAnchor.constraint(equalTo: bottomAnchor),

            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padH),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padH),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        labelLeadingDot.isActive = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 内容

    /// - Parameters:
    ///   - fraction: 进度（0…1）。0 就不画那条线 —— 访达那头没有进度可言。
    ///   - animateText: 文字换了要不要淡一下。整颗刚出现时不用（本来就在淡入）。
    func set(title: String, style: Style, fraction: CGFloat, animateText: Bool) {
        let changed = label.stringValue != title
        self.style = style
        self.fraction = max(0, min(1, fraction))

        if changed, animateText {
            // 数字每存回一张就减一，硬切会跳；0.12s 的淡入淡出正好盖住。
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            label.layer?.add(fade, forKey: "text")
        }
        label.stringValue = title

        let showCheck = style == .done
        check.isHidden = !showCheck
        labelLeadingCheck.isActive = showCheck
        labelLeadingDot.isActive = !showCheck

        applyColors()
        layoutPieces()
        invalidateIntrinsicContentSize()
    }

    /// 宽度随文案变，夹在 120…320 之间。
    override var intrinsicContentSize: NSSize {
        let text = (label.stringValue as NSString).size(withAttributes: [.font: Self.font]).width
        let lead = style == .done ? 12 + 6 : Self.dotSize + Self.gap
        let w = ceil(text + lead + Self.padH * 2)
        return NSSize(width: min(max(w, Self.minWidth), Self.maxWidth), height: Self.height)
    }

    // MARK: - 外观

    private var accent: NSColor { .controlAccentColor }

    private func applyColors() {
        // 🔴 关掉隐式动画：borderColor / backgroundColor 默认有 0.25s 淡入，
        //    悬停进出会拖出一条尾巴，看着像卡了一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch style {
        case .action:
            fill.backgroundColor = accent.cgColor
            fill.opacity = 1
            label.textColor = .white
            dot.isHidden = false
            dot.backgroundColor = NSColor.white.withAlphaComponent(pressed ? 0.75 : (hovering ? 1 : 0.8)).cgColor
            // 悬停提亮 16%、按下压暗 18%（设计稿：**不放大**，放大交给按下那一下）
            overlay.backgroundColor = (pressed ? NSColor.black.withAlphaComponent(0.18)
                                               : NSColor.white.withAlphaComponent(0.16)).cgColor
            overlay.opacity = (pressed || hovering) ? 1 : 0
            layer?.borderColor = NSColor.black.withAlphaComponent(pressed ? 0.24 : 0.16).cgColor
            // 按下时把顶部内高光收掉 —— 按下去的东西不该还反光
            innerTop.backgroundColor = NSColor.white
                .withAlphaComponent(pressed ? 0 : (hovering ? 0.34 : 0.3)).cgColor
            progress.backgroundColor = NSColor.white.withAlphaComponent(hovering ? 0.7 : 0.62).cgColor

        case .busy:
            // 降成中性玻璃 = 「现在别点」。灰掉本身就是状态，不用再写一句话。
            fill.opacity = 0
            overlay.opacity = 0
            label.textColor = .secondaryLabelColor
            dot.isHidden = false
            dot.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            innerTop.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            flow.colors = [NSColor.clear.cgColor, accent.cgColor, NSColor.clear.cgColor]

        case .done:
            fill.backgroundColor = NSColor.systemGreen.cgColor
            fill.opacity = 1
            overlay.opacity = 0
            label.textColor = .white
            dot.isHidden = true          // 位置让给对勾
            layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor
            innerTop.backgroundColor = NSColor.white.withAlphaComponent(0.26).cgColor
        }

        CATransaction.commit()
    }

    /// 圆点、内高光、底边那两条线。🔴 宽度必须用 `bounds` 现算（药丸宽度随文案变）。
    private func layoutPieces() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        fill.frame = bounds
        overlay.frame = bounds
        innerTop.frame = CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1)
        dot.frame = CGRect(x: Self.padH, y: bounds.midY - Self.dotSize / 2,
                           width: Self.dotSize, height: Self.dotSize)

        let h: CGFloat = 2
        progress.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: h)
        progress.opacity = (style == .action && fraction > 0.001) ? 1 : 0
        flow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        flow.opacity = style == .busy ? 0.75 : 0

        CATransaction.commit()

        if style == .busy {
            if flow.animation(forKey: "flow") == nil {
                // 不用 spinner：设计稿的原话是「靠底边流动描边表达在动」。
                let a = CABasicAnimation(keyPath: "locations")
                a.fromValue = [-0.6, -0.3, 0.0]
                a.toValue = [1.0, 1.3, 1.6]
                a.duration = 1.1
                a.repeatCount = .infinity
                flow.add(a, forKey: "flow")
            }
        } else {
            flow.removeAnimation(forKey: "flow")
        }
    }

    override func layout() {
        super.layout()
        layoutPieces()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 明暗切换时 cgColor 不会自己跟着走，得重新取一遍。
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 鼠标

    /// 中间那几层（毛玻璃、自绘层、文字）都不该吃鼠标事件 —— 点在药丸任何位置都算点它。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // 🔴 `.activeAlways`：QuickBar 从来不是活跃应用，别的 option 一个事件都收不到。
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard style == .action else { return }
        hovering = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        applyColors()
        setScale(1)
    }

    override func mouseDown(with event: NSEvent) {
        guard style == .action else { return }
        pressed = true
        applyColors()
        setScale(0.97)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        applyColors()
        setScale(1)
        // 松开时鼠标还在药丸上才算点中（跟系统按钮一致）。
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    /// 按下缩到 0.97。锚点要挪到中心，否则会从左下角缩，看着像滑了一下。
    private func setScale(_ s: CGFloat) {
        guard let layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        layer.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }
}
