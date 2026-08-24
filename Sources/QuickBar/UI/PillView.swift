import AppKit

/// 那颗药丸长什么样。**只管画，不管什么时候出现** —— 那半在 `MainImagesPill`。
///
/// 版式来自设计稿 `QuickBar 快捷条.dc.html` 的 `1d Pill`：
/// 高 30、圆角 9、1px 边框、12pt medium、左右内边距 13、宽度 120–320 夹取。
///
/// 【为什么不是 NSButton】三个状态要改的东西超出了 `NSButton` 肯给的范围：
/// 按下时整颗变强调色实底 + 缩到 0.97、悬停时只有边框和文字变色、进行中底边还要有一条流动的线。
/// 用 `NSButton` 拼这些等于跟它的绘制打架，自绘反而短。
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
        /// 可以点。
        case action
        /// 正在干活，不可点（文字降到次要色，底边一条流动的线）。
        case busy
        /// 干完了那 0.6 秒（绿色 + 对勾，随后整颗收走）。
        case done
    }

    static let height: CGFloat = 30
    static let corner: CGFloat = 9
    static let padH: CGFloat = 13
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 320
    static let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    var onClick: (() -> Void)?

    private let blur = NSVisualEffectView()
    /// 按下时盖上去的强调色实底。平时透明 —— 毛玻璃在它下面。
    private let tint = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    /// 进度：底边一条 1.5pt 的线。设计稿的原话是「底边描边着色，不加进度条控件」。
    private let progress = CALayer()
    /// 进行中：同一条位置上的流动渐变。
    private let flow = CAGradientLayer()

    private var style: Style = .action
    private var fraction: CGFloat = 0
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    // MARK: - 组装

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.corner
        layer?.borderWidth = 1

        blur.material = .popover          // 跟随系统明暗；文字用 labelColor 两种外观都清楚
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        tint.backgroundColor = NSColor.controlAccentColor.cgColor
        tint.opacity = 0
        layer?.addSublayer(tint)

        progress.opacity = 0
        layer?.addSublayer(progress)

        flow.startPoint = CGPoint(x: 0, y: 0.5)
        flow.endPoint = CGPoint(x: 1, y: 0.5)
        flow.opacity = 0
        layer?.addSublayer(flow)

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
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

        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),

            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padH),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),

            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padH),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // 有对勾时文字往右让 17pt，没有就贴着左内边距。两条约束按需切换。
        labelLeadingPlain = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padH)
        labelLeadingWithCheck = label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6)
        labelLeadingPlain.isActive = true

        applyColors()
    }

    private var labelLeadingPlain: NSLayoutConstraint!
    private var labelLeadingWithCheck: NSLayoutConstraint!

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
        labelLeadingWithCheck.isActive = showCheck
        labelLeadingPlain.isActive = !showCheck

        applyColors()
        layoutBars()
        invalidateIntrinsicContentSize()
    }

    /// 宽度随文案变，夹在 120…320 之间。
    override var intrinsicContentSize: NSSize {
        var w = (label.stringValue as NSString)
            .size(withAttributes: [.font: Self.font]).width + Self.padH * 2
        if style == .done { w += 17 }
        return NSSize(width: min(max(ceil(w), Self.minWidth), Self.maxWidth), height: Self.height)
    }

    // MARK: - 外观

    private func applyColors() {
        // 🔴 关掉隐式动画：borderColor / backgroundColor 默认有 0.25s 淡入，
        //    悬停进出会拖出一条尾巴，看着像卡了一下。
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let accent = NSColor.controlAccentColor
        switch style {
        case .action:
            layer?.borderColor = (hovering || pressed ? accent : NSColor.separatorColor).cgColor
            tint.opacity = pressed ? 1 : 0
            label.textColor = pressed ? .white : (hovering ? accent : .labelColor)
        case .busy:
            layer?.borderColor = NSColor.separatorColor.cgColor
            tint.opacity = 0
            label.textColor = .secondaryLabelColor
        case .done:
            layer?.borderColor = NSColor.separatorColor.cgColor
            tint.opacity = 0
            label.textColor = .systemGreen
            check.contentTintColor = .systemGreen
        }
        tint.backgroundColor = accent.cgColor
        progress.backgroundColor = accent.withAlphaComponent(0.55).cgColor
        flow.colors = [NSColor.clear.cgColor, accent.cgColor, NSColor.clear.cgColor]

        CATransaction.commit()
    }

    /// 底边那两条线。🔴 宽度必须用 `bounds` 现算（药丸宽度随文案变）。
    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        tint.frame = bounds
        let h: CGFloat = 1.5
        progress.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: h)
        progress.opacity = (style == .action && fraction > 0.001) ? 1 : 0
        flow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        flow.opacity = style == .busy ? 0.6 : 0

        CATransaction.commit()

        if style == .busy {
            if flow.animation(forKey: "flow") == nil {
                // 不用 spinner：设计稿的原话是「靠底边流动描边表达」。
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
        layoutBars()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // 明暗切换时 cgColor 不会自己跟着走，得重新取一遍。
        effectiveAppearance.performAsCurrentDrawingAppearance { applyColors() }
    }

    // MARK: - 鼠标

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
