import AppKit

/// 一份不会显示出来的主菜单。
///
/// QuickBar 是 `LSUIElement`，菜单栏不归它管，所以这份菜单永远不出现。
/// 但 AppKit 的快捷键分发要经过 `NSApp.mainMenu`——没有它，
/// 设置窗里 ⌘W 关不掉窗口、重命名输入框里 ⌘C/⌘V 也不好使。
enum MainMenu {

    static func install() {
        let main = NSMenu()

        main.addItem(submenu(title: "QuickBar", items: [
            (title: "退出 QuickBar", selector: #selector(NSApplication.terminate(_:)), key: "q", modifiers: [.command])
        ]))

        main.addItem(submenu(title: "编辑", items: [
            (title: "撤销", selector: Selector(("undo:")), key: "z", modifiers: [.command]),
            (title: "重做", selector: Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            (title: nil, selector: nil, key: "", modifiers: []),
            (title: "剪切", selector: #selector(NSText.cut(_:)), key: "x", modifiers: [.command]),
            (title: "拷贝", selector: #selector(NSText.copy(_:)), key: "c", modifiers: [.command]),
            (title: "粘贴", selector: #selector(NSText.paste(_:)), key: "v", modifiers: [.command]),
            (title: "全选", selector: #selector(NSText.selectAll(_:)), key: "a", modifiers: [.command])
        ]))

        main.addItem(submenu(title: "窗口", items: [
            (title: "关闭", selector: #selector(NSWindow.performClose(_:)), key: "w", modifiers: [.command]),
            (title: "最小化", selector: #selector(NSWindow.miniaturize(_:)), key: "m", modifiers: [.command])
        ]))

        NSApp.mainMenu = main
    }

    private typealias Entry = (title: String?, selector: Selector?, key: String, modifiers: NSEvent.ModifierFlags)

    private static func submenu(title: String, items: [Entry]) -> NSMenuItem {
        let container = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in items {
            guard let entryTitle = entry.title, let selector = entry.selector else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entryTitle, action: selector, keyEquivalent: entry.key)
            item.keyEquivalentModifierMask = entry.modifiers
            // target 留空，交给响应链——这样快捷键会落到当前的输入框或窗口上。
            menu.addItem(item)
        }
        container.submenu = menu
        return container
    }
}
