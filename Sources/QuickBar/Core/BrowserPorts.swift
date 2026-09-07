import Foundation

/// 哪个 Chrome 是哪个店 —— 跟 PortManager 对上号。
///
/// 【为什么要它】这台机器上同时开着 5 个 Chrome（PortManager 那套多 profile，各是独立进程），
/// 图标一模一样，网页标题又是「货品全站推广_万相台无界版 - 内存用量高 - 951 MB」这种一长串。
/// 人切浏览器时脑子里想的是**「去 C店 那个」**，不是「去标题里带万相台那个」。
/// 所以格子上真正该写的是店名。
///
/// 【怎么对上的】（2026-09-07 mac24g 实测）
/// 进程的命令行里有 `--remote-debugging-port=11111` 和 `--user-data-dir=~/.openclaw/browser/cmall`，
/// PortManager 的配置 `~/.openclaw/port-manager.json` 里那一项是 `{port: 11111, profile: "cmall", label: "C店"}`
/// —— 按 profile（拿不到就按端口）一查就是店名。四个实例全部对上：
/// 13333/dipdip=Dip、12222/买家=买家号、11111/cmall=C店、11222/tmall=天猫；
/// 第五个是用户自己那个普通 Chrome（argc=3，没有调试端口），不在 PortManager 里，也就没有店名。
///
/// 🔴 **读命令行用 `sysctl KERN_PROCARGS2`，别 fork `ps`。**
///    一是快（不建进程），二是 `ps` 会把非 ASCII 转义成 `M-dM-9M-0`（profile 名「买家」当场变乱码），
///    sysctl 拿到的是原始字节，UTF-8 直接解得开。
///
/// 🔴 **这是「跟 PortManager 联动」的全部**：只读它那份配置文件，不调用它、不要求它在跑、
///    也绝不写回去。它没装、配置没了、格式变了，都只是「格子上不显示店名」——
///    三向甩本身照常工作。跨软件联动一旦能把对方弄坏，就不该做。
enum BrowserPorts {

    struct Info {
        let port: Int?
        let profile: String?
        /// PortManager 里给这个 profile 起的名字（「C店」「天猫」）。没配就是 nil。
        let label: String?
    }

    private static let configPath = NSHomeDirectory() + "/.openclaw/port-manager.json"

    /// 这个进程是哪个店。不是 PortManager 管的 Chrome 就返回 nil。
    static func info(pid: pid_t) -> Info? {
        let args = commandLine(pid: pid)
        guard !args.isEmpty else { return nil }

        var port: Int?
        var profile: String?
        for a in args {
            if a.hasPrefix("--remote-debugging-port=") {
                port = Int(a.dropFirst("--remote-debugging-port=".count))
            } else if a.hasPrefix("--user-data-dir=") {
                let dir = String(a.dropFirst("--user-data-dir=".count))
                profile = URL(fileURLWithPath: dir).lastPathComponent
            }
        }
        guard port != nil || profile != nil else { return nil }

        let table = labels()
        let label = profile.flatMap { table.byProfile[$0] } ?? port.flatMap { table.byPort[$0] }
        return Info(port: port, profile: profile, label: label)
    }

    // MARK: - PortManager 那份配置

    private struct Table {
        var byProfile: [String: String] = [:]
        var byPort: [Int: String] = [:]
    }

    private static var cached: (stamp: Date, table: Table)?

    /// 配置文件按修改时间缓存 —— 人在 PortManager 里改了店名，下一次弹出就跟着变，
    /// 但没改的时候不用每次都解一遍 JSON。
    private static func labels() -> Table {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configPath)
        let stamp = (attrs?[.modificationDate] as? Date) ?? .distantPast
        if let cached, cached.stamp == stamp { return cached.table }

        var table = Table()
        if let data = FileManager.default.contents(atPath: configPath),
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for row in rows {
                // `label` 是人给起的名字；`short` 是它在菜单栏那条上的缩写，label 空了才退到它。
                let name = (row["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (row["short"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                guard let name else { continue }
                if let p = row["profile"] as? String, !p.isEmpty { table.byProfile[p] = name }
                if let port = row["port"] as? Int { table.byPort[port] = name }
            }
        }
        cached = (stamp, table)
        return table
    }

    // MARK: - 读进程的命令行

    /// `sysctl KERN_PROCARGS2` 的布局：`argc`（4 字节）→ 可执行路径 → 若干个 0 → argv[0…argc-1]，
    /// 每个以 0 结尾。同 uid 的进程读得到（实测五个 Chrome 全读到了）。
    private static func commandLine(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<4]) }
        guard argc > 0 else { return [] }

        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // 可执行路径
        while i < size && buf[i] == 0 { i += 1 }        // 中间的填充 0

        var out: [String] = []
        while i < size && out.count < Int(argc) {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if let s = String(bytes: buf[start..<i], encoding: .utf8) { out.append(s) }
            i += 1
        }
        return out
    }
}
