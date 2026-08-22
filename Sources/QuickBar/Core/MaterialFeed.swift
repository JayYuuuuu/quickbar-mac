import AppKit
import UserNotifications

extension Notification.Name {
    static let quickBarMaterialFeedChanged = Notification.Name("QuickBarMaterialFeedChanged")
}

/// 「最近派出去的素材下载批次」→ 快捷条里能直接跳的目录。
///
/// 为什么这批条目不能靠手工加：素材落盘的形状是
/// `<out>/<品牌>/<20260820-1305_补素材>/`，**每派一单就是一个新的时间戳目录**，
/// 今天加的书签明天就不指向任何东西了。而派单那侧（AI 电商内容助手的
/// 「品牌源素材下载」「品牌素材变动 → 补素材」）本来就把 brand / batchDir /
/// out / 下载状态全算在服务端了，这里只是把它取回来变成目录条目。
///
/// 权限只有读：走 `/api/listing-source/history`，一条写接口都不碰。
final class MaterialFeed {
    static let shared = MaterialFeed()

    /// 服务器地址。团队只有这一台，写死比让每个人填一遍靠谱。
    private static let server = "https://ai.yujiev.com:8444"

    /// 内置口令。**不在源码里**——仓库是公开的，值由 `build.sh` 构建时写进 Info.plist
    /// （来源见那儿：`QUICKBAR_MATERIAL_KEY` 或 `~/.quickbar-material-key`）。
    /// 没内置的包（比如别人 clone 下来自己编的）这里是空的，设置页就会露出「密码」那一栏。
    static let builtInKey = (Bundle.main.object(forInfoDictionaryKey: "QuickBarMaterialKey") as? String) ?? ""

    /// 实际用的口令：设置里手填的优先，方便服务端换了口令而新版还没发出去时自己顶上。
    static var apiKey: String {
        let typed = Store.shared.settings.materialFeedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? builtInKey : typed
    }

    /// 🔴 缓存的是批次本身，不是渲染好的条目：`detail` 里「今天只报时分」的判断跟当前日期有关，
    /// 存渲染结果的话跨夜就定死了——昨天的批次会一直显示成只有时分，看不出是昨天。
    private var batches: [MaterialBatch] = []

    /// 面板直接读这个。只在主线程读写。
    var items: [QuickItem] { batches.map(\.quickItem) }

    /// 设置页那一行结论。
    private(set) var statusText = "未启用"

    private let dir: URL
    private var timer: Timer?
    private var isFetching = false
    private var lastFetchAt: Date?
    /// 最近一次**成功**同步的时刻，设置页拿它算「几分钟前」。
    private(set) var lastSyncAt: Date?
    private var observersInstalled = false
    /// 已经通知过「下完了」的批次。持久化，否则每次重启都把历史批次重播一遍。
    private var notified: Set<String> = []
    /// 第一次成功拉取只播种不通知——不然装上软件的那一刻会一次弹出十几条历史通知。
    private var seeded = false

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        // 🔴 必须 true。开机自启时 didFinishLaunching 跑在网络栈就绪之前，
        // false 会让这一发**立刻**失败成 -1009「似乎已断开与互联网的连接」——
        // 不是超时、是零延迟返回，看起来像服务器挂了。实测踩过。
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 30   // 但也不能无限等，30 秒还不通就当这次失败
        return URLSession(configuration: config)
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("QuickBar", isDirectory: true)
        loadCache()
    }

    // MARK: - 生命周期

    /// 启动 / 重新配置，同一个入口。设置页改完开关、地址、Key 也调它。
    func start() {
        stop()
        guard isConfigured else {
            // 关掉之后必须把条目和缓存一起清干净，否则下次开机 loadCache() 会把
            // 一批过期目录又摆回快捷条上——用户已经明确说不要了。
            statusText = Store.shared.settings.materialFeedEnabled ? "还没填密码" : "未启用"
            guard !batches.isEmpty else { return }
            batches = []
            lastSyncAt = nil
            saveCache()
            Availability.shared.refresh()
            NotificationCenter.default.post(name: .quickBarMaterialFeedChanged, object: nil)
            return
        }
        requestNotificationAuthorizationIfNeeded()
        // 首拉延后一拍：开机自启那会儿系统正忙、网络也常常还没起来（同 Updater 的 30 秒退避，
        // 只是这边要早点有数据，所以短得多）。waitsForConnectivity 是兜底，这个是不去撞它。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        // 接回 NAS 的那一刻，批次目录才重新可用，顺手重算一次。
        // 只装一次：start() 会被反复调用，重复注册等于一次挂载触发好几次拉取。
        if !observersInstalled {
            observersInstalled = true
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didMountNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh(force: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var isConfigured: Bool {
        Store.shared.settings.materialFeedEnabled && !Self.apiKey.isEmpty
    }

    // MARK: - 拉取

    /// 面板弹出前会调一次（force: false）。**绝不能挡住这次弹出**——
    /// 网络整段在后台，界面永远只读缓存。
    func refresh(force: Bool) {
        guard isConfigured, !isFetching else { return }
        if !force, let last = lastFetchAt, Date().timeIntervalSince(last) < 30 { return }
        guard let url = endpoint() else { return }
        isFetching = true
        lastFetchAt = Date()

        var request = URLRequest(url: url)
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("QuickBar/\(Updater.shared.currentVersion)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            var outcome = Self.parse(data: data, response: response, error: error)

            // 目录探测放在后台：路径全在 /Volumes 上，卷没挂时 stat 会卡好几秒。
            func finish() {
                let mounted = Self.mountedVolumes()
                let resolved = outcome.batches.map { ($0, Availability.probe($0.path, mountedVolumes: mounted)) }
                DispatchQueue.main.async { self.apply(outcome: outcome, resolved: resolved) }
            }

            // 批次本身没拿到就别再多打一次请求了，直接照原样收尾。
            guard outcome.error == nil else { finish(); return }

            // 图片空间上传进度是**附加信息**：拿不到就当没有，照常显示批次。
            // 🔴 绝不能让这一发失败把整个列表打空 —— 那等于用一个锦上添花的功能
            //    换掉了快捷条最主要的用途。
            self.fetchUploads { uploads in
                if !uploads.isEmpty { outcome.batches = MaterialBatch.merge(outcome.batches, uploads: uploads) }
                finish()
            }
        }.resume()
    }

    /// 拉「这些批次传进图片空间没有」。只读端点，跟批次用同一把口令。
    /// 失败一律回空数组（不区分原因）——调用方只关心「有没有可显示的进度」。
    private func fetchUploads(_ done: @escaping ([String: UploadStatusRow]) -> Void) {
        guard let url = URL(string: Self.server + "/api/tu-upload/quickbar-status?limit=20") else { return done([:]) }
        var request = URLRequest(url: url)
        request.setValue(Self.apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("QuickBar/\(Updater.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let payload = try? JSONDecoder().decode(UploadStatusResponse.self, from: data)
            else { return done([:]) }
            var map: [String: UploadStatusRow] = [:]
            for row in payload.items where !row.key.isEmpty {
                if map[row.key] == nil { map[row.key] = row }   // 已按时间倒序，第一条就是最新那次
            }
            done(map)
        }.resume()
    }

    private func endpoint() -> URL? {
        URL(string: Self.server + "/api/listing-source/history?limit=40")
    }

    private static func mountedVolumes() -> Set<String> {
        Set((FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                  options: [.skipHiddenVolumes]) ?? []).map(\.path))
    }

    private struct Outcome {
        var batches: [MaterialBatch] = []
        var error: String?
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Outcome {
        if let error { return Outcome(error: error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 401 单独说：这是「密码错了」，说成「连不上」会让人去查网络。
        if code == 401 { return Outcome(error: "密码不对") }
        guard code == 200, let data else { return Outcome(error: "服务器返回 \(code)") }
        guard let payload = try? JSONDecoder().decode(MaterialFeedResponse.self, from: data) else {
            return Outcome(error: "返回内容看不懂")
        }
        return Outcome(batches: MaterialBatch.dedupe(payload.items.compactMap(MaterialBatch.init(row:))))
    }

    private func apply(outcome: Outcome, resolved: [(MaterialBatch, Availability.State)]) {
        isFetching = false

        if let error = outcome.error {
            statusText = error   // 拉失败时保留上一批条目：断网不该让快捷条突然少一截
            // 失败不占节流额度，否则开机时那一发失败后要干等 180 秒；
            // 清掉之后，下次唤出快捷条就会立刻重试。
            lastFetchAt = nil
            NotificationCenter.default.post(name: .quickBarMaterialFeedChanged, object: nil)
            return
        }

        // 派了单但还没落盘的批次直接丢掉（点了也跳不过去）；
        // 卷没挂的**留着**并交给 Availability 标记——「找不到就标记，绝不自动删」是本项目的既定原则。
        let usable = resolved.filter { $0.1 != .missing }.map { $0.0 }
        batches = usable
        lastSyncAt = Date()
        statusText = usable.isEmpty ? "没有可用批次" : "\(usable.count) 个批次"

        notifyNewlyFinished(usable)
        saveCache()
        Availability.shared.refresh()
        NotificationCenter.default.post(name: .quickBarMaterialFeedChanged, object: nil)
    }

    /// 最新那一批，菜单栏直接给个入口。
    var newest: QuickItem? { batches.first?.quickItem }

    // MARK: - 下完通知

    private func requestNotificationAuthorizationIfNeeded() {
        guard Store.shared.settings.materialFeedNotify, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyNewlyFinished(_ batches: [MaterialBatch]) {
        let finished = batches.filter(\.isFinished)
        defer { notified = Set(finished.map(\.id)) }   // 只记当前这 40 条里的，集合不会无限长大

        guard seeded else { seeded = true; return }    // 第一次只播种
        guard Store.shared.settings.materialFeedNotify, Bundle.main.bundleIdentifier != nil else { return }

        for batch in finished where !notified.contains(batch.id) {
            let content = UNMutableNotificationContent()
            content.title = batch.displayName
            content.body = "\(batch.progressLabel.isEmpty ? "\(batch.itemCount) 个商品" : batch.progressLabel) · 已下完"
            content.sound = .default
            content.userInfo = ["path": batch.path]
            let request = UNNotificationRequest(identifier: "material-\(batch.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    // MARK: - 缓存

    /// 缓存的意义是「开机后不用等第一次网络往返，快捷条上就已经有批次」。
    private struct Cache: Codable {
        var batches: [MaterialBatch]
        var notified: [String]
        var seeded: Bool
    }

    private var cacheURL: URL { dir.appendingPathComponent("material-batches.json") }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        batches = cache.batches
        notified = Set(cache.notified)
        seeded = cache.seeded
    }

    private func saveCache() {
        let cache = Cache(batches: batches, notified: Array(notified), seeded: seeded)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - 一个批次

/// 一个素材下载批次：服务端那一行里，快捷条真正用得上的部分。
struct MaterialBatch: Codable {
    let id: String
    let brand: String
    let batchDir: String
    let path: String
    let refill: Bool
    let itemCount: Int
    let progressLabel: String
    let isFinished: Bool

    /// 这批传进淘宝图片空间的进度。
    /// 🔴 **必须全是 Optional**：老版本缓存的 `material-batches.json` 里没有这几个键，
    ///    换成非 Optional 会让整份缓存解不开 → 升级后快捷条上的批次**全部消失**，
    ///    而且要等下一次网络拉取才恢复。（同 CLAUDE.md 里 QuickItem 那条教训。）
    var uploadStatus: String?
    var uploadDone: Int?
    var uploadTotal: Int?
    var uploadFailed: Int?

    init?(row: MaterialFeedRow) {
        let brand = row.brand.trimmingCharacters(in: .whitespaces)
        guard !brand.isEmpty else { return nil }

        // 优先用下载器自己回写的 reportDir：那是文件真正落到哪儿的第一手事实。
        // 没有（还在下载 / 老批次）才按 out/品牌/批次 拼，拼不出来就整条丢掉。
        let reported = (row.reports?.reportDir ?? "").trimmingCharacters(in: .whitespaces)
        if !reported.isEmpty {
            path = reported
        } else {
            let out = row.out.trimmingCharacters(in: .whitespaces)
            guard !out.isEmpty else { return nil }
            var p = (out as NSString).appendingPathComponent(brand)
            if !row.batchDir.isEmpty { p = (p as NSString).appendingPathComponent(row.batchDir) }
            path = p
        }

        id = row.id
        self.brand = brand
        batchDir = row.batchDir
        refill = row.refill
        itemCount = row.itemCount
        progressLabel = row.progressLabel
        isFinished = row.status == "done" && row.runState == "ok"
    }

    /// 同一个批次目录会出现多条任务记录（重下、卡死后重派都各建一条 todo）。
    /// 按目录去重，留下「下完了」的那条；都没下完就留最新的（history 已按创建时间倒序）。
    static func dedupe(_ batches: [MaterialBatch]) -> [MaterialBatch] {
        var order: [String] = []
        var best: [String: MaterialBatch] = [:]
        for batch in batches {
            guard let existing = best[batch.path] else {
                best[batch.path] = batch
                order.append(batch.path)
                continue
            }
            if batch.isFinished && !existing.isFinished { best[batch.path] = batch }
        }
        return order.compactMap { best[$0] }
    }

    /// 批次种类比时间戳更能让人一眼认出来，所以进名字；`补素材` 是最常见的那一种。
    var displayName: String {
        if refill { return "\(brand) · 补素材" }
        let code = batchDir.split(separator: "_").dropFirst().joined(separator: "_")
        return code.isEmpty ? brand : "\(brand) · \(code)"
    }

    /// 右侧那一行：下完了报件数和时间，没下完就把服务端那句进度原样搬过来。
    /// 正在往图片空间传的时候，这一行**整个让给上传进度**——那是此刻唯一在动的数字，
    /// 件数和时间戳随时都能再看，而人盯着快捷条就是想知道传到哪儿了。
    var detail: String {
        if uploadStatus == "running" { return "上传中 \(uploadDone ?? 0)/\(uploadTotal ?? 0)" }
        guard isFinished else { return progressLabel.isEmpty ? "下载中" : progressLabel }
        let stamp = Self.stamp(from: batchDir)
        let base = stamp.isEmpty ? "\(itemCount) 件" : "\(itemCount) 件 · \(stamp)"
        guard let tail = uploadTail else { return base }
        return "\(base) · \(tail)"
    }

    /// 图片空间那一小截。
    /// 🔴 **没派过上传任务就返回 nil**，不写「未上传」：绝大多数批次本来就轮不到传，
    ///    每行都挂一个否定词只会让真正需要注意的那几行淹掉。
    var uploadTail: String? {
        switch uploadStatus {
        case "pending": return "等着传"
        case "done":    return "已传"
        case "partial":
            let n = uploadFailed ?? 0
            return n > 0 ? "差 \(n) 张" : "差几张"
        case "failed":  return "没传上"
        case "cancelled": return nil     // 撤销了等于没派过，别留痕迹
        default:        return nil
        }
    }

    /// 跟上传记录对上号的钥匙。品牌 + 批次目录两边都来自同一份 source_meta，
    /// 所以是逐字相等的（`XUZHI` / `XU ZHI` 那种写法漂移在这儿不会碰上：
    /// 同一条记录的两侧读的是同一个字段）。
    var uploadKey: String { brand + "\u{0}" + batchDir }

    /// 把上传进度并进批次。查不到的原样返回 —— 不是「没传」，是「没派过」。
    static func merge(_ batches: [MaterialBatch], uploads: [String: UploadStatusRow]) -> [MaterialBatch] {
        batches.map { batch in
            guard let u = uploads[batch.uploadKey] else { return batch }
            var copy = batch
            copy.uploadStatus = u.status
            copy.uploadDone = u.done
            copy.uploadTotal = u.total
            copy.uploadFailed = u.failed
            return copy
        }
    }

    /// `20260820-1305_补素材` → `08-20 13:05`，**今天的只报 `13:05`**。
    ///
    /// 批次目录名自带时间，不必再解析 ISO 日期。今天的省掉日期不只是为了短：
    /// 人来找批次十有八九找的就是刚下的那批，「08-20」这天天一样的四个字符是噪音，
    /// 省下来正好够右侧那行完整显示，不至于被挤成 `28 件…09:16`。
    static func stamp(from batchDir: String) -> String {
        let head = batchDir.split(separator: "_").first.map(String.init) ?? ""
        let parts = head.split(separator: "-")
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 4 else { return "" }
        let date = parts[0], time = parts[1]
        let clock = "\(time.prefix(2)):\(time.suffix(2))"
        if date == Self.today() { return clock }
        let month = date[date.index(date.startIndex, offsetBy: 4)..<date.index(date.startIndex, offsetBy: 6)]
        let day = date[date.index(date.startIndex, offsetBy: 6)...]
        return "\(month)-\(day) \(clock)"
    }

    /// 批次目录名是服务端按北京时间打的戳，Mac 也在同一时区，直接按本地日期比。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static func today() -> String { dayFormatter.string(from: Date()) }

    var quickItem: QuickItem {
        var item = QuickItem(kind: .folder, name: displayName, path: path)
        item.subtitle = detail
        return item
    }
}

// MARK: - 服务端返回

struct MaterialFeedResponse: Decodable {
    let items: [MaterialFeedRow]
}

/// `/api/tu-upload/quickbar-status` 的返回。
struct UploadStatusResponse: Decodable {
    let items: [UploadStatusRow]
}

/// 一条上传任务。字段同样逐个兜默认值 —— 理由见下面 MaterialFeedRow 的说明，
/// 服务端还在长，不能让它加个字段就把这边打空。
struct UploadStatusRow: Decodable {
    let brand: String
    let batchDir: String
    let status: String
    let total: Int
    let done: Int
    let failed: Int

    enum CodingKeys: String, CodingKey {
        case brand, status, total, done, failed
        case batchDir = "batch_dir"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        func int(_ key: CodingKeys) -> Int { (try? c.decode(Int.self, forKey: key)) ?? 0 }
        brand = string(.brand)
        batchDir = string(.batchDir)
        status = string(.status)
        total = int(.total)
        done = int(.done)
        failed = int(.failed)
    }

    var key: String { brand + "\u{0}" + batchDir }
}

/// `/api/listing-source/history` 的一行。
///
/// 每个字段都按「缺了就用默认值」解码，**不用合成的 Decodable**：
/// 那个只要有一行少一个键就整批抛错，表现是快捷条上素材批次凭空消失、
/// 设置页只说一句「返回内容看不懂」。服务端是另一个项目、还在长，
/// 不能让它加个字段或某行少个字段就把这边打空。
struct MaterialFeedRow: Decodable {
    /// 只有一个可选字段，合成的 Decodable 本身就用 decodeIfPresent，缺键或 null 都回 nil。
    struct Reports: Decodable { let reportDir: String? }

    let id: String
    let brand: String
    let batchDir: String
    let out: String
    let status: String
    let runState: String
    let progressLabel: String
    let refill: Bool
    let itemCount: Int
    let reports: Reports?

    enum CodingKeys: String, CodingKey {
        case id, brand, batchDir, out, status, refill, itemCount, reports
        case runState = "run_state"
        case progressLabel = "progress_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        id = string(.id)
        brand = string(.brand)
        batchDir = string(.batchDir)
        out = string(.out)
        status = string(.status)
        runState = string(.runState)
        progressLabel = string(.progressLabel)
        refill = (try? c.decode(Bool.self, forKey: .refill)) ?? false
        itemCount = (try? c.decode(Int.self, forKey: .itemCount)) ?? 0
        reports = try? c.decode(Reports.self, forKey: .reports)
    }
}
