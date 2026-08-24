import AppKit

/// 「把这些商品的主图丢进 Photoshop」—— 素材下载完之后的第一道人工工序
/// （主图上有品牌水印，要在 PS 里去掉再存回原文件）。
///
/// 【真正花时间的不是修图】原来的流程是：Finder 里翻到批次 → 翻到商品文件夹（一批 60 多个）
/// → 进 `主图/` → 把图一张张拖进 PS。前面那三跳每件商品都要重来一遍，这个动作就是把它们合成一下。
///
/// 【只认 `主图/` 的第一张】商品文件夹长这样：`主图/ 主图1比1/ SKU图/ 详情图/ 视频/`；
/// 每件只开 `主图/` 里的**首图**（`main_01`）—— 水印一般只烧在第一张上。见 `FIRST_ONLY`。
/// 🔴 **有意不顺手带上 `主图1比1/`**：那是从店铺列表卡片回填的另一套图，跟着一起开等于每件多开一堆
///    标签页，人还得分辨哪张是哪套。哪天确认它也要去水印，在 `SUB_DIRS` 里加一行就行 —— 但那是
///    一个**决定**，不该由这个动作偷偷替人做。
enum MainImages {

    /// 要开哪几个子目录里的图。顺序即打开顺序。
    static let SUB_DIRS = ["主图"]

    /// 🔴 **每个商品只开「主图」里的第一张**（`main_01`）—— 水印一般只在首图上
    ///    （用户 2026-08-24 明确：「只需要每个主图的第一张」）。
    ///    全开的代价是实打实的：一批 63 件 = 507 张，PS 里 507 个标签页，人得自己认哪张要改。
    ///    哪天别的位次也要改，把这里改成 false 就恢复全开。
    static let FIRST_ONLY = true

    private static let IMAGE_EXT: Set<String> = ["jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp"]

    /// 超过这个数先问一声。一整批 60 多个商品 = 500 多张图，一次全丢进 PS 会把它打爆。
    private static let ASK_OVER = 30

    static let photoshopBundleID = "com.adobe.Photoshop"

    // MARK: - 对外

    /// 把这些路径里的主图丢进 Photoshop。路径可以是：单张图 / `主图` 目录 / 商品文件夹 / 批次目录。
    static func openInPhotoshop(_ paths: [String]) {
        guard !paths.isEmpty else {
            Notify.tell("不知道要开哪儿的主图", "先在 Finder 里选中商品文件夹（或那一批），再来一次。")
            return
        }
        let images = collect(from: paths)
        guard !images.isEmpty else {
            Notify.tell("这儿没找到主图", "认的是商品文件夹里的 `主图/`（也可以直接选批次目录或图片本身）。")
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: photoshopBundleID) else {
            Notify.tell("没找到 Photoshop", "这台机器上没装，或者装的版本换了 bundle id（当前认的是 \(photoshopBundleID)）。")
            return
        }
        if images.count > ASK_OVER {
            guard Notify.confirm("要一次打开 \(images.count) 张首图吗？",
                                 "Photoshop 会开成 \(images.count) 个标签页，机器可能会卡一会儿。\n"
                                 + "想少开一点：在 Finder 里只选中要处理的那几个商品文件夹。",
                                 ok: "全部打开") else { return }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(images, withApplicationAt: app, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Notify.tell("Photoshop 没能打开这些图", error.localizedDescription)
                    return
                }
                // 丢进去几张，收尾那半边（「存回原位」，见 Core/Photoshop.swift）就知道还剩几张要修。
                Photoshop.rememberOpened(images.count)
            }
        }
    }

    // MARK: - 挑图

    /// 展开成一串主图。去重、保持传入顺序（同一个商品的图按文件名排，`main_01` 在前）。
    static func collect(from paths: [String]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
            for one in expand(url) where !seen.contains(one.path) {
                seen.insert(one.path)
                out.append(one)
            }
        }
        return out
    }

    /// 一个路径能是四种东西，按「越具体越优先」判。
    ///
    /// 🔴 **只往下看一层**（批次目录 → 商品文件夹 → `主图/`）。不做递归：给的要是品牌目录，
    ///    递归下去就是几千张图，人只会看到 PS 卡死，根本猜不到自己点了什么。
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return isImage(url) ? [url] : [] }

        // ① 自己就是 `主图/`
        if SUB_DIRS.contains(url.lastPathComponent) { return images(in: url) }

        // ② 商品文件夹：下面挂着 `主图/`
        let mine = SUB_DIRS.map { url.appendingPathComponent($0) }.filter(isDirectory)
        if !mine.isEmpty { return mine.flatMap(images(in:)) }

        // ③ 批次目录：下面一堆商品文件夹
        return childDirs(of: url).flatMap { child in
            SUB_DIRS.map { child.appendingPathComponent($0) }.filter(isDirectory).flatMap(images(in:))
        }
    }

    private static func images(in dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let all = names.sorted()
            .map { dir.appendingPathComponent($0) }
            .filter { isImage($0) }
        // 按文件名排序后的第一张就是 `main_01`（下载器按序号命名，见 listing-source 落盘约定）
        return FIRST_ONLY ? Array(all.prefix(1)) : all
    }

    private static func childDirs(of dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted()
            .filter { !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0) }
            .filter(isDirectory)
    }

    private static func isImage(_ url: URL) -> Bool {
        !url.lastPathComponent.hasPrefix(".") && IMAGE_EXT.contains(url.pathExtension.lowercased())
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
