import AppKit

/// 网页上那个「在 Finder 打开」按钮的落点：`quickbar://reveal?path=…&dir=…&suffix=…`
///
/// 【为什么非得由本机的程序来接】网页自己开不了本地文件夹——https 页面里的 `file://` 链接
/// 浏览器一律拦掉；而素材服务器跑在 NAS 的容器里，它够不着人正坐着的这台 Mac 的访达。
/// 中间缺的就是「本机上有个常驻的东西愿意接这一下」。QuickBar 本来就常驻、本来就在开访达
/// （`Actions.openFolder`，复用当前 Finder 窗口所以尺寸不会跳），顺手把这条协议接上，
/// 网页那边就退化成一个普通的 `<a href>`。
///
/// 【只做 reveal，别的什么都不做】自定义协议是**任何网页**都能往里塞参数的入口，所以这里：
///   · 只开访达：不执行、不删除、不写盘、不回传任何东西；
///   · 路径必须落在 `/Volumes`（素材盘都在这儿）或用户家目录下，别的一概不理；
///   · `..` 先折平再判前缀，绕不过去；
///   · **绝不「点了没反应」**：目标没了就退到还在的上一层，并说清为什么。
enum URLScheme {

    static let scheme = "quickbar"

    /// 同一条 URL 两秒内只处理一次。
    /// AppKit 的默认 GetURL 处理器与我们自己装的那个都可能到这儿来，撞上就会开两次访达。
    private static var lastURL = ""
    private static var lastAt = Date.distantPast

    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == scheme else { return }
        let key = url.absoluteString
        if key == lastURL, Date().timeIntervalSince(lastAt) < 2 { return }
        lastURL = key; lastAt = Date()

        // `quickbar://reveal?…` 里动作名落在 host 上；写成 `quickbar:reveal?…` 时落在 path 上，两处都认。
        let raw = url.host ?? url.path
        let action = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q: (String) -> String = { name in items.first { $0.name == name }?.value ?? "" }

        switch action {
        case "reveal", "open":
            reveal(path: q("path"), dir: q("dir"), suffix: q("suffix"))
        case "ps":
            // 把这些目录里的主图丢进 Photoshop（`path` 可以出现多次）。挑图口径见 MainImages。
            MainImages.openInPhotoshop(items.filter { $0.name == "path" }.compactMap(\.value).filter { !$0.isEmpty }
                                            .compactMap { allowed($0)?.path })
        default:
            NSLog("[QuickBar] 不认识的 quickbar:// 动作：\(action)")
        }
    }

    // MARK: - reveal

    /// - Parameters:
    ///   - path: 首选目标（商品文件夹）。派发方已经保证它是「存在的那一层」，但盘上的事随时会变。
    ///   - dir: 兜底目录（批次目录）。`path` 没了就开它，人至少落在对的那一批里。
    ///   - suffix: 形如 `_1063903380912`。`path` 没命中时拿它在 `dir` 里**再找一次**——
    ///     服务器读到的目录名与访达呈现的万一对不上（SMB 的 Unicode 归一化差异就够了），
    ///     这一步能自愈回那个文件夹，而不是把人丢在批次目录里自己翻。
    static func reveal(path: String, dir: String, suffix: String) {
        let target = allowed(path)
        let fallback = allowed(dir)

        if let t = target, exists(t) { open(t); return }

        if let d = fallback, isDir(d) {
            if !suffix.isEmpty, let hit = child(of: d, endingWith: suffix) { open(hit); return }
            open(d)
            Notify.tell("没找到那个商品文件夹", "已经打开它所在的批次目录：\(d.lastPathComponent)")
            return
        }

        // 连批次目录都没了：退到还存在的最近一层（多半是品牌目录或采集根目录）。
        if let any = target ?? fallback, let up = nearestExisting(any) {
            open(up)
            Notify.tell("那个文件夹不在盘上了", "已经打开还找得到的上一层：\(up.path)")
            return
        }

        Notify.tell("打不开这个文件夹", target == nil && fallback == nil
             ? "这条链接给的路径不在素材盘（/Volumes）里，没有打开。"
             : "共享盘可能没挂上——先在访达里连一下 NAS 再点。")
    }

    // MARK: - 路径闸门

    /// 只放行素材盘与用户家目录下的路径。`reveal` 和 `ps` 共用这一道闸门。
    ///`..` 先折平（`standardizedFileURL`）再判前缀，绕不过去。
    private static func allowed(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let p = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if p.hasPrefix("/Volumes/") { return url }
        if p == home || p.hasPrefix(home + "/") { return url }
        return nil
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func isDir(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    /// 在 `dir` 里找名字以 `suffix` 结尾的子目录（商品文件夹的名字末尾就是 `_<商品ID>`）。
    private static func child(of dir: URL, endingWith suffix: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.hasSuffix(suffix) }) else { return nil }
        return dir.appendingPathComponent(hit)
    }

    /// 往上找第一层还存在的目录（最多爬到 `/Volumes` 就停，别开到根目录去）。
    private static func nearestExisting(_ url: URL) -> URL? {
        var cur = url.deletingLastPathComponent()
        for _ in 0..<12 {
            let p = cur.path
            if p == "/" || p == "/Volumes" { return nil }
            if isDir(cur) { return cur }
            cur = cur.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - 动作

    private static func open(_ url: URL) {
        if isDir(url) {
            Actions.openFolder(url.path)          // 复用当前 Finder 窗口（窗口尺寸不会跳）
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])   // 是个文件就选中它
        }
    }
}
