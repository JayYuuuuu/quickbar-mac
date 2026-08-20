import AppKit
import ApplicationServices

/// 文件面板的种类。原始值就是系统给面板窗口的 `AXIdentifier`。
enum PanelKind: String {
    case open = "open-panel"
    case save = "save-panel"
}

struct DetectedPanel {
    let element: AXUIElement
    let kind: PanelKind
    /// Chrome 这类把面板做成 sheet 挂在自己窗口上的，AX 改不动尺寸。
    let isSheet: Bool
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String?
}

/// 文件面板的判定、跳转和尺寸记忆。
///
/// 判定规则是实测出来的：不管宿主 app 是否沙盒（沙盒的面板其实由
/// `com.apple.appkit.xpc.openAndSavePanelService` 画），面板都会以
/// `AXIdentifier = open-panel / save-panel` 出现在「当前聚焦 app 的
/// AXFocusedWindow」上。所以判定只要三次属性读取，实测 0.5ms 量级，
/// 可以安全地放在事件 tap 回调里跑。
///
/// 反过来说有两件事千万别做：
/// 1. 别去数 `openAndSavePanelService` 进程——它有多个实例常驻，面板关了进程也不退；
/// 2. 别在 tap 回调里遍历 AX 子树——一次几千个节点，会被系统直接判定超时禁用整个 tap。
final class PanelService {
    static let shared = PanelService()

    private var appObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var watchedPanel: AXUIElement?
    private var resizeDebounce: Timer?

    private init() {}

    // MARK: - 判定

    /// 当前聚焦的是不是文件面板。快到可以在事件回调里调用。
    func currentPanel() -> DetectedPanel? {
        guard let app = AX.element(AX.systemWide, AXAttr.focusedApplication),
              let window = AX.element(app, AXAttr.focusedWindow),
              let identifier = AX.string(window, AXAttr.identifier),
              let kind = PanelKind(rawValue: identifier)
        else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let running = NSRunningApplication(processIdentifier: pid)

        return DetectedPanel(
            element: window,
            kind: kind,
            isSheet: AX.string(window, AXAttr.role) == kAXSheetRole,
            ownerPID: pid,
            ownerBundleID: running?.bundleIdentifier,
            ownerName: running?.localizedName
        )
    }

    // MARK: - 跳转

    /// 把当前文件面板切到指定目录。
    ///
    /// 走系统自带的「前往文件夹」（⌘⇧G）。优先用 AX 直接写输入框——
    /// 不碰剪贴板，也绕开「前往文件夹」的自动补全；写不进去才退回粘贴。
    func jump(to path: String) {
        guard currentPanel() != nil else { return }
        let expanded = (path as NSString).expandingTildeInPath

        Keyboard.post(keyCode: Keyboard.g, flags: [.maskCommand, .maskShift])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if self.fillGoToField(with: expanded) {
                Keyboard.post(keyCode: Keyboard.enter, flags: [])
            } else {
                self.pasteFallback(expanded)
            }
        }
    }

    /// ⌘⇧G 之后，焦点就落在「前往文件夹」的输入框上——直接读系统级焦点即可，
    /// 不用去子树里找。
    private func fillGoToField(with path: String) -> Bool {
        guard let focused = AX.element(AX.systemWide, AXAttr.focusedUIElement) else { return false }
        let role = AX.string(focused, AXAttr.role)
        guard role == kAXTextFieldRole || role == kAXComboBoxRole else { return false }
        return AX.setString(focused, AXAttr.value, path)
    }

    /// 兜底：借剪贴板粘贴，用完立刻还回去。
    private func pasteFallback(_ path: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(path, forType: .string)

        Keyboard.post(keyCode: Keyboard.v, flags: [.maskCommand])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Keyboard.post(keyCode: Keyboard.enter, flags: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let saved {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
    }

    // MARK: - 尺寸记忆

    /// 开始盯着前台应用，面板一出现就套用记住的尺寸。
    func startWatchingPanelSize() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(pid: app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            observe(pid: front.processIdentifier)
        }
    }

    /// 同一时刻只盯一个 app——前台切换就换人，开销恒定。
    private func observe(pid: pid_t) {
        guard pid != observedPID else { return }
        teardownObserver()
        observedPID = pid

        var observer: AXObserver?
        guard AXObserverCreate(pid, panelObserverCallback, &observer) == .success, let observer else { return }
        appObserver = observer

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        // 观察器装好之前面板可能已经开着了，补一次。
        DispatchQueue.main.async { [weak self] in self?.handlePossiblePanel() }
    }

    private func teardownObserver() {
        if let observer = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        appObserver = nil
        watchedPanel = nil
        observedPID = 0
    }

    fileprivate func handlePossiblePanel() {
        guard Store.shared.settings.rememberPanelSize, let panel = currentPanel() else { return }
        applyStoredSize(to: panel)
        watchResize(of: panel)
    }

    private func watchResize(of panel: DetectedPanel) {
        guard let observer = appObserver else { return }
        if let old = watchedPanel {
            AXObserverRemoveNotification(observer, old, kAXResizedNotification as CFString)
        }
        watchedPanel = panel.element
        AXObserverAddNotification(observer, panel.element, kAXResizedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func panelResized() {
        // 用户拖动时会连发一串 resize，落一次盘就够了。
        resizeDebounce?.invalidate()
        resizeDebounce = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.rememberCurrentSize()
        }
    }

    /// 把当前面板尺寸记下来。
    func rememberCurrentSize() {
        guard Store.shared.settings.rememberPanelSize,
              let panel = currentPanel(),
              let size = AX.size(panel.element),
              size.width > 200, size.height > 200
        else { return }

        Store.shared.settings.panelSize = size
        // 顺手写进宿主 app 自己的偏好，这样即使 QuickBar 没运行，系统也会用这个尺寸。
        if let bundleID = panel.ownerBundleID {
            writeNavPanelSize(size, bundleID: bundleID, kind: panel.kind)
        }
    }

    /// 把记住的尺寸套到刚出现的面板上。
    private func applyStoredSize(to panel: DetectedPanel) {
        guard let target = Store.shared.settings.panelSize else { return }
        guard let current = AX.size(panel.element) else { return }
        guard abs(current.width - target.width) > 2 || abs(current.height - target.height) > 2 else { return }

        if panel.isSheet {
            // sheet 型面板 AX 改不动（isAttributeSettable 会撒谎说 true，实际静默失败），
            // 只能写进宿主 app 的偏好，下次打开生效。
            if let bundleID = panel.ownerBundleID {
                writeNavPanelSize(target, bundleID: bundleID, kind: panel.kind)
            }
            return
        }

        // 普通窗口型面板：size → position → size。
        // 中间那次改位置是必要的——macOS 会把窗口夹回当前屏幕，
        // 不重设位置的话第一次 setSize 可能被夹小。
        AX.setSize(panel.element, target)
        if let pos = AX.position(panel.element) { AX.setPosition(panel.element, pos) }
        AX.setSize(panel.element, target)
    }

    /// 系统自己就用这两个 key 记面板尺寸，写它比我们硬改窗口更稳。
    private func writeNavPanelSize(_ size: CGSize, bundleID: String, kind: PanelKind) {
        let key = kind == .open ? "NSNavPanelExpandedSizeForOpenMode" : "NSNavPanelExpandedSizeForSaveMode"
        let value = "{\(Int(size.width)), \(Int(size.height))}"
        CFPreferencesSetAppValue(key as CFString, value as CFString, bundleID as CFString)
        if kind == .save {
            CFPreferencesSetAppValue("NSNavPanelExpandedStateForSaveMode" as CFString,
                                     kCFBooleanTrue, bundleID as CFString)
        }
        CFPreferencesAppSynchronize(bundleID as CFString)
    }
}

private func panelObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<PanelService>.fromOpaque(refcon).takeUnretainedValue()
    if (notification as String) == kAXResizedNotification {
        service.panelResized()
    } else {
        // 窗口刚建好时 AX 树还没稳定，等一拍再读。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { service.handlePossiblePanel() }
    }
}
