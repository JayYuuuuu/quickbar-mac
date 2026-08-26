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

    /// 存回去的 JPEG 画质（Photoshop 的 0–12 档，不是 libjpeg 的 0–100）。
    ///
    /// 🔴 **别用 12。** 12 是面板上的「最佳」，但存回的是一张**本来就压过**的图：
    ///    2026-08-24 拿真素材（1440×1920）在真 PS 上量过一轮 ——
    ///
    ///    | 档 | 体积 | 相对原图 | 抽样 | 亮度量化均值 |
    ///    |---|---|---|---|---|
    ///    | 原始下载图 | 732,600 | — | 4:4:4 | 12.7 |
    ///    | q6 | 353,063 | 48% | **4:2:0** | 13.8 |
    ///    | q8 | 521,789 | 71% | 4:4:4 | 12.4 |
    ///    | **q9** | **684,460** | **93%** | 4:4:4 | 10.4 |
    ///    | q12 | 1,476,300 | **202%** | 4:4:4 | 1.7 |
    ///
    ///    q12 把体积翻一倍，多出来的精度大半花在**保留原图自己的压缩痕迹**上；
    ///    而这些图传上淘宝还要被平台再压一次，等于白花。
    /// 🔴 **也别往 6 以下降**：PS 在 7 档以下切到 **4:2:0**，色度分辨率减半 ——
    ///    电商图上的布料花色和文字会明显发虚，这是个断崖，不是渐变。
    /// 选 9：量化精度比原图略细一点（10.4 vs 12.7），去水印重编码那一道损耗有余量兜着，
    /// 体积又跟原图基本持平（用户 2026-08-24 定）。
    ///
    /// 【这条路等于 PS 的哪个菜单】等于**「文件 → 存储为 / 存储副本」→ JPEG**，逐项对应
    /// 那个「JPEG 选项」对话框。**不等于「导出为」/「存储为 Web 所用格式」**：那是另一套引擎，
    /// 画质刻度 0–100 不是 0–12（实测 q80 反而比这儿的 q9 更细、文件更大），而且会把
    /// EXIF/XMP/ICC 几乎剥光。这条路会带上约 18.7 KB 元数据（PS 自己写的 EXIF、
    /// Photoshop 资源块、XMP、sRGB 的 ICC）—— 是「存储为」的固有行为，不是我们加的。
    private static let JPEG_QUALITY = 9

    private enum Format {
        case jpeg, png

        /// 存回去那一句。`dest` 由 `my toFile(file path of d)` 得来（见 `TO_FILE`）。
        ///
        /// 🔴 **目标必须是 file specification，不能是 alias。** `file path of d` 给的是 alias，
        ///    直接 `save d in <alias>` 会报 **8800「发生了常规 Photoshop 错误」** —— 一句有用的话都没有。
        ///    2026-08-24 在真 PS 上逐个参数试过：`POSIX file` 当目标，带不带 `embed color profile`、
        ///    带不带 `appending` 全部成功；换成 alias 就必失败。`save` 的形参写着 file specification，
        ///    PS 是真的只吃这一种。
        /// 🔴 **路径不是我们拼的**：字符串从 PS 自己那儿来（`POSIX path of` 它给的 alias），
        ///    转换全交给 AppleScript 自己的强制转换，原样递回去。素材盘是 SMB，
        ///    自己拼路径会撞上 Unicode 归一化（URLScheme 那节吃过一次）。
        var saveLine: String {
            switch self {
            case .jpeg:
                // `format options:optimized` = 对话框里的「基线已优化」：优化哈夫曼表，
                // 量化表一个字节不变（画质零损失），实测同一张图 684,409 → 670,051（省 2.1%）。
                // 仍是标准基线 JPEG，浏览器和淘宝都吃。不写这一项的话 PS 默认走 standard。
                return "save d in dest as JPEG with options {class:JPEG save options, quality:\(JPEG_QUALITY), "
                     + "embed color profile:true, format options:optimized} appending no extension without copying"
            case .png:
                return "save d in dest as PNG with options {class:PNG save options, interlaced:false} "
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

    /// PS 里现在有几张**能存回**的图（有原始路径、jpg/png）。药丸靠它决定出不出现、写几。
    ///
    /// 🔴 **只记账是不够的**（2026-08-26 修）：账只在「经药丸丢进去」和「存回一张之后」变，
    ///    人自己在 PS 里开图（历史记录 / 双击 / 拖进去）或关图，QuickBar 一概不知道。
    ///    表现就是**看起来很随机**：手动开的图药丸不出现，手动关掉的图药丸还在数它 ——
    ///    用户实测拍到过「PS 里只开着 1 张，药丸写着还剩 2 张」，日志里那个数从上一次存回
    ///    之后 19 分钟纹丝不动。药丸出不出现取决于「这张图是怎么进 PS 的」，而人根本不会去想这件事。
    /// 🔴 **但也不能放进心跳**：AE 是同步的，PS 压着模态框时那一发要等到它闲下来
    ///    （实测 40 秒以上），而且会把人随后按的 F15 堵在同一条专用线程后面。
    ///    所以校准是**按需的**：PS 刚到最前时一次 + 在 PS 里时低频兜底一次，
    ///    3 秒超时、超时静默放弃（见 `syncRemaining`）。
    private(set) static var remaining = 0
    /// 这一趟总共丢进去几张。药丸底边那条进度线要它（设计稿：`已存回 done / total`）。
    /// 归零时一起清掉 —— 下一趟是新的一批，进度不该从上一批接着算。
    private(set) static var total = 0
    private(set) static var busy = false

    /// 上一次 `remaining` 归零，是**存回造成的**，还是别的（人自己把图关了 / 校准发现图没了）。
    ///
    /// 🔴 药丸那句绿色的「都存回了」只在前者说。v1.18.0 加了向 PS 校准之后立刻撞上这个：
    ///    人只是打开一张图、又手动关掉，什么都没存，药丸却先挂着不走、然后弹一句「都存回了」
    ///    （2026-08-26 用户反馈）。**那是假的成功反馈** —— 告诉人事情办成了，而事情根本没发生过。
    ///    在只记账的年代这个推断是成立的（归零只可能因为存回），现在不成立了。
    private(set) static var zeroBySave = false

    /// 已经存回几张。
    static var done: Int { max(0, total - remaining) }
    /// 进度（0…1）。没丢过图就是 0，药丸那条线也就不画。
    static var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

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
        total += count
        setRemaining(remaining + count)
    }

    /// 问一次 PS「你现在开着几张能存回的图」，用真实答案覆盖记的账。
    ///
    /// 🔴 **数的是「能存回的」，不是 `count of documents`**：psd / tif / 新建没存过的
    ///    都不该算进药丸那个数 —— 它写着「还剩 N 张」，人按 N 下期望清空，多出来的那几张
    ///    每按一次都会弹一句「这张不敢替你覆盖」，等于把错误的承诺兑现成一串报错。
    /// 🔴 **正在存回时不问**：那一发会排在存回后面，而且存回自己会校准。
    /// 🔴 **静默**：没人在等这一发，超时就当没问过（`quiet: true`），绝不弹框。
    static func syncRemaining() {
        guard isRunning, !busy, !syncing else { return }
        syncing = true
        Bridge.run(countScript, readOnly: true, timeout: Bridge.quietTimeout, quiet: true) { text in
            syncing = false
            // 🔴 **存回开跑了就把这一发的结果丢掉**。发出去的时候还没在存，回来时已经在存了 ——
            //    这一发拿到的是**存回之前**的快照，用它去覆盖只会把刚减掉的数又抬回来。
            //    账在存回期间归存回自己管（`report` 拿 PS 关掉文档之后的真实数）。
            guard !busy else { return }
            guard let n = Int((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            // 手动开的图没有「这一批总共几张」可言，进度线得有个分母才画得出来。
            if n > total { total = n }
            // 校准出来的归零 = 图是被人关掉的 / 本来就没了，不是存回来的。
            // 🔴 **必须带上 `remaining > 0` 这一半**：存回刚把数减到 0，紧跟着一发迟到的校准
            //    也会回 0 —— 不加这条它就把 `zeroBySave` 抹成 false，真存回完反而不说
            //    「都存回了」了（2026-08-26 实测撞到过：日志里只有「存回中…」，没有那句绿的）。
            //    只有**真的从有变没**才算「图是被关掉的」。
            if n == 0, remaining > 0 { zeroBySave = false }
            setRemaining(n)
        }
    }

    private static var syncing = false

    private static func setRemaining(_ n: Int) {
        let v = max(0, n)
        guard v != remaining else { return }
        remaining = v
        if v == 0 { total = 0 }
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
            let info = Info(text)

            guard info.count > 0 else {
                setBusy(false)
                zeroBySave = false
                setRemaining(0)
                Notify.problem("Photoshop 里没有打开的图", "「存回原位」只处理 PS 当前那张。")
                return
            }
            guard info.hasPath else {
                setBusy(false)
                Notify.problem("这张没有原始路径",
                               "「\(info.name.isEmpty ? "当前文档" : info.name)」不是从文件打开的"
                               + "（比如是新建的、或者已经被你另存成别的了），存回哪儿只能你自己定。"
                               + (info.why.isEmpty ? "" : "\n\nPhotoshop 说：\(info.why)"))
                return
            }
            // 🔴 认扩展名用**文档名**，不用 POSIX 串：POSIX 那一步可能失败（见 infoScript），
            //    但只要 `file path` 在，存回去就是能成的，不该被一个显示用的字段挡住。
            guard let format = Format.of(info.name) else {
                setBusy(false)
                let ext = (info.name as NSString).pathExtension
                Notify.problem("这张不敢替你覆盖",
                               "覆盖存回只认 jpg 和 png，「\(info.name)」是「\(ext.isEmpty ? "没有扩展名" : ext)」。")
                return
            }
            Bridge.run(saveFrontScript(format)) { out in
                guard let out else { setBusy(false); return }
                // 🔴 **先更账，再解除忙碌**。反过来的话药丸会在「存回中…」和「都存回了」之间
                //    闪回一格「存回原位 · 还剩 1 张」—— `setBusy(false)` 那一跳数字还没减呢
                //    （2026-08-26 从日志里逮到：三行文字挤在同一秒）。
                report(out, name: info.name, path: info.path)
                setBusy(false)
            }
        }
    }

    /// 把 PS 里所有认得的图一次全存回。菜单栏那一项。
    /// 循环在脚本里跑，不是几十个来回 —— PS 每回一次都要它闲下来。
    static func saveBackAll() {
        guard isRunning else {
            Notify.problem("Photoshop 没在跑", "先把主图丢进 PS，改完再来存回。")
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
            zeroBySave = true
            setRemaining(remaining - done)
            var body = "存回 \(done) 张。"
            if skipped > 0 { body += "跳过 \(skipped) 张（不是 jpg / png，没敢覆盖）。" }
            if failed > 0 { body += "失败 \(failed) 张：\(lastErr)" }
            if failed > 0 { Notify.problem("有几张没存回去", body) } else { Notify.tell("全部存回原位", body) }
        }
    }

    /// PS 当前这张在访达里。人问的第一句就是「能不能跳到对应的素材文件夹」——
    /// 存回原位之后其实用不着了，但偶尔要去翻同一件商品的别的图。
    static func revealFront() {
        guard isRunning else {
            Notify.problem("Photoshop 没在跑", "这一项是「把 PS 当前那张所在的文件夹打开」。")
            return
        }
        Bridge.run(infoScript, readOnly: true) { text in
            guard let text else { return }
            let info = Info(text)
            let path = info.path
            guard !path.isEmpty else {
                Notify.problem("PS 当前这张在访达里找不到",
                               info.count == 0 ? "Photoshop 里没有打开的图。"
                                               : "它不是从文件打开的，访达里没有对应的位置。"
                                                 + (info.why.isEmpty ? "" : "\n\nPhotoshop 说：\(info.why)"))
                return
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                // 绝不「点了没反应」：文件没了就退到还在的那一层，并说清楚。
                let dir = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: dir.path) {
                    Actions.openFolder(dir.path)
                    Notify.problem("那张图已经不在盘上了", "先开了它所在的文件夹：\(dir.lastPathComponent)")
                } else {
                    Notify.problem("找不到那张图了", path)
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
            Notify.problem("Photoshop 没在跑", "「存回原位」是把 PS 当前那张按原路径覆盖存回。")
            return false
        }
        setBusy(true)
        return true
    }

    private static func report(_ out: String, name: String, path: String) {
        let lines = out.components(separatedBy: "\n")
        guard lines.first == "OK" else {
            let msg = lines.count > 2 ? lines[2] : out
            Notify.problem("这张没能存回去", "\(name)：\(msg)\n原图没有被改动。")
            return
        }
        // PS 关掉这张之后自己数的，比我们递减准 —— 人中途手动关过几张也能校回来。
        // 🔴 **在 `setRemaining` 之前设**：它会同步触发 `onStateChanged` → 药丸当场重画，
        //    晚一行设，药丸看到的就还是上一次的值。
        zeroBySave = true
        setRemaining(Int(lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : "") ?? (remaining - 1))
        Notify.log("存回 \(path.isEmpty ? name : path)，PS 里还剩 \(remaining) 张")
    }

    /// `infoScript` 回来的五行。
    private struct Info {
        let count: Int
        let name: String
        let hasPath: Bool
        let path: String
        let why: String

        init(_ text: String) {
            let l = text.components(separatedBy: "\n")
            func at(_ i: Int) -> String {
                i < l.count ? l[i].trimmingCharacters(in: .whitespaces) : ""
            }
            count = Int(at(0)) ?? 0
            name = at(1)
            hasPath = at(2) == "1"
            // 路径不 trim：文件名两头理论上可以有空格
            path = l.count > 3 ? l[3] : ""
            why = at(4)
        }
    }

    // MARK: - 脚本

    /// 把 PS 给的 alias 变成它自己肯收的 file specification。
    ///
    /// 🔴 **必须写成处理器**，不能在 `tell` 块里直接 `POSIX file (POSIX path of a)`：
    ///    `POSIX path` 在 PS 的 `tell` 块里会被它的 Path Suite 抢走（见 `infoScript`），
    ///    而处理器体是在**脚本自己的上下文**里求值的，`my toFile(...)` 就绕开了这个抢词。
    ///    （顺带：`POSIX file` 也不能在 `tell` 块里直接写，PS 会把它当成自己的对象去解，
    ///    报 -1728「不能获得 …of «script»」。放进处理器一起解决。）
    private static let TO_FILE = """
    on toFile(a)
        return POSIX file (POSIX path of a)
    end toFile
    """

    /// 数 PS 里有几张**能存回**的图：有 `file path`（是从文件打开的）且扩展名是 jpg / png。
    /// `syncRemaining` 用它把药丸那个数校准回真实情况。
    ///
    /// 🔴 **`file path` 对没存过的文档是报错，不是返回 missing value**，所以必须 `try` 包住。
    /// 🔴 **只读、不关文档，所以正着数就行** —— 跟 `saveAllScript` 那条倒着走的规矩不一样，
    ///    那条是因为存完就关、下标会塌。
    /// 🔴 **别在这儿用 `POSIX path`**：`path` 这个词在 PS 的 `tell` 块里被它的 Path Suite 抢走
    ///    （见 `infoScript`）。认扩展名用 `name of d` 就够了。
    private static let countScript = """
    set n to 0
    tell application id "\(bundleID)"
        repeat with i from 1 to (count of documents)
            set d to document i
            set ok to false
            try
                if (file path of d) is not missing value then set ok to true
            end try
            if ok then
                set nm to name of d
                if nm ends with ".jpg" or nm ends with ".JPG" or nm ends with ".jpeg" ¬
                    or nm ends with ".JPEG" or nm ends with ".png" or nm ends with ".PNG" then
                    set n to n + 1
                end if
            end if
        end repeat
    end tell
    return n as text
    """

    /// 只读探测：打开了几个文档、最前那个叫什么、有没有原始路径、路径是什么、失败的话为什么。
    /// 每次动作的第一发都是它（见文件头第二条）。
    ///
    /// 🔴 **`POSIX path of` 必须放在 `tell` 块外面求值**。第一版写在块里：
    ///    `set p to POSIX path of (file path of current document)` —— 从 Finder 丢进 PS 的图
    ///    也会走进「这张没有原始路径」（2026-08-24 实测）。`POSIX path` 是 StandardAdditions 的词，
    ///    在 `tell application` 块里会先被送给目标应用，Photoshop 不认就报错，被 `try` 吞掉，
    ///    结果看起来像「文档没有路径」。Adobe 自己的示例也是取出来再转。
    /// 🔴 **判「能不能存回」看的是 `file path` 拿没拿到，不是 POSIX 串**：
    ///    真正写盘用的是那个 alias（`save d in p`），POSIX 串只用来认扩展名和说人话。
    /// 🔴 **失败原因要带回来**（最后一行 `why`）。上一版这里只回一个空串，
    ///    于是「为什么空」在机器外面永远查不出来。
    private static let infoScript = """
    set n to 0
    set nm to ""
    set p to ""
    set why to ""
    set f to missing value
    tell application id "\(bundleID)"
        set n to (count of documents)
        if n > 0 then
            try
                set nm to name of current document
            end try
            try
                set f to file path of current document
            on error errMsg
                set why to "file path: " & errMsg
            end try
        end if
    end tell
    if f is not missing value then
        try
            set p to POSIX path of f
        on error errMsg2
            set why to "POSIX path: " & errMsg2
        end try
    end if
    set hasPath to "0"
    if f is not missing value then set hasPath to "1"
    return (n as text) & linefeed & nm & linefeed & hasPath & linefeed & p & linefeed & why
    """

    /// `flatten` 对本来就只有一个背景图层的文档会报「当前不可用」，所以单独 try 起来。
    private static func saveFrontScript(_ format: Format) -> String {
        """
        \(TO_FILE)
        tell application id "\(bundleID)"
            try
                set d to current document
                set dest to my toFile(file path of d)
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
    \(TO_FILE)
    tell application id "\(bundleID)"
        set doneN to 0
        set skipN to 0
        set failN to 0
        set lastErr to ""
        repeat with i from (count of documents) to 1 by -1
            try
                set d to document i
                set nm to name of d
                set dest to my toFile(file path of d)
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

        /// 后台校准那一发用的超时。它没人在等，卡住了就当没问过 —— 但**不能等 20 秒**：
        /// 那条专用线程是串行的，卡住的一发会把人随后按的 F15 一起堵在后面。
        static let quietTimeout: TimeInterval = 3

        /// - Parameter readOnly: 这段脚本改不改东西。只有只读的才允许在「空且无错」时重来一次。
        /// - Parameter timeout: 多久没回话就放弃。默认 20 秒（人按下去等着的那种）。
        /// - Parameter quiet: 超时不弹框，只记一行日志。**只有没人在等的后台探测才配 true** ——
        ///   人按了键的动作一律要说话，否则就是「按了没反应」。
        static func run(_ source: String, readOnly: Bool = false,
                        timeout: TimeInterval = Bridge.timeout, quiet: Bool = false,
                        _ done: @escaping (String?) -> Void) {
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
                if quiet {
                    Notify.log("PS 校准超时（\(Int(timeout))s），这一发放弃")
                } else {
                    Notify.problem("Photoshop 一直没回话",
                                "它多半正压着一个对话框（存储进度、生成式填充、缺字体提示…），"
                                + "也可能是第一次用、屏幕上正等你点「允许」。\n处理掉那个框再按一次。")
                }
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
                Notify.log("AppleScript 在专用线程上返回空，之后改走主线程")
                execOnMain(box)
                return
            }
            box.done(text)
        }

        private static func explain(_ error: NSDictionary) {
            let num = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (error[NSAppleScript.errorMessage] as? String) ?? ""
            Notify.log("Photoshop AppleScript 失败 \(num)：\(msg)")
            switch num {
            case -1743:
                Notify.problem("QuickBar 还不能控制 Photoshop",
                            "去「系统设置 → 隐私与安全性 → 自动化」，把 QuickBar 底下的 Photoshop 打开。")
                NSWorkspace.shared.open(Permissions.Kind.automation.settingsURL)
            case -600, -609:
                Notify.problem("Photoshop 没在跑", "先把主图丢进 PS，改完再来存回。")
            case -1712:
                Notify.problem("Photoshop 没回话", "它多半正压着一个对话框。处理掉那个框再按一次。")
            default:
                Notify.problem("跟 Photoshop 说话失败", msg.isEmpty ? "错误 \(num)" : "\(msg)（错误 \(num)）")
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
