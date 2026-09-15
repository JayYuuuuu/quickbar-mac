import AppKit

/// 编译好的 AppleScript，按「当前线程 + 目标应用那个进程 + 源码」留着重复用。
///
/// 【为什么】2026-09-15 顾婉娜那台 QuickBar 崩在苹果的 AppleScript **编译器**里
/// （`ASCompile → TASParser::Parse → TASLexer::UseEvent` 访问坏地址），那一刻主线程也在
/// AppleScript 里（正在释放一个访达脚本）。以前每问一次 PS、每查一次访达都现编一遍、用完就扔；
/// 现在每条脚本在每条线程上只编一次。编译次数少了几个数量级，撞上的机会跟着少 ——
/// **这是推断**：崩溃没能复现（mac24g 上 PS 启动期间连编 356 次没崩），没法直接验证。
///
/// 🔴 **按线程分开存**（`Thread.threadDictionary`）：同一个 `NSAppleScript` 绝不跨线程用。
/// 🔴 **目标应用换了进程就重编**：PS / 访达退了重开之后，旧的那份还能不能接着用没验证过，重编最稳。
/// 🔴 **编译失败不缓存**，原样交回去 —— `executeAndReturnError` 会再编一次、把错误带出来。
/// 🔴 脚本里的顶层变量会留在编译好的对象里跨次保留，所以**每个变量都要先 `set` 再用**
///    （现有几条都是这么写的；加新脚本时别读一个上一次才赋过值的变量）。
enum CompiledScript {

    static func get(_ source: String, target bundleID: String) -> NSAppleScript? {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.processIdentifier ?? -1
        let store = Thread.current.threadDictionary
        let pidKey = "quickbar.script.pid.\(bundleID)"
        let prefix = "quickbar.script.\(bundleID)|"
        if (store[pidKey] as? Int32) != pid {
            for case let key as String in store.allKeys where key.hasPrefix(prefix) {
                store.removeObject(forKey: key)
            }
            store[pidKey] = pid
        }
        let key = prefix + source
        if let hit = store[key] as? NSAppleScript { return hit }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        if script.compileAndReturnError(&error) { store[key] = script }
        return script
    }
}
