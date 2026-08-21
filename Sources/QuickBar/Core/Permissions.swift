import AppKit
import IOKit.hid
import ServiceManagement
import UserNotifications

/// QuickBar 用到的授权，以及开机自启。
///
/// 前三项是**必需**的，缺一项就有功能坏掉，引导页和菜单栏只认这三项。
/// 通知是**可选**的：没有它素材批次照常更新，只是下完不弹横幅——
/// 所以它只出现在设置页，不参与「还差几项授权」的计数，也不点亮那个橙点。
enum Permissions {

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, inputMonitoring, automation, notifications
        var id: String { rawValue }

        /// 引导页和菜单栏只看这三项。
        static let core: [Kind] = [.accessibility, .inputMonitoring, .automation]

        var isRequired: Bool { Self.core.contains(self) }

        var title: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .inputMonitoring: return "输入监控"
            case .automation: return "自动化 · Finder"
            case .notifications: return "通知"
            }
        }

        /// 一句话说清「没有它会怎样」，界面上只在 tip 里出现。
        var why: String {
            switch self {
            case .accessibility: return "用来判断当前是不是文件面板，以及调整面板尺寸。"
            case .inputMonitoring: return "用来接收唤出快捷条的双击和跳转快捷键。QuickBar 不记录也不上传任何按键。"
            case .automation: return "用来读取 Finder 最前窗口所在的文件夹。没有它，跳转会退回上次记住的路径。"
            case .notifications: return "素材批次下完了弹一条横幅，点一下直接在 Finder 里打开它。没有它批次照常更新，只是不会主动提醒。"
            }
        }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .automation: anchor = "Privacy_Automation"
            case .notifications:
                // 通知不在「隐私与安全性」里，是独立的一页（实测这个 id 能开，
                // com.apple.Notifications-Settings.extension 打不开）。
                return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:
            return AX.isTrusted()
        case .inputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        case .automation:
            return FinderService.automationGranted()
        case .notifications:
            // 通知授权只能异步查，这里回缓存值并顺手刷一次。
            // 设置页两秒一次的心跳会盯着它，第一次显示慢半拍无所谓。
            refreshNotificationsCache()
            return notificationsGranted
        }
    }

    /// 只看必需的三项。引导页放行、事件 tap 启动都以它为准——
    /// 通知没给不该拦着人用快捷条。
    static var allGranted: Bool { Kind.core.allSatisfy(isGranted) }

    private static var notificationsGranted = false

    private static func refreshNotificationsCache() {
        // 没有 bundle id 时（`swift run` 直接跑）UNUserNotificationCenter 会崩。
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { notificationsGranted = ok }
        }
    }

    /// 请求授权。系统只在第一次弹框，之后只能引导用户去设置里手动开。
    static func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            _ = AX.isTrusted(prompt: true)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .automation:
            FinderService.shared.refresh(force: true)   // 触发系统的自动化授权框
        case .notifications:
            guard Bundle.main.bundleIdentifier != nil else { break }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                refreshNotificationsCache()
            }
        }
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// 开机自启。用 SMAppService，不手写 LaunchAgent plist。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("[QuickBar] 开机自启设置失败: \(error.localizedDescription)")
        }
    }
}
