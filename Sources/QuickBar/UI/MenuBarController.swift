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

    override init() {
        super.init()
        statusItem.button?.image = MenuBarController.icon()
        statusItem.button?.toolTip = "QuickBar"
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
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

        menu.addItem(.separator())

        let settings = item("设置…", action: #selector(openSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)

        let missing = Permissions.Kind.allCases.filter { !Permissions.isGranted($0) }
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

    private func dot(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
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
    @objc private func checkUpdates() { Updater.shared.check(userInitiated: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// 菜单栏图标：三条横杠加一个右尖角，模板图会自动跟随深浅色和高亮态。
    static func icon() -> NSImage {
        let size = NSSize(width: 17, height: 15)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let bars: [(CGFloat, CGFloat)] = [(11, 7.5), (6.6, 9.5), (2.2, 5.5)]
            for (y, width) in bars {
                NSBezierPath(roundedRect: NSRect(x: 1.5, y: y, width: width, height: 1.9),
                             xRadius: 0.95, yRadius: 0.95).fill()
            }
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: 11.2, y: 6.4))
            chevron.line(to: NSPoint(x: 14.2, y: 3.9))
            chevron.line(to: NSPoint(x: 11.2, y: 1.4))
            chevron.lineWidth = 1.7
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.setStroke()
            chevron.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private extension NSStatusItem {
    static func buttonItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }
}
