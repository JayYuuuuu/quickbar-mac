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
                                   kAXMainWindowChangedNotification,
                                   // 进度框这类冒出来的窗口不一定抢焦点，出来就得看它挡没挡住药丸
                                   kAXWindowCreatedNotification]
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

    /// 把移动/缩放那几条通知挂到**当前**该贴的那个窗口上。
    private func refreshWindow() {
        guard let obs = observer, let app = appElement, let bundleID else { return }
        let front = Self.hostWindow(app, bundleID: bundleID)
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

    // MARK: - 贴哪个窗口

    /// 这个应用里只有带这个 AXIdentifier 的窗口才算宿主。没列的应用：最前面那个就是。
    ///
    /// 🔴 **访达不能直接拿「当前窗口」。** 拷贝 / 移动的进度框也是访达的一个窗口，一冒出来就
    ///    抢成当前窗口（2026-09-17 mac24g 实测：AXFocusedWindow、AXMainWindow 都是「拷贝」），
    ///    药丸于是贴进那个 404×88 的小框右下角，正好压住进度条（用户实拍）。
    ///    子角色分不开 —— 两个都是 AXStandardWindow；分得开的是 AXIdentifier：
    ///    浏览窗口 = `FinderWindow`（带工具栏），进度框 = `Progress`（同一轮实测）。
    ///    PS 没量过它的窗口长什么样，保持原样。
    private static let hostIdentifier = ["com.apple.finder": "FinderWindow"]
    /// 就算认不出宿主，也绝不能贴上去的那些。
    private static let neverHost: Set<String> = ["Progress"]

    /// 按上面的口径挑宿主窗口。`windows` 是从前往后排的（同一轮实测：进度框排第一）。
    ///
    /// 认不出 `FinderWindow` 时退回「最前面那个、只要不是进度框」—— 只在 macOS 27 上量过这个名字，
    /// 别的系统版本要是叫法不同，退回去就是改之前的行为，不至于药丸没处贴。
    private static func hostWindow(_ app: AXUIElement, bundleID: String) -> AXUIElement? {
        let focused = AX.element(app, AXAttr.focusedWindow)
        guard let want = hostIdentifier[bundleID] else {
            return focused ?? AX.elements(app, AXAttr.windows).first
        }
        if let focused, AX.string(focused, AXAttr.identifier) == want { return focused }
        let ordered = (focused.map { [$0] } ?? []) + AX.elements(app, AXAttr.windows)
        return ordered.first { AX.string($0, AXAttr.identifier) == want }
            ?? ordered.first { !neverHost.contains(AX.string($0, AXAttr.identifier) ?? "") }
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

    /// 挡在宿主窗口前面的、同一应用的其它窗口（AppKit 坐标）。药丸要躲开它们。
    ///
    /// 只看 `hostIdentifier` 里列了的应用：访达的窗口量过，PS 的没量过 ——
    /// 它的浮动面板要是也在 `windows` 里，药丸会莫名其妙地跳，所以先不碰。
    /// 平时宿主就排第一，读一次窗口列表就返回；进度框在的时候多读它一个的位置和大小。
    var obstacles: [CGRect] {
        guard let bundleID, Self.hostIdentifier[bundleID] != nil,
              let app = appElement, let host = windowElement else { return [] }
        var out: [CGRect] = []
        for w in AX.elements(app, AXAttr.windows) {
            if CFEqual(w, host) { return out }
            if AX.value(w, kAXMinimizedAttribute) as Bool? == true { continue }
            if let r = Self.toAppKit(w, minSize: .zero) { out.append(r) }
        }
        return []      // 列表里压根没有宿主：说不清谁在它前面，那就谁都不躲
    }

    /// 现查一次某个应用宿主窗口的矩形（还没开始跟、或者通知漏了的时候用）。
    static func frontWindowFrame(of bundleID: String) -> CGRect? {
        guard Permissions.isGranted(.accessibility),
              let host = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let app = AXUIElementCreateApplication(host.processIdentifier)
        AXUIElementSetMessagingTimeout(app, AX.messagingTimeout)
        guard let win = hostWindow(app, bundleID: bundleID) else { return nil }
        return toAppKit(win)
    }

    /// 🔴 AX 给的坐标是「主屏左上角为原点、y 向下」，AppKit 是「左下为原点、y 向上」，必须翻一次。
    ///    翻错了的表现是药丸跑到屏幕外（看着像"没弹出来"）。
    ///    `minSize` 是给宿主用的门槛（太小的窗口贴不下药丸）；算障碍物时不设门槛。
    private static func toAppKit(_ win: AXUIElement, minSize: CGSize = CGSize(width: 120, height: 80)) -> CGRect? {
        guard let pos = AX.position(win), let sz = AX.size(win), sz.width > minSize.width, sz.height > minSize.height,
              // 主屏（原点在 (0,0) 那块）的高度是两套坐标之间的换算基准
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        else { return nil }
        let y = primary.frame.maxY - (pos.y + sz.height)
        return CGRect(x: pos.x, y: y, width: sz.width, height: sz.height)
    }
}
