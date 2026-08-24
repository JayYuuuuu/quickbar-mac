import AppKit
import UserNotifications

/// 把话说给人听。**这个软件里所有「结果和你以为的不一样」都必须走这儿**——
/// 静悄悄地降级比什么都不做更坏：人以为打开的是 A，其实是 B。
enum Notify {

    /// 「你刚点了一下、结果跟你以为的不一样」——**这种必须弹框，不能走通知**。
    ///
    /// 🔴 通知会被专注模式、或者「通知样式：无」**整条吞掉**：2026-08-24 实测，
    ///    「存回原位」连点三次、三条通知全部投递成功（`hasError: 0`），人一条都没看见，
    ///    表现就是「按了没反应」，白查了一轮。人主动触发的动作出岔子还走横幅，
    ///    就是这个软件最不该有的那种静默失败。
    static func problem(_ title: String, _ body: String) {
        log("\(title)：\(body)")
        guard Bundle.main.bundleIdentifier != nil else { return }
        DispatchQueue.main.async { alert(title, body) }
    }

    /// 通知优先；没授权就退回弹框。两条路都走不通至少留一行日志。
    /// **只用于自己发生的事**（素材批次下完了这种）；人刚点过的动作用 `problem`。
    static func tell(_ title: String, _ body: String) {
        log("\(title)：\(body)")
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

    // MARK: - 日志

    /// `~/Library/Logs/QuickBar.log`。
    ///
    /// 🔴 **NSLog 的正文在统一日志里是 `<private>`**：`log show` 只看得到一行 `<private>`，
    ///    远程排查等于什么都没有（2026-08-24 就是卡在这儿）。这个文件是唯一能捞到的现场。
    private static let logURL: URL? = try? FileManager.default
        .url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        .appendingPathComponent("Logs/QuickBar.log")

    /// 超过这个大小就从头来过。这是排查用的现场，不是审计流水，留最近的就够。
    private static let logCap = 256 * 1024

    static func log(_ line: String) {
        NSLog("[QuickBar] \(line)")
        guard let url = logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        logQueue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > logCap {
                try? fm.removeItem(at: url)
            }
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }

    /// 写盘不占调用方的线程 —— 素材盘忙的时候连家目录都可能慢。
    private static let logQueue = DispatchQueue(label: "quickbar.log", qos: .utility)

    private static func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
