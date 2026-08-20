import AppKit
import IOKit.hid
import ServiceManagement

/// QuickBar 需要的三项授权，以及开机自启。
enum Permissions {

    enum Kind: String, CaseIterable, Identifiable {
        case accessibility, inputMonitoring, automation
        var id: String { rawValue }

        var title: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .inputMonitoring: return "输入监控"
            case .automation: return "自动化 · Finder"
            }
        }

        /// 一句话说清「没有它会怎样」，界面上只在 tip 里出现。
        var why: String {
            switch self {
            case .accessibility: return "用来判断当前是不是文件面板，以及调整面板尺寸。"
            case .inputMonitoring: return "用来接收唤出快捷条的双击和跳转快捷键。QuickBar 不记录也不上传任何按键。"
            case .automation: return "用来读取 Finder 最前窗口所在的文件夹。没有它，跳转会退回上次记住的路径。"
            }
        }

        var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .automation: anchor = "Privacy_Automation"
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
        }
    }

    static var allGranted: Bool { Kind.allCases.allSatisfy(isGranted) }

    /// 请求授权。系统只在第一次弹框，之后只能引导用户去设置里手动开。
    static func request(_ kind: Kind) {
        switch kind {
        case .accessibility:
            _ = AX.isTrusted(prompt: true)
        case .inputMonitoring:
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case .automation:
            FinderService.shared.refresh(force: true)   // 触发系统的自动化授权框
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
