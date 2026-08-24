import AppKit

/// 跟 Photoshop 说话：**把改完的这张按原路径覆盖存回去，然后关掉**。
///
/// 【它解决的是哪件事】去水印的流程是「一批主图一起丢进 PS → 一张张修 → 存回原文件」
/// （见 MainImages）。修图只花几秒，磨人的全在存：动过生成式填充 / 内容识别之后图层不止一个，
/// ⌘S 就变成「存储为」，对话框落在上次那个目录，每张都要重新翻回
/// `/Volumes/…/<批次>/<商品>/主图/`；一次开了几十张之后，人根本认不出手上这张是哪件商品的。
///
/// 🔴 **「存哪个文件夹」不该由人回答** —— PS 自己就知道每个文档是从哪个文件打开的
///    （`document` 的 `file path`）。所以这里不做「帮你把存储对话框跳到正确目录」，
///    而是把那个对话框整个拿掉：拼合 → 按原 alias 覆盖写回 → 关掉 → 下一张。
///
/// 【四条硬约束】
/// 🔴 **不在主线程上跟 PS 说话。** AE 是同步等待的，PS 只要弹着任何模态框（存储进度、
///    生成式填充、缺字体提示）就一直不回复。2026-08-24 实测：从终端问它「打开了几个文档」，
///    40 秒都没回来。放主线程上，那就是整个 QuickBar 卡死 40 秒。所以跑在一条自带 run loop
///    的专用线程上，主线程只收结果。
/// 🔴 **那条线程上 `NSAppleScript` 未必活着。** 在没有 run loop 的 `DispatchQueue` 上它会
///    **一声不响地返回空**（见 MainImagesPill 文件头那一轮）。这里用 `Thread` + `CFRunLoopRun()`，
///    照理不会；但**每次动作的第一发永远是只读探测**，真撞上「空且无错」就把后面所有调用
///    切回主线程 —— 只读的重来一次没有代价，写盘的不能赌。
/// 🔴 **PS 没在跑就一个 AE 都不发。** `tell application` 会把它启动起来：人只想按个键存图，
///    等来的却是 Photoshop 的开机画面。
/// 🔴 **只认 jpg 和 png。** 覆盖写回意味着原图没了，猜错格式的代价是一张烧进 JPEG 块的 PNG，
///    而人不会立刻发现。别的扩展名一律不碰，明说。
enum Photoshop {

    static let bundleID = MainImages.photoshopBundleID

    private enum Format {
        case jpeg, png

        /// 存回去那一句。`p` 是 `file path of d` 拿到的 alias —— **不拼路径字符串**：
        /// 素材盘是 SMB，服务端读到的目录名和访达呈现的可能差一次 Unicode 归一化，
        /// 拼出来的路径会指不到那个文件（这个坑在 URLScheme 里已经吃过一次）。
        var saveLine: String {
            switch self {
            case .jpeg:
                return "save d in p as JPEG with options {class:JPEG save options, quality:12, "
                     + "embed color profile:true} appending no extension without copying"
            case .png:
                return "save d in p as PNG with options {class:PNG save options, interlaced:false} "
                     + "appending no extension without copying"
            }
        }

        static func of(_ path: String) -> Format? {
            switch (path as NSString).pathExtension.lowercased() {
            case "jpg", "jpeg": return .jpeg
            case "png": return .png
            default: return nil
            }
        }
    }

    // MARK: - 还剩几张

    /// 这一趟丢进 PS 的图还剩几张没存回。药丸靠它决定出不出现、写几。
    ///
    /// 🔴 **不轮询 PS**：QuickBar 自己就知道刚丢进去几张，之后每存回一张，拿 PS 回的
    ///    真实 `count of documents` 校准一次。人手动关掉几张会让它偏大，下一次存回就纠正回来 ——
    ///    比每 1.5 秒往 PS 发一发 AE 划算得多（PS 正忙时那一发要等到它闲下来，见文件头）。
    private(set) static var remaining = 0
    private(set) static var busy = false

    /// 数字或忙闲变了。药丸拿它立刻重画，不用等下一次心跳。
    static var onStateChanged: (() -> Void)?

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// 刚往 PS 里丢了几张。`MainImages.openInPhotoshop` 打开成功之后叫一声。
    static func rememberOpened(_ count: Int) {
        setRemaining(remaining + count)
    }

    private static func setRemaining(_ n: Int) {
        let v = max(0, n)
        guard v != remaining else { return }
        remaining = v
        onStateChanged?()
    }

    private static func setBusy(_ v: Bool) {
        guard v != busy else { return }
        busy = v
        onStateChanged?()
    }

    // MARK: - 存回原位

    /// 把 PS 最前那张拼合、按原路径覆盖存回、关掉。快捷键和药丸都走这儿。
    static func saveBackFront() {
        guard start() else { return }
        Bridge.run(infoScript, readOnly: true) { text in
            guard let text else { setBusy(false); return }   // 出错的话 Bridge 已经说过了
            let lines = text.components(separatedBy: "\n")
            let count = Int(lines.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            let path = lines.count > 1 ? lines[1] : ""

            guard count > 0 else {
                setBusy(false)
                setRemaining(0)
                Notify.tell("Photoshop 里没有打开的图", "「存回原位」只处理 PS 当前那张。")
                return
            }
            guard !path.isEmpty else {
                setBusy(false)
                Notify.tell("这张没有原始路径", "它不是从文件打开的（比如是新建的文档），存回哪儿只能你自己定。")
                return
            }
            guard let format = Format.of(path) else {
                setBusy(false)
                let ext = (path as NSString).pathExtension
                Notify.tell("这张不敢替你覆盖", "覆盖存回只认 jpg 和 png，当前这张是「\(ext.isEmpty ? "没有扩展名" : ext)」。")
                return
            }
            Bridge.run(saveFrontScript(format)) { out in
                setBusy(false)
                guard let out else { return }
                report(out, path: path)
            }
        }
    }

    /// 把 PS 里所有认得的图一次全存回。菜单栏那一项。
    /// 循环在脚本里跑，不是几十个来回 —— PS 每回一次都要它闲下来。
    static func saveBackAll() {
        guard isRunning else {
            Notify.tell("Photoshop 没在跑", "先把主图丢进 PS，改完再来存回。")
            return
        }
        guard !busy else { return }
        guard Notify.confirm("把 PS 里打开的图全部存回原位？",
                             "每张都会先拼合图层，再按它自己的原路径覆盖写回，然后关掉。\n"
                             + "原图会被改完的这版替掉，这一步没有撤销。",
                             ok: "全部存回") else { return }
        setBusy(true)
        Bridge.run(saveAllScript) { out in
            setBusy(false)
            guard let out else { return }
            let lines = out.components(separatedBy: "\n")
            let num: (Int) -> Int = { Int(lines.count > $0 ? lines[$0].trimmingCharacters(in: .whitespaces) : "") ?? 0 }
            let done = num(0), skipped = num(1), failed = num(2)
            let lastErr = lines.count > 3 ? lines[3] : ""
            setRemaining(remaining - done)
            var body = "存回 \(done) 张。"
            if skipped > 0 { body += "跳过 \(skipped) 张（不是 jpg / png，没敢覆盖）。" }
            if failed > 0 { body += "失败 \(failed) 张：\(lastErr)" }
            Notify.tell(failed > 0 ? "有几张没存回去" : "全部存回原位", body)
        }
    }

    /// PS 当前这张在访达里。人问的第一句就是「能不能跳到对应的素材文件夹」——
    /// 存回原位之后其实用不着了，但偶尔要去翻同一件商品的别的图。
    static func revealFront() {
        guard isRunning else {
            Notify.tell("Photoshop 没在跑", "这一项是「把 PS 当前那张所在的文件夹打开」。")
            return
        }
        Bridge.run(infoScript, readOnly: true) { text in
            guard let text else { return }
            let lines = text.components(separatedBy: "\n")
            let path = lines.count > 1 ? lines[1] : ""
            guard !path.isEmpty else {
                Notify.tell("PS 当前这张没有原始路径", "它不是从文件打开的，访达里没有对应的位置。")
                return
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                // 绝不「点了没反应」：文件没了就退到还在的那一层，并说清楚。
                let dir = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: dir.path) {
                    Actions.openFolder(dir.path)
                    Notify.tell("那张图已经不在盘上了", "先开了它所在的文件夹：\(dir.lastPathComponent)")
                } else {
                    Notify.tell("找不到那张图了", path)
                }
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - 内部

    /// 动作开始前的统一闸门。
    private static func start() -> Bool {
        guard !busy else { return false }
        guard isRunning else {
            Notify.tell("Photoshop 没在跑", "「存回原位」是把 PS 当前那张按原路径覆盖存回。")
            return false
        }
        setBusy(true)
        return true
    }

    private static func report(_ out: String, path: String) {
        let lines = out.components(separatedBy: "\n")
        let name = (path as NSString).lastPathComponent
        guard lines.first == "OK" else {
            let msg = lines.count > 2 ? lines[2] : out
            Notify.tell("这张没能存回去", "\(name)：\(msg)\n原图没有被改动。")
            return
        }
        // PS 关掉这张之后自己数的，比我们递减准 —— 人中途手动关过几张也能校回来。
        setRemaining(Int(lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : "") ?? (remaining - 1))
        NSLog("[QuickBar] 存回 \(path)，PS 里还剩 \(remaining) 张")
    }

    // MARK: - 脚本

    /// 只读：打开了几个文档、最前那个的原始路径。每次动作的第一发都是它（见文件头第二条）。
    private static let infoScript = """
    tell application id "\(bundleID)"
        set n to (count of documents)
        if n is 0 then return "0"
        set p to ""
        try
            set p to POSIX path of (file path of current document)
        end try
        return (n as text) & linefeed & p
    end tell
    """

    /// `flatten` 对本来就只有一个背景图层的文档会报「当前不可用」，所以单独 try 起来。
    private static func saveFrontScript(_ format: Format) -> String {
        """
        tell application id "\(bundleID)"
            try
                set d to current document
                set p to file path of d
                try
                    flatten d
                end try
                \(format.saveLine)
                close d saving no
                return "OK" & linefeed & ((count of documents) as text)
            on error errMsg number errNum
                return "ERR" & linefeed & (errNum as text) & linefeed & errMsg
            end try
        end tell
        """
    }

    /// 🔴 **从最后一个往前数着走**：存完就关，关掉 `document i` 之后 1…i-1 的下标不动，
    ///    正着走会漏掉一半。跳过的那些（不是 jpg/png）留在 PS 里不关，所以也不能写成
    ///    `repeat while (count of documents) > 0` —— 那是个死循环。
    private static let saveAllScript = """
    tell application id "\(bundleID)"
        set doneN to 0
        set skipN to 0
        set failN to 0
        set lastErr to ""
        repeat with i from (count of documents) to 1 by -1
            try
                set d to document i
                set nm to name of d
                set p to file path of d
                if nm ends with ".png" or nm ends with ".PNG" then
                    try
                        flatten d
                    end try
                    \(Format.png.saveLine)
                    close d saving no
                    set doneN to doneN + 1
                else if nm ends with ".jpg" or nm ends with ".JPG" or nm ends with ".jpeg" or nm ends with ".JPEG" then
                    try
                        flatten d
                    end try
                    \(Format.jpeg.saveLine)
                    close d saving no
                    set doneN to doneN + 1
                else
                    set skipN to skipN + 1
                end if
            on error errMsg
                set failN to failN + 1
                set lastErr to errMsg
            end try
        end repeat
        return (doneN as text) & linefeed & (skipN as text) & linefeed & (failN as text) & linefeed & lastErr
    end tell
    """
}

// MARK: - 跟 PS 通话的那条线

extension Photoshop {

    /// `NSAppleScript` 的收发口。存在的理由只有一个：**PS 可能永远不回话**（见文件头第一条），
    /// 所以这一发不能占着主线程，也不能没有下文。
    enum Bridge {

        /// 超过这个还没回话就认定 PS 卡住了。存一张 20MB 的 JPEG 到 SMB 上撑死几秒，
        /// 20 秒只可能是它正压着一个模态框。
        private static let timeout: TimeInterval = 20

        /// 专用线程被判定为「跑不了 AppleScript」之后翻成 true，从此全走主线程。
        /// 只由只读探测翻（见文件头第二条）。
        private static var mainThreadOnly = false
        private static var thread: Thread?
        private static let runner = Runner()

        /// - Parameter readOnly: 这段脚本改不改东西。只有只读的才允许在「空且无错」时重来一次。
        static func run(_ source: String, readOnly: Bool = false, _ done: @escaping (String?) -> Void) {
            var settled = false
            let settle: (String?) -> Void = { text in
                guard !settled else { return }
                settled = true
                done(text)
            }
            // 绝不「按了没反应」：卡住了也要说一声，并把忙碌状态放回去。
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !settled else { return }
                settled = true
                // 🔴 **那条线程已经废了**：AE 是同步的，卡住的这一发会一直占着它，
                //    后面每一发都排在它后面（实测过：一发卡住，之后的全不执行）。
                //    所以把它丢掉换一条新的 —— 不然一次卡死之后这个功能到重启为止都是哑的。
                //    旧线程等 PS 回话之后会自己空转下去，`settled` 已经是 true，结果会被丢弃。
                thread = nil
                Notify.tell("Photoshop 一直没回话",
                            "它多半正压着一个对话框（存储进度、生成式填充、缺字体提示…），"
                            + "也可能是第一次用、屏幕上正等你点「允许」。\n处理掉那个框再按一次。")
                done(nil)
            }

            let box = ScriptBox(source: source, readOnly: readOnly, done: settle)
            if mainThreadOnly {
                DispatchQueue.main.async { execOnMain(box) }
            } else {
                runner.perform(#selector(Runner.exec(_:)), on: ensureThread(), with: box, waitUntilDone: false)
            }
        }

        /// 一条自带 run loop 的常驻线程。**run loop 是关键**：没有它 `NSAppleScript`
        /// 就是文件头第二条说的那个「一声不响返回空」。空 run loop 会立刻退出，所以挂一个 port 占着。
        private static func ensureThread() -> Thread {
            if let t = thread, !t.isFinished { return t }
            let t = Thread {
                let loop = RunLoop.current
                loop.add(NSMachPort(), forMode: .default)
                while !Thread.current.isCancelled {
                    loop.run(mode: .default, before: .distantFuture)
                }
            }
            t.name = "com.yujiev.quickbar.photoshop"
            t.qualityOfService = .userInitiated
            t.start()
            thread = t
            return t
        }

        fileprivate static func execOnMain(_ box: ScriptBox) {
            var err: NSDictionary?
            let text = NSAppleScript(source: box.source)?.executeAndReturnError(&err).stringValue
            interpret(text: text, error: err, box: box, fromBackground: false)
        }

        fileprivate static func interpret(text: String?, error: NSDictionary?,
                                          box: ScriptBox, fromBackground: Bool) {
            if let error {
                explain(error)
                box.done(nil)
                return
            }
            if let text, !text.isEmpty {
                box.done(text)
                return
            }
            // 「空、而且没有报错」正是那个静默失败的签名。只读的才敢重来。
            if fromBackground, box.readOnly, !mainThreadOnly {
                mainThreadOnly = true
                NSLog("[QuickBar] AppleScript 在专用线程上返回空，之后改走主线程")
                execOnMain(box)
                return
            }
            box.done(text)
        }

        private static func explain(_ error: NSDictionary) {
            let num = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? ""
            NSLog("[QuickBar] Photoshop AppleScript 失败 \(num)：\(msg)")
            switch num {
            case -1743:
                Notify.tell("QuickBar 还不能控制 Photoshop",
                            "去「系统设置 → 隐私与安全性 → 自动化」，把 QuickBar 底下的 Photoshop 打开。")
                NSWorkspace.shared.open(Permissions.Kind.automation.settingsURL)
            case -600, -609:
                Notify.tell("Photoshop 没在跑", "先把主图丢进 PS，改完再来存回。")
            case -1712:
                Notify.tell("Photoshop 没回话", "它多半正压着一个对话框。处理掉那个框再按一次。")
            default:
                Notify.tell("跟 Photoshop 说话失败", msg.isEmpty ? "错误 \(num)" : "\(msg)（错误 \(num)）")
            }
        }
    }

    /// 一次调用的全部行李。`perform(_:on:with:)` 只能捎一个对象过去。
    fileprivate final class ScriptBox: NSObject {
        let source: String
        let readOnly: Bool
        let done: (String?) -> Void

        init(source: String, readOnly: Bool, done: @escaping (String?) -> Void) {
            self.source = source
            self.readOnly = readOnly
            self.done = done
        }
    }

    /// 只为了给 `perform(_:on:with:)` 一个 `NSObject` 靶子。真正的活在那条专用线程上跑，
    /// 结果一律回主线程解释 —— `Notify` 和药丸都只认主线程。
    fileprivate final class Runner: NSObject {
        @objc func exec(_ box: ScriptBox) {
            var err: NSDictionary?
            let text = NSAppleScript(source: box.source)?.executeAndReturnError(&err).stringValue
            DispatchQueue.main.async {
                Bridge.interpret(text: text, error: err, box: box, fromBackground: true)
            }
        }
    }
}
