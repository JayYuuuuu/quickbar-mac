import AppKit

/// 全局键鼠监听。
///
/// 两条硬约束，都是踩出来的：
///
/// 1. **回调必须快。** 事件 tap 的回调有时间预算，超了系统会直接发
///    `tapDisabledByTimeout` 把整个 tap 关掉——表现是快捷键毫无征兆地全部失灵。
///    所以回调里只做常数级的判断（面板判定就三次 AX 读取），
///    真正的动作一律 `DispatchQueue.main.async` 扔出去。
/// 2. **tap 跑在自己的线程上。** 挂主线程的话，设置窗一渲染就可能把回调拖超时。
final class EventTapService {
    static let shared = EventTapService()

    /// 唤出快捷条。参数是鼠标当时的位置（全局坐标）。
    var onTrigger: ((CGPoint) -> Void)?
    /// 在文件面板里按了跳转键。
    var onJumpToFinder: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var watchdog: Timer?

    /// 吞掉了触发用的那次 mouseDown，配对的 mouseUp 也得一起吞，
    /// 否则有些应用会收到孤零零的 up 而状态错乱。
    private var swallowNextMouseUp = false

    /// 双击 ⌘ 的状态。
    private var lastCommandRelease: CFAbsoluteTime = 0
    private var commandWasAlone = false

    private init() {}

    var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "com.yujiev.quickbar.eventtap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        // 兜底：万一还是被系统禁用了，5 秒内自动救回来。
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        watchdog?.invalidate()
        watchdog = nil
    }

    private func threadMain() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    // MARK: - 事件处理（跑在 tap 线程上，务必保持轻量）

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统把 tap 关了，立刻开回来。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 自家合成的事件直接放行，避免自己触发自己。
        if Keyboard.isOurs(event) { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .leftMouseDown:
            if handleMouseDown(event) {
                swallowNextMouseUp = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseUp:
            if swallowNextMouseUp {
                swallowNextMouseUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// 跳转键（默认 ⌘G）。只在确实是文件面板时才吞掉——
    /// 其他场合 ⌘G 仍然是各 app 自己的「查找下一个」。
    ///
    /// 「存回原位」（默认 ⌃⌘S）同理：**只在 Photoshop 在最前时才拦**。
    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let settings = Store.shared.settings
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(TriggerModifier.allFlags)

        // 去水印的收尾：拼合 → 按原路径覆盖存回 → 关掉这张（见 Core/Photoshop.swift）。
        if settings.psSaveBackEnabled,
           keyCode == CGKeyCode(settings.psSaveBackKeyCode),
           flags == CGEventFlags(rawValue: UInt64(settings.psSaveBackModifierFlags))
               .intersection(TriggerModifier.allFlags),
           Photoshop.isFrontmost {
            DispatchQueue.main.async { Photoshop.saveBackFront() }
            return nil
        }

        guard keyCode == settings.jumpKeyCode else { return Unmanaged.passUnretained(event) }

        let wanted = CGEventFlags(rawValue: UInt64(settings.jumpModifierFlags))
        guard flags == wanted.intersection(TriggerModifier.allFlags) else {
            return Unmanaged.passUnretained(event)
        }
        guard PanelService.shared.currentPanel() != nil else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in self?.onJumpToFinder?() }
        return nil   // 吞掉
    }

    /// 返回值：要不要吞掉这次点击。
    ///
    /// 带修饰键的手势必须吞——放行的话鼠标底下那个应用会被激活抢走 key window，
    /// 快捷条刚弹出来就被自己的 resignKey 收掉了。
    /// 裸双击模式不能吞，否则选词、打开文件全废。
    private func handleMouseDown(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.mouseEventClickState) == 2 else { return false }
        let settings = Store.shared.settings
        let flags = event.flags.intersection(TriggerModifier.allFlags)
        let location = event.location
        var swallow = true

        switch settings.trigger {
        case .modifierDoubleClick:
            guard flags == settings.modifier.flag.intersection(TriggerModifier.allFlags) else { return false }
        case .desktopDoubleClick:
            guard flags.isEmpty, ScreenProbe.isDesktop(at: location) else { return false }
        case .bareDoubleClick:
            guard flags.isEmpty, !isFrontmostExcluded(settings) else { return false }
            swallow = false
        case .doubleCommand:
            return false
        }

        DispatchQueue.main.async { [weak self] in self?.onTrigger?(location) }
        return swallow
    }

    /// 连按两下 ⌘：两次「按下又松开且期间没按别的键」的间隔小于 400ms。
    private func handleFlagsChanged(_ event: CGEvent) {
        guard Store.shared.settings.trigger == .doubleCommand else { return }
        let hasCommand = event.flags.contains(.maskCommand)
        let others = event.flags.intersection([.maskAlternate, .maskControl, .maskShift])

        if hasCommand && others.isEmpty {
            commandWasAlone = true
            return
        }
        guard !hasCommand, commandWasAlone else {
            commandWasAlone = false
            return
        }
        commandWasAlone = false

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastCommandRelease < 0.4 {
            lastCommandRelease = 0
            let location = event.location
            DispatchQueue.main.async { [weak self] in self?.onTrigger?(location) }
        } else {
            lastCommandRelease = now
        }
    }

    private func isFrontmostExcluded(_ settings: Settings) -> Bool {
        guard !settings.excludedBundleIDs.isEmpty,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return false }
        return settings.excludedBundleIDs.contains(bundleID)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<EventTapService>.fromOpaque(refcon).takeUnretainedValue()
    return service.handle(type: type, event: event)
}

/// 判断某个屏幕坐标下面是不是桌面（没有任何普通窗口盖着）。
enum ScreenProbe {
    static func isDesktop(at point: CGPoint) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            // layer 0 才是普通应用窗口；菜单栏、Dock、悬浮面板都在更高层。
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if rect.contains(point) { return false }
        }
        return true
    }
}
