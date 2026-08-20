import AppKit

// 同一时间只允许一个实例：静默更新重启时会短暂重叠，直接让旧的那个赢。
let bundleID = Bundle.main.bundleIdentifier ?? "com.yujiev.quickbar"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !others.isEmpty {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
