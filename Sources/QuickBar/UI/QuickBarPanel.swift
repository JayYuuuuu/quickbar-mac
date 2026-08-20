import AppKit

/// ⌥双击弹出来的那个悬浮条。
///
/// 面板在启动时就建好并一直留着，唤出只是 `orderFront`——
/// 每次现建窗口会有肉眼可见的迟滞，这是弹出手感的关键。
final class QuickBarPanel: NSPanel {

    private enum Entry {
        case header(String)
        case item(QuickItem, pinned: Bool)
    }

    private static let panelWidth: CGFloat = 298
    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 340

    private let effect = RoundedEffectView()
    private let contextIcon = NSImageView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let contextAction = NSTextField(labelWithString: "")
    private let filterLabel = NSTextField(labelWithString: "")
    private let filterIcon = NSImageView()
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")

    private var entries: [Entry] = []
    private var rowViews: [RowView] = []
    private var selectableIndexes: [Int] = []
    private var selection = 0
    private var filter = ""
    private var panelContext: DetectedPanel?
    private var iconCache: [String: NSImage] = [:]
    private var listHeightConstraint: NSLayoutConstraint!
    private var contentListHeight: CGFloat = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        buildUI()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - 组装界面

    private func buildUI() {
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        contentView = effect

        // 上下文：一行结论，解释都在 tooltip 里
        contextIcon.imageScaling = .scaleProportionallyDown
        contextLabel.font = .systemFont(ofSize: 11.5)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextAction.font = .systemFont(ofSize: 11, weight: .medium)
        contextAction.textColor = .tertiaryLabelColor

        let contextRow = NSStackView(views: [contextIcon, contextLabel, NSView(), contextAction])
        contextRow.orientation = .horizontal
        contextRow.spacing = 6
        contextRow.edgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 6, right: 11)
        contextIcon.setContentHuggingPriority(.required, for: .horizontal)
        contextAction.setContentHuggingPriority(.required, for: .horizontal)
        contextIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        contextIcon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        contextRow.toolTip = "快捷条会跟着当前上下文改动作：在桌面或 Finder 里是「打开」，在上传/保存窗里变成「跳转到此」。"

        // 筛选：直接吃键盘输入，不用 NSTextField，省掉一层焦点管理
        filterIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        filterIcon.contentTintColor = .tertiaryLabelColor
        filterLabel.font = .systemFont(ofSize: 12.5)
        let filterBox = NSStackView(views: [filterIcon, filterLabel])
        filterBox.orientation = .horizontal
        filterBox.spacing = 6
        filterBox.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        filterBox.wantsLayer = true
        filterBox.layer?.cornerRadius = 8
        filterBox.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        filterBox.heightAnchor.constraint(equalToConstant: 27).isActive = true
        filterIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        filterBox.toolTip = "支持拼音：「下载」可以输 xiazai，也可以只输首字母 xz。"
        let filterRow = NSStackView(views: [filterBox])
        filterRow.orientation = .horizontal
        filterRow.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 4, right: 9)
        filterBox.widthAnchor.constraint(equalTo: filterRow.widthAnchor, constant: -18).isActive = true

        // 列表
        listStack.orientation = .vertical
        listStack.spacing = 1
        listStack.alignment = .leading
        listStack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 6, right: 7)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listStack
        // documentView 必须显式钉到 clipView 上。少了这几条，
        // listStack 宽度会是 0——行被压成零宽（看不见），窗口也没东西撑开宽度。
        listStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        // 底栏
        footerLeft.font = .systemFont(ofSize: 11)
        footerLeft.textColor = .tertiaryLabelColor
        footerRight.font = .systemFont(ofSize: 11)
        footerRight.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [footerLeft, NSView(), footerRight])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 11, bottom: 7, right: 11)

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSStackView(views: [contextRow, filterRow, scrollView, separator, footer])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            contextRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            filterRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            effect.widthAnchor.constraint(equalToConstant: Self.panelWidth)
        ])

        // 只建一次，之后改 constant——每次 reload 新建约束会越堆越多然后互相打架
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 120)
        listHeightConstraint.isActive = true
    }

    // MARK: - 显示

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        filter = ""
        selection = 0
        panelContext = PanelService.shared.currentPanel()
        FinderService.shared.refresh()
        reload()

        let point = NSEvent.mouseLocation
        setFrameTopLeft(near: point)
        orderFrontRegardless()
        makeKey()
    }

    func hide() {
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        hide()
    }

    /// 弹在鼠标右下方，越界了就翻到另一边，保证整条都在屏幕里。
    private func setFrameTopLeft(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var frame = self.frame
        frame.size.width = Self.panelWidth
        var origin = NSPoint(x: point.x + 12, y: point.y - frame.height - 12)

        if origin.x + frame.width > visible.maxX { origin.x = point.x - frame.width - 12 }
        if origin.x < visible.minX { origin.x = visible.minX + 8 }
        if origin.y < visible.minY { origin.y = point.y + 12 }
        if origin.y + frame.height > visible.maxY { origin.y = visible.maxY - frame.height - 8 }

        frame.origin = origin
        setFrame(frame, display: false)
    }

    // MARK: - 内容

    private func reload() {
        buildEntries()
        rebuildRows()
        updateChrome()
        resizeToFit()
        updateSelection()
    }

    private func buildEntries() {
        let store = Store.shared
        let needle = filter.lowercased()

        entries = []

        // 在文件面板里，把「Finder 当前文件夹」置顶——这就是 ⌘G 那一下要跳的地方
        if panelContext != nil {
            var pinned = QuickItem(kind: .folder, name: FinderService.shared.currentName,
                                   path: FinderService.shared.currentPath)
            pinned.id = UUID()
            if Pinyin.score(name: pinned.name, path: pinned.path, needle: needle) != nil {
                entries.append(.item(pinned, pinned: true))
            }
        }

        let folders = rank(store.folders, needle: needle)
        if !folders.isEmpty {
            entries.append(.header("文件夹"))
            entries.append(contentsOf: folders.map { .item($0, pinned: false) })
        }
        let apps = rank(store.apps, needle: needle)
        if !apps.isEmpty {
            entries.append(.header("应用"))
            entries.append(contentsOf: apps.map { .item($0, pinned: false) })
        }
        if entries.isEmpty { entries.append(.header("没有匹配项")) }
    }

    /// 没有筛选词时保持用户自己排的顺序；一旦开始筛选，就按贴切程度重排。
    private func rank(_ items: [QuickItem], needle: String) -> [QuickItem] {
        guard !needle.isEmpty else { return items }
        return items.enumerated()
            .compactMap { index, item -> (QuickItem, Int, Int)? in
                guard let score = Pinyin.score(name: item.name, path: item.path, needle: needle) else { return nil }
                return (item, score, index)
            }
            // 同分时按原顺序，Swift 的 sorted 不保证稳定，所以显式拿下标兜底
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowViews = []
        selectableIndexes = []
        contentListHeight = listStack.edgeInsets.top + listStack.edgeInsets.bottom
        var pieces = 0

        for (index, entry) in entries.enumerated() {
            switch entry {
            case .header(let title):
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 10.5, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                let wrapper = NSStackView(views: [label])
                wrapper.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 3, right: 9)
                listStack.addArrangedSubview(wrapper)
                wrapper.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                contentListHeight += 25
                pieces += 1

            case .item(let item, let pinned):
                let disabled = panelContext != nil && item.kind == .app
                let row = RowView(item: item, pinned: pinned, disabled: disabled, icon: icon(for: item))
                row.onClick = { [weak self] in self?.activate(item, disabled: disabled) }
                row.onHover = { [weak self] in
                    guard let self, let position = self.selectableIndexes.firstIndex(of: index) else { return }
                    self.selection = position
                    self.updateSelection()
                }
                let height: CGFloat = pinned ? 34 : Self.rowHeight
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: height).isActive = true
                rowViews.append(row)
                contentListHeight += height
                pieces += 1
                if !disabled { selectableIndexes.append(index) }
            }
        }
        contentListHeight += CGFloat(max(0, pieces - 1)) * listStack.spacing
        selection = min(selection, max(0, selectableIndexes.count - 1))
    }

    private func updateChrome() {
        if let context = panelContext {
            contextIcon.image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: nil)
            contextIcon.contentTintColor = .controlAccentColor
            contextLabel.stringValue = "\(context.kind == .save ? "保存窗" : "上传窗") · \(context.ownerName ?? "未知应用")"
            contextAction.stringValue = "跳转"
            contextAction.textColor = .controlAccentColor
            footerLeft.stringValue = filter.isEmpty ? "↩ 跳转到此" : "筛选：\(filter)"
            if let size = Store.shared.settings.panelSize {
                footerRight.stringValue = "尺寸 \(Int(size.width))×\(Int(size.height)) 已记住"
                footerRight.toolTip = "普通面板即时套用；Chrome 这类 sheet 面板由系统偏好承载，下次打开生效。"
            } else {
                footerRight.stringValue = ""
            }
        } else {
            contextIcon.image = NSWorkspace.shared.icon(forFile: FinderService.shared.currentPath)
            contextIcon.contentTintColor = nil
            contextLabel.stringValue = "Finder · \(FinderService.shared.currentName)"
            contextAction.stringValue = "打开"
            contextAction.textColor = .tertiaryLabelColor
            footerLeft.stringValue = filter.isEmpty ? "↑↓ 选择 · ↩ 打开" : "筛选：\(filter)"
            footerRight.stringValue = ""
        }
        filterLabel.stringValue = filter.isEmpty ? "输入即可筛选" : filter
        filterLabel.textColor = filter.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    private func resizeToFit() {
        listHeightConstraint.constant = min(contentListHeight, Self.maxListHeight)
        effect.layoutSubtreeIfNeeded()
        // 高度交给 Auto Layout 算，宽度由 effect 的固定约束定死。
        let height = max(effect.fittingSize.height, 120)
        setContentSize(NSSize(width: Self.panelWidth, height: height))
    }

    private func updateSelection() {
        guard !selectableIndexes.isEmpty else { return }
        let selectedEntryIndex = selectableIndexes[min(selection, selectableIndexes.count - 1)]
        var cursor = 0
        for (index, entry) in entries.enumerated() {
            guard case .item = entry else { continue }
            rowViews[cursor].isSelected = (index == selectedEntryIndex)
            cursor += 1
        }
    }

    private func icon(for item: QuickItem) -> NSImage {
        if let cached = iconCache[item.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.path)
        image.size = NSSize(width: 18, height: 18)
        iconCache[item.path] = image
        return image
    }

    private func activate(_ item: QuickItem, disabled: Bool) {
        guard !disabled else { return }
        // 用弹出那一刻抓到的上下文，而不是事后再查：快捷条一旦成为 key 窗口，
        // 「当前聚焦窗口」就变成我们自己了，再查必然查不到那个文件面板。
        let wasInPanel = panelContext != nil
        hide()
        // 等焦点真正回到原来的窗口再动手。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if wasInPanel, item.kind == .folder {
                PanelService.shared.jump(to: item.path)
            } else {
                Actions.activate(item)
            }
        }
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                                  // esc
            hide()
        case 125:                                 // ↓
            move(by: 1)
        case 126:                                 // ↑
            move(by: -1)
        case 36, 76:                              // ↩ / 小键盘 ↩
            activateSelection()
        case 51:                                  // ⌫
            if !filter.isEmpty { filter.removeLast(); reload() }
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let text = event.charactersIgnoringModifiers, !text.isEmpty,
               text.rangeOfCharacter(from: .controlCharacters) == nil {
                filter += text
                selection = 0
                reload()
            }
        }
    }

    private func move(by delta: Int) {
        guard !selectableIndexes.isEmpty else { return }
        selection = (selection + delta + selectableIndexes.count) % selectableIndexes.count
        updateSelection()
        selectedRowView()?.scrollToVisible(selectedRowView()!.bounds)
    }

    /// selectableIndexes 排除了禁用行，rowViews 没有——两者下标不通用，得换算。
    private func selectedRowView() -> RowView? {
        guard !selectableIndexes.isEmpty else { return nil }
        let entryIndex = selectableIndexes[min(selection, selectableIndexes.count - 1)]
        var cursor = 0
        for (index, entry) in entries.enumerated() {
            guard case .item = entry else { continue }
            if index == entryIndex { return cursor < rowViews.count ? rowViews[cursor] : nil }
            cursor += 1
        }
        return nil
    }

    private func activateSelection() {
        guard !selectableIndexes.isEmpty else { return }
        let entryIndex = selectableIndexes[min(selection, selectableIndexes.count - 1)]
        guard case .item(let item, _) = entries[entryIndex] else { return }
        activate(item, disabled: false)
    }
}

// MARK: - 单行

private final class RowView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false { didSet { needsDisplay = true; applyColors() } }

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let runningDot = NSView()
    private let disabled: Bool

    init(item: QuickItem, pinned: Bool, disabled: Bool, icon: NSImage) {
        self.disabled = disabled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.stringValue = item.name
        nameLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: pinned ? 10.5 : 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .right

        if pinned {
            detailLabel.stringValue = "Finder 当前"
            detailLabel.alignment = .left
            badge.stringValue = "⌘G"
            badge.font = .systemFont(ofSize: 10.5, weight: .medium)
            badge.textColor = .secondaryLabelColor
        } else if disabled {
            detailLabel.stringValue = "面板内不可用"
            toolTip = "文件面板里没有「启动应用」这个动作。"
        } else if item.kind == .app {
            detailLabel.stringValue = Actions.isRunning(item) ? "切到前台" : "启动"
        } else {
            detailLabel.stringValue = item.compactPath
            toolTip = item.path
        }

        runningDot.wantsLayer = true
        runningDot.layer?.cornerRadius = 2.5
        runningDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        runningDot.isHidden = !Actions.isRunning(item)
        runningDot.toolTip = "已在运行，点击切到前台，不会新开一个。"

        let text: NSView
        if pinned {
            let column = NSStackView(views: [nameLabel, detailLabel])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            text = column
        } else {
            text = nameLabel
        }

        let stack = NSStackView(views: pinned
            ? [iconView, text, NSView(), badge]
            : [iconView, text, runningDot, NSView(), detailLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            runningDot.widthAnchor.constraint(equalToConstant: 5),
            runningDot.heightAnchor.constraint(equalToConstant: 5)
        ])
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        alphaValue = disabled ? 0.45 : 1
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        let onAccent = isSelected
        nameLabel.textColor = onAccent ? .white : .labelColor
        detailLabel.textColor = onAccent ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor
        badge.textColor = onAccent ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        guard !disabled else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !disabled else { return }
        onHover?()
    }
}

/// 只是为了在外观切换时把描边颜色刷对。
private final class RoundedEffectView: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBorder()
    }

    private func applyBorder() {
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
