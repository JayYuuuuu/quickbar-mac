import AppKit
import Foundation

/// 操作日志回传（2026-09-30）：「谁、几点、做了什么、成没成」传到 ai-ecommerce `/api/app-logs/ingest`，
/// 排查问题时在网站「软件日志」页（管理员）直接查。和帧选同一套（帧选那份在 framepick `Library/AppLog.swift`），
/// 帧选发过来的 `quickbar://ps?…&trace=` 带着同一个编号，两边的记录能串成一条线。
///
/// 起因：帧选主图页「送去 Photoshop」第一次点了没反应，这边的本机日志（`Notify.log`）只记失败、别人也看不到，
/// 到现在说不清是帧选没发出来还是这边没接住。
///
/// 规矩（用户 2026-09-30 定）：静默开、不另行通知；只记动作和结果（路径可以），不记文件内容、密钥；服务端存 30 天、只有管理员能看。
/// 身份用本机 PortManager 签的证明（`/pm/whoami`），不另带口令 —— 素材那把 QuickBar key 故意只开只读接口。
///
/// 🔴 旁路，绝不反过来卡软件：记一条只是往本机文件追加一行；每分钟把攒下的一批传上去，传不上留着下次再传；
/// 本机最多 5MB，满了丢最老的一半。
final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "quickbar.applog")
    private var flushing = false          // 只在 queue 上读写
    private let dir: URL
    private var current: URL { dir.appendingPathComponent("applog.jsonl") }
    private var sending: URL { dir.appendingPathComponent("applog.sending.jsonl") }
    private var runningMark: URL { dir.appendingPathComponent("running") }
    private static let cap = 5 * 1024 * 1024
    private static let perPost = 500
    private static let server = "https://ai.yujiev.com:8444"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("QuickBar/applog", isDirectory: true)
    }

    // MARK: - 记

    /// 记一条。`action` 用固定的英文名（网站那页有对照表翻成人话）。
    static func log(_ action: String, _ target: String = "", ok: Bool = true, ms: Double? = nil,
                    err: String = "", trace: String = "", detail: [String: String] = [:]) {
        guard Bundle.main.bundleIdentifier != nil else { return }   // 命令行 / 测试里跑的不记
        var e: [String: Any] = ["at": stamp(), "action": action, "ok": ok]
        if !target.isEmpty { e["target"] = String(target.prefix(600)) }
        if let ms { e["ms"] = Int(ms.rounded()) }
        if !err.isEmpty { e["err"] = String(err.prefix(600)) }
        if !trace.isEmpty { e["trace"] = String(trace.prefix(40)) }
        if !detail.isEmpty { e["detail"] = detail }
        guard let data = try? JSONSerialization.data(withJSONObject: e) else { return }
        shared.append(data)
    }

    private static func stamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    private func append(_ line: Data) {
        queue.async { [self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? Int) ?? nil, size > Self.cap {
                Self.dropOldestHalf(current)
            }
            var d = line; d.append(0x0A)
            if let h = try? FileHandle(forWritingTo: current) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: d)
            } else {
                try? d.write(to: current)
            }
        }
    }

    private static func dropOldestHalf(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        var out = Data()
        for l in lines.suffix(lines.count / 2) { out.append(contentsOf: l); out.append(0x0A) }
        try? out.write(to: url, options: .atomic)
    }

    // MARK: - 开 / 关

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let abnormal = FileManager.default.fileExists(atPath: runningMark.path)
        try? Data().write(to: runningMark)
        if abnormal { Self.log("app.lastRunAbnormal", "上次没正常退出（闪退 / 强退 / 断电）") }
        Self.log("app.launch", Updater.shared.currentVersion,
                 detail: ["os": ProcessInfo.processInfo.operatingSystemVersionString])
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in AppLog.shared.flush() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { AppLog.shared.flush() }
    }

    func quit() {
        Self.log("app.quit")
        try? FileManager.default.removeItem(at: runningMark)
    }

    // MARK: - 传

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        return c.urlSession
    }()

    func flush() {
        queue.async { [self] in
            guard !flushing else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: sending.path) {
                guard fm.fileExists(atPath: current.path) else { return }
                try? fm.moveItem(at: current, to: sending)
            }
            guard let data = try? Data(contentsOf: sending), !data.isEmpty else {
                try? fm.removeItem(at: sending); return
            }
            let lines = data.split(separator: 0x0A).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
            guard !lines.isEmpty else { try? fm.removeItem(at: sending); return }
            flushing = true
            let chunks = stride(from: 0, to: lines.count, by: Self.perPost).map {
                Array(lines[$0..<min($0 + Self.perPost, lines.count)])
            }
            Self.whoami { who in
                guard let who else {           // 没 PortManager / 没领证：留着下次再传
                    self.queue.async { self.flushing = false }
                    return
                }
                self.postAll(chunks, who: who, index: 0) { allOK in
                    self.queue.async {
                        if allOK { try? FileManager.default.removeItem(at: self.sending) }
                        self.flushing = false
                    }
                }
            }
        }
    }

    private func postAll(_ chunks: [[[String: Any]]], who: Who, index: Int, done: @escaping (Bool) -> Void) {
        guard index < chunks.count else { done(true); return }
        let body: [String: Any] = [
            "app": "quickbar",
            "ver": Updater.shared.currentVersion,
            "host": Host.current().localizedName ?? "",
            "person": who.owner,
            "device": who.deviceId,
            "entries": chunks[index],
        ]
        guard let url = URL(string: Self.server + "/api/app-logs/ingest"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { done(false); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(who.proof, forHTTPHeaderField: "X-PM-Identity")
        req.setValue("QuickBar/\(Updater.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.httpBody = data
        session.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(code)
                && ((data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["ok"] as? Bool) == true
            guard ok else { done(false); return }
            self.postAll(chunks, who: who, index: index + 1, done: done)
        }.resume()
    }

    // MARK: - 身份（本机 PortManager）

    private struct Who { let owner: String; let deviceId: String; let proof: String }
    private static var cached: (who: Who, at: Date)?

    /// 问本机 PortManager 要一张现签的证明（12 小时有效，这里 20 分钟换一张）。回环地址不走代理。
    private static func whoami(_ done: @escaping (Who?) -> Void) {
        if let c = cached, Date().timeIntervalSince(c.at) < 20 * 60 { done(c.who); return }
        guard let url = URL(string: "http://127.0.0.1:47600/pm/whoami") else { done(nil); return }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 5
        URLSession(configuration: cfg).dataTask(with: url) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            guard let proof = j?["proof"] as? String, !proof.isEmpty else { done(nil); return }
            let who = Who(owner: j?["owner"] as? String ?? "", deviceId: j?["deviceId"] as? String ?? "", proof: proof)
            AppLog.shared.queue.async { cached = (who, Date()) }
            done(who)
        }.resume()
    }
}

private extension URLSessionConfiguration {
    var urlSession: URLSession { URLSession(configuration: self) }
}
