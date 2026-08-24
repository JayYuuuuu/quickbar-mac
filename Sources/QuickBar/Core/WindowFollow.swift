import AppKit
import ApplicationServices

/// 盯着某个应用最前面那个窗口在哪儿、多大，一动就喊一声。药丸靠它贴着窗口走。
///
/// 【为什么不用定时轮询】药丸是贴着访达 / PS 的窗口浮着的，窗口一拖它得跟着。
/// 轮询要跟手就得 10Hz 以上，而这颗药丸在 PS 里可能挂好几分钟（人在修图）——
/// 那就是几分钟的持续跨进程 IPC。AX 的移动/缩放通知是**推**过来的：拖窗时连续到，
/// 平时一次都不发，正好是这个软件要的「平时零负载」。
///
/// 【三条不能踩的】
/// 🔴 **换了窗口要重新注册。** 移动/缩放通知是注册在**那个窗口元素**上的，不是应用上。
///    人在访达里 ⌘N 开一个新窗口，旧注册还挂在旧窗口上、新窗口一声不响 ——
///    表现是「有时候跟、有时候不跟」，最难查的那种。所以应用元素上还得盯一个
///    `focusedWindowChanged`，一变就把窗口那几个通知重新挂过去。
/// 🔴 **run loop source 挂在主线程的 run loop 上。** 回调里要动 NSPanel，AppKit 只认主线程。
/// 🔴 **AX 调用是跨进程 IPC**：对面卡住时不设超时会把自己也拖住，沿用 `AX.messagingTimeout`。
///    另外**通知会漏**（切空间、换显示器、别的程序代为移动窗口都可能），所以调用方那边
///    还留着 1.5 秒的心跳兜一次底 —— 推送负责跟手，心跳负责别跑偏。
final class WindowFollow {

    /// 窗口动了 / 换了 / 没了。一律在主线程上叫。
    var onChange: (() -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var pid: pid_t = 0
    private var bundleID: String?

    private static let appNotes = [kAXFocusedWindowChangedNotification,
                                   kAXMainWindowChangedNotification]
    private static let winNotes = [kAXMovedNotification,
                                   kAXResizedNotification,
                                   kAXWindowMiniaturizedNotification,
                                   kAXUIElementDestroyedNotification]

    // MARK: - 开关

    /// 开始跟这个应用。已经在跟同一个就什么都不做（重复注册会白白多一份回调）。
    func follow(_ bundleID: String) {
        guard Permissions.isGranted(.accessibility) else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { stop(); return }
        if self.bundleID == bundleID, pid == app.processIdentifier, observer != nil {
            refreshWindow()          // 应用没换，但最前面那个窗口可能换了
            return
        }
        stop()

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowFollow>.fromOpaque(refcon).takeUnretainedValue()
            // 通知是在主线程的 run loop 上到的，直接办事即可。
            me.handle()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }

        observer = obs
        pid = app.processIdentifier
        self.bundleID = bundleID
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, AX.messagingTimeout)
        appElement = element

        let me = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.appNotes {
            AXObserverAddNotification(obs, element, note as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        refreshWindow()
    }

    func stop() {
        if let obs = observer {
            if let el = appElement {
                for note in Self.appNotes { AXObserverRemoveNotification(obs, el, note as CFString) }
            }
            unhookWindow()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        appElement = nil
        windowElement = nil
        pid = 0
        bundleID = nil
    }

    // MARK: - 窗口

    private func handle() {
        // 任何一条通知都可能意味着「最前面的窗口换人了」，重挂一次代价只有几次 AX 读取。
        refreshWindow()
        onChange?()
    }

    /// 把移动/缩放那几条通知挂到**当前**最前那个窗口上。
    private func refreshWindow() {
        guard let obs = observer, let app = appElement else { return }
        let front = AX.element(app, AXAttr.focusedWindow) ?? AX.elements(app, AXAttr.windows).first
        // 同一个窗口就别重挂了 —— `AXObserverAddNotification` 对已注册的会返回
        // `notificationAlreadyRegistered`，不致命，但每次都试一遍纯属浪费。
        if let front, let current = windowElement, CFEqual(front, current) { return }
        unhookWindow()
        guard let front else { return }
        AXUIElementSetMessagingTimeout(front, AX.messagingTimeout)
        windowElement = front
        let me = Unmanaged.passUnretained(self).toOpaque()
        for note in Self.winNotes {
            AXObserverAddNotification(obs, front, note as CFString, me)
        }
    }

    private func unhookWindow() {
        guard let obs = observer, let win = windowElement else { return }
        for note in Self.winNotes { AXObserverRemoveNotification(obs, win, note as CFString) }
        windowElement = nil
    }

    // MARK: - 位置

    /// 宿主窗口被最小化了。设计稿要求这时候把药丸收掉 ——
    /// 它是「附着在这个窗口上」的东西，窗口进了程序坞它还浮着就成了孤儿。
    /// （被别的窗口遮挡不用单独判：药丸只在宿主是最前面那个应用时才出现。）
    var hostMinimized: Bool {
        guard let win = windowElement else { return false }
        return AX.value(win, kAXMinimizedAttribute) as Bool? ?? false
    }

    /// 正在跟的那个窗口，换算成 AppKit 坐标之后的矩形。拿不到就是 nil。
    var frame: CGRect? {
        guard let win = windowElement else { return nil }
        return Self.toAppKit(win)
    }

    /// 现查一次某个应用最前窗口的矩形（还没开始跟、或者通知漏了的时候用）。
    static func frontWindowFrame(of bundleID: String) -> CGRect? {
        guard Permissions.isGranted(.accessibility),
              let host = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let app = AXUIElementCreateApplication(host.processIdentifier)
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
        guard let win = AX.element(app, AXAttr.focusedWindow) ?? AX.elements(app, AXAttr.windows).first
        else { return nil }
        return toAppKit(win)
    }

    /// 🔴 AX 给的坐标是「主屏左上角为原点、y 向下」，AppKit 是「左下为原点、y 向上」，必须翻一次。
    ///    翻错了的表现是药丸跑到屏幕外（看着像"没弹出来"）。
    private static func toAppKit(_ win: AXUIElement) -> CGRect? {
        guard let pos = AX.position(win), let sz = AX.size(win), sz.width > 120, sz.height > 80,
              // 主屏（原点在 (0,0) 那块）的高度是两套坐标之间的换算基准
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return nil }
        let y = primary.frame.maxY - (pos.y + sz.height)
        return CGRect(x: pos.x, y: y, width: sz.width, height: sz.height)
    }
}
