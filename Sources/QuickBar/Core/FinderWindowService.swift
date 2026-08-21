import AppKit
import ApplicationServices

/// 让新开的 Finder 窗口用你记住的尺寸。
///
/// 为什么需要这个东西（macOS 26 实测）：
///
/// Finder 的窗口尺寸是**按文件夹逐个记**的，记在**父目录的 `.DS_Store`** 里
/// （`bwsp` 记录，一段 binary plist，含 `WindowBounds`），而且**关窗那一刻才写盘**。
/// 没有记录的文件夹一律开成 **960×492**，且跟「上一个窗口多大」无关——
/// 实测一个 1520×1020 的窗口开着时新开没记录的文件夹，仍然是 960×492，只是位置错开。
/// macOS 没有「默认窗口尺寸」这个偏好可以改。
///
/// 于是两种情况必然每次都是小窗口：
/// 1. 每次新建的目录（素材批次那种时间戳目录）天生没有记录；
/// 2. `com.apple.desktopservices` 里 `DSDontWriteNetworkStores = 1` 时，
///    Finder 根本不往网络卷写 `.DS_Store`（实测在 SMB 共享上拉大再关窗，
///    `.DS_Store` 的 mtime 纹丝不动），尺寸只活在 Finder 进程内存里，
///    Finder 一重启全部回到 960×492。
///
/// 所以只能在窗口出现的那一刻自己改。**只动尺寸恰好等于系统默认值的窗口**——
/// 其他尺寸说明那个文件夹自己记着东西，是用户特意调的，不该覆盖。
final class FinderWindowService {
    static let shared = FinderWindowService()

    /// 系统默认的新窗口尺寸（实测值）。
    private static let systemDefault = CGSize(width: 960, height: 492)
    private static let tolerance: CGFloat = 8

    private var observer: AXObserver?
    private var finderPID: pid_t = 0
    private var watchedWindow: AXUIElement?
    private var resizeDebounce: Timer?
    /// 我们自己改尺寸时系统可能把窗口夹回屏幕，那一下不能被当成用户操作记下来，
    /// 否则每套用一次就缩一点，越用越小。
    private var suppressUntil: CFAbsoluteTime = 0

    private init() {}

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        // Finder 会被 killall / 自己重启，pid 一变观察器就废了，得重新绑。
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.finder" else { return }
                self?.bind()
                self?.watchFrontWindow()
            }
        }
        bind()
    }

    // MARK: - 绑定

    private func bind() {
        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let pid = finder.processIdentifier
        guard pid != finderPID || observer == nil else { return }

        teardown()
        var created: AXObserver?
        guard AXObserverCreate(pid, finderObserverCallback, &created) == .success, let created else { return }

        observer = created
        finderPID = pid
        let app = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(created, app, kAXWindowCreatedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    private func teardown() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        watchedWindow = nil
        finderPID = 0
    }

    // MARK: - 新窗口

    fileprivate func windowCreated(_ window: AXUIElement, retriesLeft: Int = 2) {
        guard Store.shared.settings.rememberFinderWindowSize else { return }
        // 窗口刚建好时 AX 树还没长齐，工具栏可能还没挂上去，退避重试几次。
        guard isBrowserWindow(window) else {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.windowCreated(window, retriesLeft: retriesLeft - 1)
            }
            return
        }

        watchResize(of: window)

        guard let target = Store.shared.settings.finderWindowSize,
              let current = AX.size(window),
              Self.isSystemDefault(current),
              abs(current.width - target.width) > 2 || abs(current.height - target.height) > 2
        else { return }

        suppressUntil = CFAbsoluteTimeGetCurrent() + 1.0
        // 和文件面板同样的 size → position → size：中间那次改位置是为了避开
        // macOS 把窗口夹回当前屏幕的逻辑，不然第一次 setSize 可能被夹小。
        AX.setSize(window, target)
        if let pos = AX.position(window) { AX.setPosition(window, pos) }
        AX.setSize(window, target)
    }

    /// Finder 进程里不只有浏览窗口——「简介」、拷贝进度这些也是它的窗口。
    /// 浏览窗口有工具栏，那几个没有；只读一层直接子节点，开销恒定。
    private func isBrowserWindow(_ window: AXUIElement) -> Bool {
        guard AX.string(window, AXAttr.role) == kAXWindowRole else { return false }
        return AX.elements(window, AXAttr.children)
            .contains { AX.string($0, AXAttr.role) == kAXToolbarRole }
    }

    private static func isSystemDefault(_ size: CGSize) -> Bool {
        abs(size.width - systemDefault.width) <= tolerance
            && abs(size.height - systemDefault.height) <= tolerance
    }

    // MARK: - 记住尺寸

    /// 绑定/激活时补一次，覆盖 QuickBar 启动之前就开着的窗口。
    private func watchFrontWindow() {
        guard finderPID != 0 else { return }
        let app = AXUIElementCreateApplication(finderPID)
        guard let front = AX.element(app, AXAttr.focusedWindow), isBrowserWindow(front) else { return }
        watchResize(of: front)
    }

    /// 同一时刻只盯一个窗口，开销恒定；语义是「你最后手动拉过的那个尺寸」。
    private func watchResize(of window: AXUIElement) {
        guard let observer else { return }
        if let old = watchedWindow {
            AXObserverRemoveNotification(observer, old, kAXResizedNotification as CFString)
        }
        watchedWindow = window
        AXObserverAddNotification(observer, window, kAXResizedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func windowResized() {
        guard Store.shared.settings.rememberFinderWindowSize,
              CFAbsoluteTimeGetCurrent() > suppressUntil else { return }
        // 拖动时会连发一串 resize，落一次盘就够了。
        resizeDebounce?.invalidate()
        resizeDebounce = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.rememberCurrentSize()
        }
    }

    private func rememberCurrentSize() {
        guard let window = watchedWindow,
              let size = AX.size(window),
              size.width > 400, size.height > 300,
              !Self.isSystemDefault(size)
        else { return }
        Store.shared.settings.finderWindowSize = size
    }
}

private func finderObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<FinderWindowService>.fromOpaque(refcon).takeUnretainedValue()
    if (notification as String) == kAXResizedNotification {
        service.windowResized()
    } else {
        // 窗口刚建好时 AX 树还没稳定，等一拍再读。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { service.windowCreated(element) }
    }
}
