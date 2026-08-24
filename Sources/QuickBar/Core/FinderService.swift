import AppKit

/// 盯着 Finder 最前窗口在哪个文件夹、里面选中了什么。
///
/// AppleScript 一次要几十毫秒，不能在按下快捷键时才现查——
/// 所以在 Finder 激活/失活的时候各刷一次，平时直接用缓存。
/// 失活那一刷正好是「离开 Finder 去上传窗」的那一瞬间，选中项就是这么拿到的。
final class FinderService {
    static let shared = FinderService()

    private(set) var currentPath: String
    private(set) var currentName: String
    /// 最前窗口里选中的那个**文件**（只选中一个、且不是文件夹时才有值）。
    /// 不落盘——重启之后「上次选中的文件」没有意义。
    private(set) var currentSelection: String?

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
        guard let raw = Self.runScript() else { return currentPath }

        let lines = raw.components(separatedBy: "\n")
        let folder = lines.first ?? ""
        let selected = lines.count > 1 ? lines[1] : ""

        // 搜索/「最近使用」这类窗口拿不到 target，但选中项照样有——
        // 这时候就用选中项所在的目录，⌘G 一样能落到实处。
        var path = folder
        if path.isEmpty, !selected.isEmpty {
            path = (selected as NSString).deletingLastPathComponent
        }
        guard !path.isEmpty else { return currentPath }

        currentPath = path
        currentName = (path as NSString).lastPathComponent
        currentSelection = Self.validSelection(selected, in: path)
        UserDefaults.standard.set(path, forKey: Self.cacheKey)
        return path
    }

    /// 选中项要同时满足：是个文件（不是文件夹）、就在当前目录下。
    /// 不在当前目录说明那是别的窗口留下的旧选择，跟着跳过去只会更迷惑。
    private static func validSelection(_ path: String, in folder: String) -> String? {
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let parent = trimSlash((path as NSString).deletingLastPathComponent)
        return parent == trimSlash(folder) ? path : nil
    }

    /// Finder 给文件夹的 POSIX path 带尾斜杠，文件不带，比较前统一削掉。
    private static func trimSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// **现查**一次：Finder 最前窗口里选中的所有项（文件夹也算）。一个都没选就返回窗口本身那个目录。
    ///
    /// 🔴 不能用缓存的 `currentSelection`：那个只记「单个文件」、而且是 Finder 激活/失活时刷的。
    ///    「把选中的这几个商品文件夹丢进 PS」必须是**按下那一刻**的真实选择，差一步就开错东西。
    ///    代价是一次 AppleScript 往返（几十毫秒），点菜单时完全无感。
    func selectionNow() -> [String] {
        guard Permissions.isGranted(.automation) else { return [] }
        let source = """
        tell application "Finder"
            if (count of Finder windows) = 0 then return ""
            set out to ""
            set picked to selection
            if (count of picked) is 0 then
                try
                    set out to POSIX path of (target of front Finder window as alias)
                end try
            else
                repeat with one in picked
                    set out to out & POSIX path of (one as alias) & linefeed
                end repeat
            end if
            return out
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return [] }
        let result = script.executeAndReturnError(&error)
        guard error == nil, let text = result.stringValue else { return [] }
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 返回两行：第一行是最前窗口的目录，第二行是选中的单个项目（没有就空行）。
    private static func runScript() -> String? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) = 0 then return ""
            set folderPath to ""
            try
                set folderPath to POSIX path of (target of front Finder window as alias)
            end try
            set selectedPath to ""
            try
                set picked to selection
                if (count of picked) is 1 then
                    set selectedPath to POSIX path of ((item 1 of picked) as alias)
                end if
            end try
            return folderPath & linefeed & selectedPath
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        guard let text = result.stringValue, !text.isEmpty else { return nil }
        return text
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
