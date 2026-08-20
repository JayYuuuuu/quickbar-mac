import AppKit

extension Notification.Name {
    static let quickBarAvailabilityChanged = Notification.Name("QuickBarAvailabilityChanged")
}

/// 条目指向的东西还在不在。
///
/// 关键约束：**不能在界面线程上直接 stat**。条目路径可能落在没挂载的外置盘
/// 或网络卷上，`fileExists` 在那种情况下会一卡好几秒——快捷条要求 16ms 内弹出，
/// 这一下就废了。所以探测全在后台队列做，界面只读缓存。
///
/// 另一条原则：找不到就**标记**，绝不自动删除。外置盘拔掉时把条目删了，
/// 等于插回去也回不来，用户的配置就毁了。
final class Availability {
    static let shared = Availability()

    enum State: Equatable {
        case ok
        /// 路径在某个卷上，而那个卷现在没挂载——插回去就好了。
        case volumeOffline(String)
        /// 卷是在的，但东西没了（应用被卸载、文件夹被删或改名）。
        case missing

        var isUsable: Bool { self == .ok }

        /// 一行结论，界面上就显示这个。
        var label: String? {
            switch self {
            case .ok: return nil
            case .volumeOffline(let volume): return "「\(volume)」未挂载"
            case .missing: return "找不到"
            }
        }
    }

    private var cache: [String: State] = [:]
    private let probeQueue = DispatchQueue(label: "com.yujiev.quickbar.availability", qos: .utility)

    private init() {}

    /// 界面读这个。没探测过的一律先当作可用——宁可让用户点一次没反应，
    /// 也不要因为还没探测完就把条目画成灰的。
    func state(of item: QuickItem) -> State {
        cache[item.path] ?? .ok
    }

    var unavailableCount: Int {
        Store.shared.items.reduce(0) { $0 + (state(of: $1).isUsable ? 0 : 1) }
    }

    func start() {
        refresh()
        // 插拔外置盘时立刻重算，这是最常见的状态变化来源。
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let paths = Store.shared.items.map(\.path)
        probeQueue.async { [weak self] in
            let mounted = Set(
                (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                       options: [.skipHiddenVolumes]) ?? [])
                    .map(\.path)
            )
            var result: [String: State] = [:]
            for path in paths {
                result[path] = Self.probe(path, mountedVolumes: mounted)
            }
            DispatchQueue.main.async {
                guard let self, self.cache != result else { return }
                self.cache = result
                NotificationCenter.default.post(name: .quickBarAvailabilityChanged, object: nil)
            }
        }
    }

    // 内部可见是为了能单独测：这段判定顺序（先看卷、再 stat）是防卡死的关键。
    static func probe(_ path: String, mountedVolumes: Set<String>) -> State {
        // 先看卷在不在。卷没挂的话 fileExists 本身就会卡，所以顺序不能反。
        if path.hasPrefix("/Volumes/") {
            let rest = path.dropFirst("/Volumes/".count)
            if let name = rest.split(separator: "/").first {
                let volume = "/Volumes/" + name
                if !mountedVolumes.contains(volume) { return .volumeOffline(String(name)) }
            }
        }
        return FileManager.default.fileExists(atPath: path) ? .ok : .missing
    }
}
