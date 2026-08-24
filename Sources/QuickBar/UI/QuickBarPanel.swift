import AppKit

/// 唤出后弹出来的那个悬浮条。
///
/// 面板在启动时就建好并一直留着，唤出只是 `orderFront`——
/// 每次现建窗口会有肉眼可见的迟滞，这是弹出手感的关键。
final class QuickBarPanel: NSPanel {

    private enum Entry {
        case header(String)
        case item(QuickItem, pinned: Bool)
    }

    private static let panelWidth: CGFloat = 320
    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 340
    /// 不筛选时快捷条上直接列出来的素材批次条数；再多就要靠输品牌名筛。
    private static let batchPreviewCount = 6

    private let effect = RoundedEffectView()
    private let contextIcon = NSImageView()
    private let contextLabel = NSTextField(labelWithString: "")
    private let contextAction = NSTextField(labelWithString: "")
    private let filterLabel = NSTextField(labelWithString: "")
    /// 这两个要在 `updateChrome` 里换颜色（面板形态整条变强调色底、有筛选词时输入框描边点亮）。
    private var contextRow: NSStackView!
    private var filterBox: NSStackView!
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
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect

        // 上下文：一行结论，解释都在 tooltip 里
        contextIcon.imageScaling = .scaleProportionallyDown
        contextLabel.font = .systemFont(ofSize: 12)
        contextLabel.textColor = .labelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextAction.font = .systemFont(ofSize: 12)
        contextAction.textColor = .tertiaryLabelColor

        // 设计稿 1a/1c：高 32、左右内边距 11、间距 7、图标 14；文件面板形态整条铺 accent-soft。
        contextRow = NSStackView(views: [contextIcon, contextLabel, NSView(), contextAction])
        contextRow.orientation = .horizontal
        contextRow.spacing = 7
        contextRow.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        contextRow.wantsLayer = true
        contextRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
        contextIcon.setContentHuggingPriority(.required, for: .horizontal)
        contextAction.setContentHuggingPriority(.required, for: .horizontal)
        contextIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        contextIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        contextRow.toolTip = "快捷条会跟着当前上下文改动作：在桌面或 Finder 里是「打开」，在上传/保存窗里变成「跳转到此」。"

        // 筛选：直接吃键盘输入，不用 NSTextField，省掉一层焦点管理
        // 设计稿 1a：一个 26 高、圆角 6、1px 描边的输入框，**没有放大镜图标** ——
        // 占位文字「输入即可筛选」已经把它是什么说清楚了，再加个图标是重复。
        filterLabel.font = .systemFont(ofSize: 12.5)
        filterBox = NSStackView(views: [filterLabel])
        filterBox.orientation = .horizontal
        filterBox.spacing = 6
        filterBox.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        filterBox.wantsLayer = true
        filterBox.layer?.cornerRadius = 6
        filterBox.layer?.borderWidth = 1
        filterBox.heightAnchor.constraint(equalToConstant: 26).isActive = true

        filterBox.toolTip = "支持拼音：「下载」可以输 xiazai，也可以只输首字母 xz。"
        let filterRow = NSStackView(views: [filterBox])
        filterRow.orientation = .horizontal
        filterRow.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 3, right: 9)
        filterBox.widthAnchor.constraint(equalTo: filterRow.widthAnchor, constant: -18).isActive = true

        // 列表
        listStack.orientation = .vertical
        listStack.spacing = 0
        listStack.alignment = .leading
        listStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 6, right: 6)
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
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        footer.heightAnchor.constraint(equalToConstant: 26).isActive = true
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.5).cgColor

        let separator = NSBox()
        separator.boxType = .separator

        let contextSeparator = NSBox()
        contextSeparator.boxType = .separator

        let root = NSStackView(views: [contextRow, contextSeparator, filterRow, scrollView, separator, footer])
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
            contextSeparator.widthAnchor.constraint(equalTo: root.widthAnchor),
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
        Availability.shared.refresh()   // 后台跑，不挡这次弹出
        MaterialFeed.shared.refresh(force: false)   // 同样是后台；这次弹出用的是缓存
        filter = ""
        selection = 0
        panelContext = PanelService.shared.currentPanel()
        FinderService.shared.refresh()
        reload()

        let point = NSEvent.mouseLocation
        setFrameTopLeft(near: point)

        // 必须把应用本身激活。键盘事件只会送给「当前活跃应用」的 key window，
        // QuickBar 平时是不活跃的后台程序，光 makeKey() 收不到任何按键——
        // 表现就是弹出来了但打字没反应、回车也没反应。
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        orderFrontRegardless()
        makeKey()
    }

    func hide() {
        orderOut(nil)
        // 把活跃状态还回去，否则会一直挡着用户原来在用的那个应用。
        // 设置窗之类还开着的时候不能还，那会把它也踢到后面。
        let hasOtherWindow = NSApp.windows.contains { $0 !== self && $0.isVisible }
        if !hasOtherWindow { NSApp.deactivate() }
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

        // 素材批次排在最前：这批目录带时间戳、每派一单换一个，是最可能要跳过去的地方。
        // 不筛选时只列最近几条（免得把手工条目挤出视野），但**把总数写在标题上**——
        // 悄悄截断会让人以为「那一批没下下来」。
        let batches = rank(MaterialFeed.shared.items, needle: needle)
        if !batches.isEmpty {
            let shown = needle.isEmpty ? Array(batches.prefix(Self.batchPreviewCount)) : batches
            entries.append(.header(shown.count < batches.count
                                   ? "素材批次 · 最近 \(shown.count) / 共 \(batches.count)"
                                   : "素材批次"))
            entries.append(contentsOf: shown.map { .item($0, pinned: false) })
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
                // 设计稿 1a：分组之间插一条分隔线（第一组前面不插），标题 11pt semibold。
                if pieces > 0 {
                    let line = NSBox()
                    line.boxType = .separator
                    let holder = NSStackView(views: [line])
                    holder.edgeInsets = NSEdgeInsets(top: 6, left: 7, bottom: 0, right: 7)
                    listStack.addArrangedSubview(holder)
                    holder.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                    line.widthAnchor.constraint(equalTo: holder.widthAnchor, constant: -14).isActive = true
                    contentListHeight += 7
                    pieces += 1
                }
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                let wrapper = NSStackView(views: [label])
                wrapper.edgeInsets = NSEdgeInsets(top: pieces == 0 ? 8 : 2, left: 6, bottom: 3, right: 6)
                listStack.addArrangedSubview(wrapper)
                wrapper.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                contentListHeight += pieces == 0 ? 25 : 19
                pieces += 1

            case .item(let item, let pinned):
                let availability = Availability.shared.state(of: item)
                // 找不到的条目照样列出来（免得用户以为自己没加过），
                // 但置灰、不可选中，右侧一行说清是什么情况。
                let unavailableNote = availability.label
                let disabled = unavailableNote != nil || (panelContext != nil && item.kind == .app)
                let row = RowView(item: item, pinned: pinned, disabled: disabled,
                                  note: unavailableNote, icon: icon(for: item))
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
        let accent = NSColor.controlAccentColor
        if let context = panelContext {
            contextIcon.image = NSImage(systemSymbolName: "tray.and.arrow.up", accessibilityDescription: nil)
            contextIcon.contentTintColor = accent
            contextLabel.stringValue = "\(context.kind == .save ? "保存窗" : "上传窗") · \(context.ownerName ?? "未知应用")"
            contextAction.stringValue = "跳转"
            contextAction.font = .systemFont(ofSize: 12, weight: .semibold)
            contextAction.textColor = accent
            // 设计稿 1c：文件面板形态整条铺一层强调色底 —— 这是快捷条唯一会改变形态的时候，
            // 值得让人一眼看出「现在按回车不是打开，是跳转」。
            contextRow.layer?.backgroundColor = accent.withAlphaComponent(0.13).cgColor
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
            contextAction.font = .systemFont(ofSize: 12)
            contextAction.textColor = .tertiaryLabelColor
            contextRow.layer?.backgroundColor = NSColor.clear.cgColor
            footerLeft.stringValue = filter.isEmpty ? "↑↓ 选择 · ↩ 打开" : "筛选：\(filter)"
            footerRight.stringValue = ""
        }
        // 有筛选词就把输入框点亮（设计稿 1b：1.5px 强调色描边 + 一层很淡的底）。
        // 光晕（`box-shadow 0 0 0 3px`）在 AppKit 里要再套一层视图，收益不抵复杂度，只做描边和底。
        let typing = !filter.isEmpty
        filterBox.layer?.borderWidth = typing ? 1.5 : 1
        filterBox.layer?.borderColor = (typing ? accent : NSColor.separatorColor).cgColor
        filterBox.layer?.backgroundColor = typing
            ? accent.withAlphaComponent(0.10).cgColor
            : NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        filterLabel.stringValue = filter.isEmpty ? "输入即可筛选" : filter
        filterLabel.textColor = filter.isEmpty ? .tertiaryLabelColor : .labelColor
        // 筛选态右下角给一条出路：不写的话「怎么把它清掉」只能靠试（设计稿 1b）。
        if typing, panelContext == nil { footerRight.stringValue = "⎋ 清空" }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
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
    private var pinned = false
    /// 右侧那行的固有颜色（素材批次的上传状态用）。nil = 跟着普通次要色。
    private var tone: NSColor?

    init(item: QuickItem, pinned: Bool, disabled: Bool, note: String?, icon: NSImage) {
        self.disabled = disabled
        super.init(frame: .zero)
        wantsLayer = true
        // 设计稿 1a：普通行圆角 6；置顶那张卡片圆角 8、带强调色描边。
        layer?.cornerRadius = pinned ? 8 : 6
        if pinned {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor
        }
        self.pinned = pinned

        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.font = pinned ? .systemFont(ofSize: 12.5, weight: .semibold) : .systemFont(ofSize: 13)
        nameLabel.stringValue = item.name
        nameLabel.lineBreakMode = .byTruncatingTail

        // 置顶那张卡片第二行是完整路径，等宽字体读起来更像"地址"（设计稿 1c）。
        detailLabel.font = pinned
            ? .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            : .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.alignment = .right

        if let note {
            detailLabel.stringValue = note
            toolTip = note.contains("未挂载")
                ? "接回这个卷就能用了。QuickBar 不会因为找不到就把条目删掉。"
                : "\(item.path) 已经不在了。右键可以移除这个条目。"
        } else if pinned {
            // 设计稿 1c：第二行写完整路径（人要确认跳的是不是同名的另一个目录），
            // 右上角一枚实底徽标点明这行的身份。
            detailLabel.stringValue = item.path
            detailLabel.alignment = .left
            detailLabel.textColor = .tertiaryLabelColor
            badge.stringValue = " Finder 当前 "
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .white
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 4
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        } else if disabled {
            detailLabel.stringValue = "面板内不可用"
            toolTip = "文件面板里没有「启动应用」这个动作。"
        } else if item.kind == .app {
            detailLabel.stringValue = Actions.isRunning(item) ? "切到前台" : "启动"
        } else if let subtitle = item.subtitle, !subtitle.isEmpty {
            // 来源自己写好的一行结论（素材批次的件数/进度）比紧凑路径有用得多。
            detailLabel.stringValue = subtitle
            // 设计稿 1a 给上传状态定了颜色：传完了绿、差几张橙、正在传就跟着普通次要色。
            // 🔴 靠文案判断，不给 `QuickItem` 加字段 —— 那是要落盘的结构，
            //    给它加非 Optional 字段会让老 items.json 解不开（见 CLAUDE.md）。
            //    这三个词是 MaterialFeed 自己拼的，就在同一个仓库里，改了这儿会一起改。
            if subtitle.contains("已传") { tone = .systemGreen }
            else if subtitle.contains("差") { tone = .systemOrange }
            toolTip = item.path
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
        stack.edgeInsets = NSEdgeInsets(top: 0, left: pinned ? 8 : 7, bottom: 0, right: pinned ? 8 : 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: pinned ? 16 : 14),
            iconView.heightAnchor.constraint(equalToConstant: pinned ? 16 : 14),
            runningDot.widthAnchor.constraint(equalToConstant: 5),
            runningDot.heightAnchor.constraint(equalToConstant: 5)
        ])
        // 右侧那行谁先让位：手工条目右边是长路径，压掉不心疼；素材批次右边是「件数 · 时间」
        // 这种结论，压了就成 "28 件…09:16"，把最该看的信息弄没了 —— 所以反过来让名字先截尾
        // （品牌名在最前面，截掉的是批次码尾巴，照样认得出来）。
        if item.subtitle?.isEmpty == false {
            detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        } else {
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        alphaValue = disabled ? 0.45 : 1
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        if pinned {
            // 置顶卡片本来就有强调色描边，选中时只把底加深，别整块刷成实底 ——
            // 那样它跟普通选中行就分不出来了（设计稿 1c 里它是一张卡片，不是一行）。
            layer?.backgroundColor = (isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.textBackgroundColor.withAlphaComponent(0.5)).cgColor
        } else {
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        let onAccent = isSelected && !pinned
        nameLabel.textColor = onAccent ? .white : .labelColor
        detailLabel.textColor = onAccent
            ? NSColor.white.withAlphaComponent(0.85)
            : (tone ?? (pinned ? .tertiaryLabelColor : .secondaryLabelColor))
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
