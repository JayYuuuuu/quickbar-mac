import AppKit

/// 菜单栏那个小图标和它的菜单。
///
/// 界面是「默认静默、有事才说话」：图标平时是普通模板色，
/// 权限掉了才变成需要注意的样子。
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusItem.buttonItem()
    private let menu = NSMenu()

    var onShowQuickBar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onToggleTrigger: (() -> Void)?
    var onJumpToFinder: (() -> Void)?
    var onOpenNewestBatch: (() -> Void)?
    var onMainImagesToPhotoshop: (() -> Void)?
    var onSaveBackAll: (() -> Void)?
    var onRevealPhotoshopFront: (() -> Void)?
    var onOpenBatchLinksDir: (() -> Void)?

    override init() {
        super.init()
        statusItem.button?.image = MenuBarController.icon()
        statusItem.button?.toolTip = "QuickBar"
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()
        menu.removeAllItems()

        menu.addItem(item("唤出快捷条", action: #selector(showQuickBar)))

        let paused = !EventTapService.shared.isRunning
        menu.addItem(item(paused ? "恢复触发" : "暂停触发", action: #selector(toggleTrigger)))

        if Permissions.isGranted(.automation) {
            let jump = item("跳到 Finder 当前", action: #selector(jumpToFinder))
            jump.toolTip = FinderService.shared.currentPath
            menu.addItem(jump)
        }

        // 最新那一批素材：下完之后第一件事就是去开它，给个不用弹快捷条的入口。
        if let batch = MaterialFeed.shared.newest {
            let open = item("打开 \(batch.name)", action: #selector(openNewestBatch))
            open.toolTip = batch.path
            menu.addItem(open)
        }

        // 下载完素材的下一步就是去水印：站在 Finder 里选中几个商品文件夹，一下全丢进 PS。
        // 🔴 只在「能问到 Finder」且**真装了 Photoshop** 时才出这一项 —— 摆一个点了只会弹
        //    「没找到 Photoshop」的菜单项，是把自己的实现细节摊给人看。
        if Permissions.isGranted(.automation),
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: MainImages.photoshopBundleID) != nil {
            let ps = item("主图丢进 PS", action: #selector(mainImagesToPhotoshop))
            ps.toolTip = "把 Finder 里选中的商品文件夹（或整批）的「主图」全部在 Photoshop 里打开。没选就用当前窗口那个文件夹。"
            menu.addItem(ps)
        }

        // 改完之后的收尾。**只在 PS 真的在跑时才出现** —— 它俩问的都是「PS 现在开着什么」，
        // PS 没在跑时点了只会弹一句「没在跑」，那是把实现细节摊给人看。
        if Store.shared.settings.psSaveBackEnabled, Photoshop.isRunning {
            let key = KeySymbols.describe(
                flags: CGEventFlags(rawValue: UInt64(Store.shared.settings.psSaveBackModifierFlags)),
                keyCode: CGKeyCode(Store.shared.settings.psSaveBackKeyCode))
            let all = item("全部存回原位", action: #selector(saveBackAll))
            all.toolTip = "把 PS 里打开的图挨个拼合、按各自的原路径覆盖存回、关掉。"
                + "只认 jpg 和 png，别的原样留着。一张一张来的话在 PS 里按 \(key)。"
            menu.addItem(all)

            let reveal = item("PS 当前这张在访达里", action: #selector(revealPhotoshopFront))
            reveal.toolTip = "打开 Photoshop 最前那个文档所在的素材文件夹，并选中它。"
            menu.addItem(reveal)
        }

        if Store.shared.settings.batchLinksEnabled, Store.shared.settings.materialFeedEnabled {
            let links = item("最近素材批次…", action: #selector(openBatchLinksDir))
            links.toolTip = "打开 ~/\(BatchLinks.dirName)/ —— 里面是最近几批的替身，把这个目录拖进 Finder 侧栏就常驻了。"
            menu.addItem(links)
        }

        menu.addItem(.separator())

        let settings = item("设置…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)

        // 只数必需的三项：通知没给不算「还差授权」，那是设置页里的事。
        let missing = Permissions.Kind.core.filter { !Permissions.isGranted($0) }
        let permissions = item(missing.isEmpty ? "权限正常" : "还差 \(missing.count) 项授权",
                               action: #selector(openPermissions))
        permissions.image = dot(color: missing.isEmpty ? .systemGreen : .systemOrange)
        permissions.toolTip = missing.isEmpty
            ? "辅助功能、输入监控、自动化（Finder）都已授权。"
            : "未授权：" + missing.map(\.title).joined(separator: "、")
        menu.addItem(permissions)

        menu.addItem(.separator())

        let update = item("检查更新", action: #selector(checkUpdates))
        update.toolTip = Updater.shared.statusText
        menu.addItem(update)

        let version = item("版本 \(Updater.shared.currentVersion)", action: nil)
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())
        let quit = item("退出 QuickBar", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func item(_ title: String, action: Selector?) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    /// 「还差 N 项授权」左边那颗点。设计稿 1e：**用 `NSMenuItem.image` 塞一颗 7pt 圆点，
    /// 不用 emoji** —— emoji 在不同系统版本上大小和基线都会飘。
    private func dot(color: NSColor) -> NSImage {
        let size = NSSize(width: 7, height: 7)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }

    @objc private func showQuickBar() { onShowQuickBar?() }
    @objc private func toggleTrigger() { onToggleTrigger?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openPermissions() { onOpenPermissions?() }
    @objc private func jumpToFinder() { onJumpToFinder?() }
    @objc private func openNewestBatch() { onOpenNewestBatch?() }
    @objc private func mainImagesToPhotoshop() { onMainImagesToPhotoshop?() }
    @objc private func saveBackAll() { onSaveBackAll?() }
    @objc private func revealPhotoshopFront() { onRevealPhotoshopFront?() }
    @objc private func openBatchLinksDir() { onOpenBatchLinksDir?() }
    @objc private func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// 菜单栏图标：三条等长的横杠 + 一个右尖角 —— 「三个常去的地方」＋「往那边去」。
    ///
    /// 设计稿 1e 的形，16×16、描边 1.5、圆头。**必须是模板图**（`isTemplate`）：
    /// 系统会按明暗和高亮态自动反色，自己上色的话深色菜单栏里会看不见。
    /// 旧版画的是三条**不等长**的实心圆角条，在 16pt 上糊成一团，这版改成等长描边。
    static func icon() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            let bars = NSBezierPath()
            for y in [4.5, 8.0, 11.5] {
                bars.move(to: NSPoint(x: 2.5, y: y))
                bars.line(to: NSPoint(x: 9.5, y: y))
            }
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 12, y: 5.5))
            chevron.line(to: NSPoint(x: 14, y: 8))
            chevron.line(to: NSPoint(x: 12, y: 10.5))
            for path in [bars, chevron] {
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 暂停触发时把图标压到 45% 透明。
    /// 🔴 **不换图形**：两个形状要认，而「暂停」是个临时状态，
    ///    让人多记一个符号不值当（设计稿 1e 的原话）。
    func refreshIcon() {
        statusItem.button?.alphaValue = EventTapService.shared.isRunning ? 1 : 0.45
        statusItem.button?.toolTip = EventTapService.shared.isRunning
            ? "QuickBar" : "QuickBar · 已暂停触发"
    }

}

private extension NSStatusItem {
    static func buttonItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
}
