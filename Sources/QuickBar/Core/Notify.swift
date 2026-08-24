import AppKit
import UserNotifications

/// 把话说给人听。**这个软件里所有「结果和你以为的不一样」都必须走这儿**——
/// 静悄悄地降级比什么都不做更坏：人以为打开的是 A，其实是 B。
enum Notify {

    /// 通知优先；没授权就退回弹框。两条路都走不通至少留一行日志。
    static func tell(_ title: String, _ body: String) {
        NSLog("[QuickBar] \(title)：\(body)")
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                if granted {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    let id = "notify-\(Int(Date().timeIntervalSince1970 * 1000))"
                    UNUserNotificationCenter.current()
                        .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                } else {
                    alert(title, body)
                }
            }
        }
    }

    /// 问一声。QuickBar 是后台程序（accessory），不先 activate 的话弹框会出在别人后面看不见。
    @discardableResult
    static func confirm(_ title: String, _ body: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
