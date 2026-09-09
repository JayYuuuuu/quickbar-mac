import AppKit

/// 剪贴板里躺着一条 Mac 路径时，按 ⌘⇧G 直接在访达里打开它。
///
/// 【补的是哪一步】素材/视频那几个网页上都有「复制路径」。复制完，人要做的是：
/// 切到访达 → ⌘⇧G 叫出「前往文件夹」→ ⌘V → 回车，而且手边还得先有个访达窗口。
/// 这里把这一串压成一下 —— 在**任何**应用里按 ⌘⇧G，访达就跳过去了。
/// 网页上那颗「在访达打开」按钮走的是 `quickbar://reveal`，跟这里是同一件事的两个入口
/// （鼠标一个、键盘一个），落点也是同一段代码。
///
/// 【凭什么敢抢 ⌘⇧G】三个条件同时成立才吞掉这一下，差一个就原样放行：
///   · 剪贴板里确实是一条落在素材盘或家目录下的路径（闸门跟 `quickbar://` 共用一道）；
///   · 前台不是访达 —— 访达自己的 ⌘⇧G 是「前往文件夹」，人可能正想手打一条别的路径；
///   · 「打开/保存」对话框没浮着 —— 那儿归 `jumpKeyCode`（⌘G）那条老路管。
/// 别的应用里 ⌘⇧G 是「查找上一个」，剪贴板里没有路径时这里一个字节都不动它。
/// **不用 ⌘G**：那是全系统的「查找下一个」，而人刚在网页上复制完路径，多半还在那页上翻。
///
/// 🔴 **判据必须是现成的。** 事件 tap 的回调有时间预算，超了系统会把整个 tap 关掉，
///    表现是所有快捷键毫无征兆地一起失灵。读剪贴板是一次跨进程调用，绝不能放进那个回调 ——
///    所以这里在主线程上维护一个布尔，tap 只读它。
enum ClipboardJump {

    // MARK: - 给事件 tap 读的那个布尔

    private static let lock = NSLock()
    private static var _armed = false

    /// **事件 tap 线程读这个**，所以这条路上不能有任何 IO。
    static var armed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _armed
    }

    // MARK: - 刷新（全部在主线程）

    private static var lastChangeCount = -1
    private static var pending = false

    /// 人敲了键或松了鼠标——剪贴板可能变了。跟 `MainImagesPill.noteUserInput` 挂在同一个信号上：
    /// 剪贴板只会被人的操作改变，没必要另起一条轮询。**主线程调用。**
    ///
    /// 🔴 **要等这 120ms**：⌘C 的 keyDown 到剪贴板真被写进去还隔着一段，
    ///    立刻读会读到上一份，人紧接着按 ⌘⇧G 就成了「按了没反应」。
    static func noteUserInput() {
        guard Store.shared.settings.clipboardJumpEnabled else { return }
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pending = false
            refresh()
        }
    }

    /// `changeCount` 没变就立刻返回——这是这条路上唯一会被频繁走到的地方，得便宜。
    private static func refresh() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        let hit = URLScheme.allowed(clean(pb.string(forType: .string) ?? "")) != nil
        lock.lock(); _armed = hit; lock.unlock()
    }

    /// 开关关掉时把布尔也收掉，否则 tap 那边还举着一个永远为真的判据。
    static func reload() {
        guard Store.shared.settings.clipboardJumpEnabled else {
            lock.lock(); _armed = false; lock.unlock()
            return
        }
        lastChangeCount = -1
        refresh()
    }

    // MARK: - 按下了

    /// `armed` 说剪贴板里有路径，这一下已经被**吞掉**了 —— 所以失败必须说话。
    static func jump() { run(loud: true) }

    /// `armed` 说没有，事件已经**放行**给了那个应用（别处 ⌘⇧G 是「查找上一个」）。
    /// 🔴 **仍然要现查一次**：那个布尔是输入事件之后 120ms 才刷新的，人复制完立刻按
    ///    就可能还没热 —— 而「按了没反应」是这功能最不该有的表现。把正确性从时序上摘下来，
    ///    比赌那 120ms 够不够稳（Photoshop 那边「只读探测撞上就翻主线程」是同一个思路）。
    ///    剪贴板里确实没路径是常态，所以这一发不说话。
    static func jumpIfReallyPath() { run(loud: false) }

    /// 🔴 **这一刻现读剪贴板**。`armed` 只是「值不值得吞掉这一下」的判断，
    ///    中间剪贴板被改过就会开错东西——那比慢半拍严重得多（药丸那边踩过同一个坑）。
    private static func run(loud: Bool) {
        let raw = clean(NSPasteboard.general.string(forType: .string) ?? "")
        guard let url = URLScheme.allowed(raw) else {
            guard loud else { return }
            Notify.problem("剪贴板里不是一条能打开的路径",
                           raw.isEmpty
                           ? "先在网页上点一下「复制路径」，再按这个键。"
                           : "只认素材盘（/Volumes/…）和你自己家目录下的路径。现在剪贴板里是：\n\(preview(raw))")
            return
        }
        Notify.log("剪贴板跳转→ \(url.path)")

        // 🔴 存在性检查放后台：素材盘是 SMB，盘掉了一次 stat 能卡好几秒，
        //    放主线程上就是整个软件转圈。
        DispatchQueue.global(qos: .userInitiated).async {
            let there = URLScheme.exists(url)
            let up = there ? nil : URLScheme.nearestExisting(url)
            DispatchQueue.main.async {
                if there { URLScheme.open(url); return }
                // 绝不「按了没反应」：退到还在的上一层，并说清为什么。
                if let up {
                    URLScheme.open(up)
                    Notify.tell("那个东西不在盘上了", "已经打开还找得到的上一层：\(up.path)")
                    return
                }
                Notify.problem("打不开这个位置",
                               "共享盘可能没挂上——先在访达里连一下 NAS 再按。\n\(url.path)")
            }
        }
    }

    // MARK: - 清洗

    /// 剪贴板里的东西比 URL 参数脏：有的地方复制路径会带上引号，粘出来还常挂着空行。
    /// **内部还有换行的一律不认** —— 那是一段文本，不是一条路径。
    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, s.last == f, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !s.contains("\n"), !s.contains("\r") else { return "" }
        // `file:///Volumes/…`（中文在里面是转义过的）也认，顺手换回普通路径。
        if s.lowercased().hasPrefix("file://"), let u = URL(string: s), u.isFileURL {
            s = u.path
        }
        return s
    }

    /// 弹框里回显剪贴板内容：太长的截断，不然一条长路径会把对话框撑到看不清重点。
    private static func preview(_ s: String) -> String {
        s.count <= 120 ? s : String(s.prefix(120)) + "…"
    }
}
