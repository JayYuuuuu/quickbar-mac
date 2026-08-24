import AppKit

/// `~/最近素材批次/` —— 想在 **Finder 里**看到最近那几批素材，这是最省事的做法。
///
/// 【为什么不是 Finder 插件】Finder 侧栏只收**真实存在的文件夹**，插件（FinderSync）能加的是
/// 右键菜单、工具栏按钮和角标，塞不进侧栏。而「最近 12 批」本身就可以是一个真实目录：
/// 里面放 12 个替身（符号链接），服务器那份清单一变就重建一次。人只需要把这个目录
/// **拖进侧栏一次**，之后点开就是最新那几批 —— 手工加书签跟不上，是因为每派一单就换一个
/// 新的时间戳目录，而不是因为 Finder 不行。
///
/// 🔴 **只删自己建的符号链接**。这个目录在人的家目录下，他完全可能往里放点别的东西；
///    重建时按「是不是 symlink」筛，普通文件/文件夹一律不碰 —— 宁可留一个过期的名字，
///    也不能删掉人家的东西。
///
/// 🔴 **整套 IO 都在后台队列**。目标在 `/Volumes` 上（SMB），盘要是掉了，一个 `stat`
///    能卡好几秒。这活儿由网络回调触发，卡在主线程上就是整个软件转圈。
enum BatchLinks {

    static let dirName = "最近素材批次"
    private static let keep = 12

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dirName, isDirectory: true)
    }

    private static let queue = DispatchQueue(label: "quickbar.batchlinks", qos: .utility)

    /// 服务器那份批次清单每次刷新完都调它（开关关着就顺手清干净）。
    static func sync(_ batches: [MaterialBatch]) {
        let enabled = Store.shared.settings.batchLinksEnabled && Store.shared.settings.materialFeedEnabled
        let wanted: [(name: String, target: String)] = enabled
            ? batches.prefix(keep).map { (name(for: $0), $0.path) }
            : []
        queue.async { rebuild(wanted: wanted, keepDir: enabled) }
    }

    /// 设置里关掉时立刻清空（不用等下一次网络刷新）。
    static func clear() {
        queue.async { rebuild(wanted: [], keepDir: false) }
    }

    /// 目录不在就建一个，然后交给 Finder 打开 —— 让人把它拖进侧栏。
    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Actions.openFolder(dir.path)
    }

    // MARK: - 实现

    private static func rebuild(wanted: [(name: String, target: String)], keepDir: Bool) {
        let fm = FileManager.default
        // 目标不存在的不建链接：盘没挂 / 那批被挪走了，建出来就是一排断链，点进去只会更迷惑。
        let live = wanted.filter { isDirectory($0.target) }
        let names = Set(live.map(\.name))

        if !live.isEmpty {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else {
            // 目录还不存在（也没东西要放）→ 什么都不用做
            for one in live { link(one, fm: fm) }
            return
        }

        // ① 清掉自己建的、这一轮不该有的那些
        for name in entries {
            let path = dir.appendingPathComponent(name).path
            guard isSymlink(path) else { continue }        // 🔴 不是符号链接 = 不是我们建的，绝不动
            if !names.contains(name) { try? fm.removeItem(atPath: path) }
        }

        // ② 建这一轮该有的
        for one in live { link(one, fm: fm) }

        // ③ 关掉之后目录空了就把目录也收走，不留一个空壳在人家目录里
        if !keepDir,
           let rest = try? fm.contentsOfDirectory(atPath: dir.path), rest.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private static func link(_ one: (name: String, target: String), fm: FileManager) {
        let path = dir.appendingPathComponent(one.name).path
        if isSymlink(path) {
            // 已经有了：指向没变就别动（动一下 Finder 里那一行会闪）
            if (try? fm.destinationOfSymbolicLink(atPath: path)) == one.target { return }
            try? fm.removeItem(atPath: path)
        } else if fm.fileExists(atPath: path) {
            return   // 同名的真文件/真目录 —— 人自己放的，让它赢
        }
        try? fm.createSymbolicLink(atPath: path, withDestinationPath: one.target)
    }

    /// `20260821-1225_补素材` + `CNLEEWEI` → `20260821-1225 CNLEEWEI 补素材`。
    /// 日期打头，Finder 按名字排就是时间序；`:` `/` 在 Finder 里是分隔符，换掉。
    private static func name(for batch: MaterialBatch) -> String {
        let head = batch.batchDir.split(separator: "_").first.map(String.init) ?? batch.batchDir
        let tail = batch.refill ? " 补素材" : ""
        let raw = "\(head) \(batch.brand)\(tail)"
        return raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSymlink(_ path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)   // 不跟随链接
        return (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return !path.isEmpty
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }
}
