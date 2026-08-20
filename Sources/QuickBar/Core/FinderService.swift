import AppKit

/// 盯着 Finder 最前窗口在哪个文件夹。
///
/// AppleScript 一次要几十毫秒，不能在按下快捷键时才现查——
/// 所以在 Finder 激活/失活的时候各刷一次，平时直接用缓存。
final class FinderService {
    static let shared = FinderService()

    private(set) var currentPath: String
    private(set) var currentName: String

    private static let cacheKey = "lastFinderPath"

    private init() {
        currentPath = UserDefaults.standard.string(forKey: Self.cacheKey) ?? NSHomeDirectory()
        currentName = (currentPath as NSString).lastPathComponent
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didDeactivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.finder" else { return }
                self?.refresh()
            }
        }
        refresh()
    }

    /// 查一次 Finder 最前窗口。查不到就保留上一次的值——
    /// 「上一次看过的文件夹」本来就是这个功能想要的语义。
    @discardableResult
    func refresh(force: Bool = false) -> String {
        guard force || Permissions.isGranted(.automation) else { return currentPath }
        guard let path = Self.runScript(), !path.isEmpty else { return currentPath }
        currentPath = path
        currentName = (path as NSString).lastPathComponent
        UserDefaults.standard.set(path, forKey: Self.cacheKey)
        return path
    }

    private static func runScript() -> String? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) = 0 then return ""
            try
                return POSIX path of (target of front Finder window as alias)
            on error
                return ""
            end try
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    /// 有没有「自动化 → Finder」的授权。不弹框，纯查询。
    static func automationGranted() -> Bool {
        var target = AEAddressDesc()
        var identifier = Array("com.apple.finder".utf8)
        guard AECreateDesc(typeApplicationBundleID, &identifier, identifier.count, &target) == 0 else {
            return false
        }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false) == noErr
    }
}
