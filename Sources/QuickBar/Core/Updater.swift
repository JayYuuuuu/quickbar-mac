import AppKit
import Security

/// 静默自动更新：盯 GitHub Releases，有新版就换掉自己再重启。
///
/// 安全性靠代码签名而不是 HTTPS 一层：下载解压之后，用**当前运行版本自己的
/// designated requirement** 去校验新版本。签名主体和 bundle id 对不上就直接丢弃，
/// 所以哪怕仓库或下载链路被换掉，装不上不属于我们签的东西。
///
/// 因为 QuickBar 是无窗口的后台程序，静默模式下换版本 + 重启对用户完全无感。
final class Updater {
    static let shared = Updater()

    static let repository = "JayYuuuuu/quickbar-mac"
    private static let checkInterval: TimeInterval = 6 * 3600

    /// 供菜单栏显示的状态，一行结论。
    @Published private(set) var statusText = "已是最新版本"

    private var timer: Timer?
    private var isBusy = false

    private init() {}

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 本地构建（0.0.0-dev）不参与自动更新。
    /// 否则装上开发版试跑，30 秒后就被线上正式版悄悄换掉了——
    /// 表现是「代码明明改了，跑起来还是旧行为」，非常难查。
    var isDevelopmentBuild: Bool { currentVersion.contains("dev") }

    func startScheduledChecks() {
        guard Store.shared.settings.autoUpdate, !isDevelopmentBuild else { return }
        // 开机自启时别和登录风暴抢资源，等 30 秒再说。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check(userInitiated: false)
        }
    }

    func stopScheduledChecks() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 检查

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        guard userInitiated || (Store.shared.settings.autoUpdate && !isDevelopmentBuild) else { return }
        isBusy = true
        statusText = "正在检查更新…"

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("QuickBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil,
                  let release = try? JSONDecoder().decode(Release.self, from: data)
            else {
                self.finish(userInitiated: userInitiated, message: "检查更新失败，稍后重试")
                return
            }

            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            guard Self.isNewer(latest, than: self.currentVersion) else {
                self.finish(userInitiated: userInitiated, message: "已是最新版本 \(self.currentVersion)")
                return
            }
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                self.finish(userInitiated: userInitiated, message: "\(latest) 没有可用的下载包")
                return
            }
            DispatchQueue.main.async { self.statusText = "正在下载 \(latest)…" }
            self.download(asset: asset, version: latest, userInitiated: userInitiated)
        }.resume()
    }

    private func finish(userInitiated: Bool, message: String) {
        DispatchQueue.main.async {
            self.isBusy = false
            self.statusText = message
            if userInitiated { self.notify(message) }
        }
    }

    // MARK: - 下载 / 校验 / 替换

    private func download(asset: Release.Asset, version: String, userInitiated: Bool) {
        var request = URLRequest(url: URL(string: asset.browserDownloadURL)!)
        request.setValue("QuickBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 300

        URLSession.shared.downloadTask(with: request) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL, error == nil else {
                self.finish(userInitiated: userInitiated, message: "下载失败，稍后重试")
                return
            }
            do {
                let newApp = try self.unpack(tempURL)
                try self.verifySignature(of: newApp)
                try self.install(newApp, version: version, userInitiated: userInitiated)
            } catch {
                self.finish(userInitiated: userInitiated, message: "更新未安装：\(error.localizedDescription)")
            }
        }.resume()
    }

    private func unpack(_ zip: URL) throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickBarUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // ditto 才认得 macOS 的资源分叉和签名，别用 unzip。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", zip.path, workDir.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateError.unpackFailed }

        let contents = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.unpackFailed
        }
        return app
    }

    /// 用「我自己」的签名要求去校验新版本。签名主体或 bundle id 不一致就装不上。
    private func verifySignature(of app: URL) throws {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            throw UpdateError.signatureCheckUnavailable
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.signatureCheckUnavailable
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.signatureCheckUnavailable
        }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else {
            throw UpdateError.signatureMismatch
        }
        let status = SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else { throw UpdateError.signatureMismatch }
    }

    private func install(_ newApp: URL, version: String, userInitiated: Bool) throws {
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw UpdateError.destinationNotWritable
        }

        let silent = Store.shared.settings.autoUpdateSilently && !userInitiated
        if !silent {
            let go = DispatchQueue.main.sync { () -> Bool in
                let alert = NSAlert()
                alert.messageText = "QuickBar \(version) 已下载"
                alert.informativeText = "现在重启 QuickBar 完成更新？重启只需一瞬间，不会打断你手上的事。"
                alert.addButton(withTitle: "现在重启")
                alert.addButton(withTitle: "稍后")
                return alert.runModal() == .alertFirstButtonReturn
            }
            guard go else {
                finish(userInitiated: userInitiated, message: "更新 \(version) 已下载，稍后重启生效")
                return
            }
        }

        try swapAndRelaunch(newApp: newApp, destination: destination)
    }

    /// 自己不能替换正在运行的自己，所以交给一个等我们退出后再动手的小脚本。
    private func swapAndRelaunch(newApp: URL, destination: URL) throws {
        let script = """
        #!/bin/sh
        PID=$1
        NEW="$2"
        DEST="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="$DEST.qbold"
        /bin/rm -rf "$BACKUP"
        /bin/mv "$DEST" "$BACKUP" || exit 1
        if /bin/mv "$NEW" "$DEST"; then
          /bin/rm -rf "$BACKUP"
        else
          /bin/mv "$BACKUP" "$DEST"
          exit 1
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open -n "$DEST"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickbar-swap-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                          newApp.path, destination.path]
        try task.run()

        DispatchQueue.main.async {
            Store.shared.saveNow()
            NSApp.terminate(nil)
        }
    }

    // MARK: - 杂项

    private func notify(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "QuickBar"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 逐段比较 1.2.10 这类版本号，别用字符串比大小。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    enum UpdateError: LocalizedError {
        case unpackFailed, signatureMismatch, signatureCheckUnavailable, destinationNotWritable

        var errorDescription: String? {
            switch self {
            case .unpackFailed: return "下载包解压失败"
            case .signatureMismatch: return "新版本的签名与当前版本不一致，已丢弃"
            case .signatureCheckUnavailable: return "无法校验签名"
            case .destinationNotWritable: return "没有写入权限，请把 QuickBar 放到「应用程序」里"
            }
        }
    }
}
