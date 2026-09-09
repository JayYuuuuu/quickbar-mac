import AppKit

/// 「把这些商品的主图丢进 Photoshop」—— 素材下载完之后的第一道人工工序
/// （主图上有品牌水印，要在 PS 里去掉再存回原文件）。
///
/// 【真正花时间的不是修图】原来的流程是：Finder 里翻到批次 → 翻到商品文件夹（一批 60 多个）
/// → 进 `主图/` → 把图一张张拖进 PS。前面那三跳每件商品都要重来一遍，这个动作就是把它们合成一下。
///
/// 【范围不止采集素材】(v1.24.0) 采集下来的商品文件夹有「主图」这层结构，认得出就按那套挑；
/// 认不出的地方一律**就按人选的来**：选中几张图就是那几张，选中一个直接摆着图的普通文件夹
/// 就是里面那些图。**这条不该有门槛** —— 要去水印的图不会只出现在采集目录里，
/// 而「这个软件只认某种文件夹」是人根本猜不到的规矩。
///
/// 【开哪几张】商品文件夹长这样：`主图/ 主图1比1/ SKU图/ 详情图/ 视频/`，其中要去水印的是
/// 两套**不同的**图：`主图/`（3 比 4）和 `主图1比1/`（1 比 1）—— 不是同一套的裁剪版，
/// 两边都得改（用户 2026-08-24 确认）。每套各开**首图**，见 `FIRST_ONLY`。
/// 实测一批 31 件：`主图/` 各 5 张、`主图1比1/` 各 1 张（`main_1x1_01.jpg`，3 件是空的），
/// 所以加上 1 比 1 的代价是每件多一个标签页，不是多一堆。
/// 🔴 **`SUB_DIRS` 的顺序就是 PS 里的标签页顺序**：同一件商品的两张挨着出现，人是按这个认的。
///    要再加目录（`SKU图/`、`详情图/`…）先想清楚每件要多开几张 —— 那是个**决定**，
///    不该由这个动作偷偷替人做。
enum MainImages {

    /// 要开哪几个子目录里的图。顺序即打开顺序（同一件商品的几张挨着）。
    static let SUB_DIRS = ["主图", "主图1比1"]

    /// 🔴 **每个子目录只开第一张**（`主图/main_01`、`主图1比1/main_1x1_01`）—— 水印一般只在首图上
    ///    （用户 2026-08-24 明确：「只需要每个主图的第一张」）。
    ///    全开的代价是实打实的：一批 63 件光 `主图/` 就 507 张，PS 里 507 个标签页，
    ///    人得自己认哪张要改。哪天别的位次也要改，把这里改成 false 就恢复全开。
    ///    对 `主图1比1/` 这一条是空操作 —— 那里本来每件就只有一张。
    static let FIRST_ONLY = true

    private static let IMAGE_EXT: Set<String> = ["jpg", "jpeg", "png", "webp", "tif", "tiff", "bmp"]

    /// 超过这个数先问一声。一整批 60 多个商品 = 500 多张图，一次全丢进 PS 会把它打爆。
    private static let ASK_OVER = 30

    static let photoshopBundleID = "com.adobe.Photoshop"

    /// 一次挑图的结果。
    ///
    /// 🔴 **「几件」由这里给**，不该由调用方拿路径层级去猜：图在 `<商品>/主图/` 和
    ///    `<商品>/主图1比1/` 里，要往上跳**两层**才是商品，跳错一层件数当场翻倍。
    ///    这个数以前算在药丸那边，等于同一个口径散在两处。
    struct Pick {
        let images: [URL]
        /// 主图口径下是「几件商品」；「就这些图」口径下等于张数。
        let products: Int
        /// 走的是采集素材那条口径（`主图/` 那两个子目录），还是「人选的就是这些图」。
        /// 🔴 **药丸靠它决定怎么说话**：对着几张随手选的图说「主图 · 1 件 2 张」，
        ///    人会以为它在按某种猜不到的规矩挑图，于是不敢用（2026-09-09 用户就是这么以为的）。
        let isMainImages: Bool
        var isEmpty: Bool { images.isEmpty }
    }

    // MARK: - 对外

    /// 把这些路径里的图丢进 Photoshop。路径可以是：图片本身 / `主图` 目录 / 商品文件夹 / 批次目录，
    /// 以及（`allowLooseFolder` 为真时）任何直接摆着图的普通文件夹。
    ///
    /// - Parameter allowLooseFolder: 人**主动**点出来的动作（菜单栏、`quickbar://ps`）传 true；
    ///   药丸那条自动浮出的路要看人是不是真的选中了它，见 `pick`。
    static func openInPhotoshop(_ paths: [String], allowLooseFolder: Bool = true) {
        guard !paths.isEmpty else {
            Notify.problem("不知道要开哪些图", "先在 Finder 里选中图片、或者装着图的文件夹，再来一次。")
            return
        }
        let picked = pick(from: paths, allowLooseFolder: allowLooseFolder)
        guard !picked.isEmpty else {
            Notify.problem("这儿没找到图",
                           "认的是选中的图片本身、商品文件夹里的「主图」，或者直接摆着图的文件夹。"
                           + "\n（文件夹里的图不往下递归找，只看这一层。）")
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: photoshopBundleID) else {
            Notify.problem("没找到 Photoshop", "这台机器上没装，或者装的版本换了 bundle id（当前认的是 \(photoshopBundleID)）。")
            return
        }
        let images = picked.images
        if images.count > ASK_OVER {
            guard Notify.confirm("要一次打开 \(images.count) 张图吗？",
                                 "Photoshop 会开成 \(images.count) 个标签页，机器可能会卡一会儿。\n"
                                 + (picked.isMainImages
                                    ? "想少开一点：在 Finder 里只选中要处理的那几个商品文件夹。"
                                    : "想少开一点：在 Finder 里只选中要改的那几张。"),
                                 ok: "全部打开") else { return }
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(images, withApplicationAt: app, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Notify.problem("Photoshop 没能打开这些图", error.localizedDescription)
                    return
                }
                // 丢进去几张，收尾那半边（「存回原位」，见 Core/Photoshop.swift）就知道还剩几张要修。
                Photoshop.rememberOpened(images.count)
            }
        }
    }

    // MARK: - 挑图

    /// 展开成一串图。去重、保持传入顺序（同一个商品的图按文件名排，`main_01` 在前）。
    ///
    /// - Parameter allowLooseFolder: 允许「普通文件夹里直接摆着的图」也算数。
    ///   🔴 药丸那条路要传**人是不是真的选中了它**（`FinderService.selectionNow().picked`）：
    ///      什么都没选时访达返回的是当前窗口所在的目录，放开这一条的话，
    ///      随便打开一个有图的文件夹药丸就浮出来了 —— 那是浏览，不是要处理。
    static func pick(from paths: [String], allowLooseFolder: Bool) -> Pick {
        var out: [URL] = []
        var seen = Set<String>()
        var allMain = true
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
            let (found, main) = expand(url, allowLooseFolder: allowLooseFolder)
            if !found.isEmpty, !main { allMain = false }
            for one in found where !seen.contains(one.path) {
                seen.insert(one.path)
                out.append(one)
            }
        }
        // 混着选（一个商品文件夹 + 几张散图）就不算主图口径 —— 那种时候「几件」没有意义，
        // 说成「N 件」反而是把一个不成立的口径硬套上去。
        let main = allMain && !out.isEmpty
        let products = main
            ? Set(out.map { $0.deletingLastPathComponent().deletingLastPathComponent().path }).count
            : out.count
        return Pick(images: out, products: products, isMainImages: main)
    }

    /// 一个路径能是五种东西，按「越具体越优先」判。
    ///
    /// 🔴 **只往下看一层**（批次目录 → 商品文件夹 → `主图/`；普通文件夹也只看这一层）。
    ///    不做递归：给的要是品牌目录，递归下去就是几千张图，人只会看到 PS 卡死，
    ///    根本猜不到自己点了什么。
    /// - Returns: 挑出来的图，以及**走的是不是主图那条口径**（药丸靠它决定怎么说话）。
    private static func expand(_ url: URL, allowLooseFolder: Bool) -> (images: [URL], main: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return ([], false) }
        // ⓪ 就是一张图：人指名道姓选中的，不套任何口径
        if !isDir.boolValue { return (isImage(url) ? [url] : [], false) }

        // ① 自己就是 `主图/`
        if SUB_DIRS.contains(url.lastPathComponent) { return (images(in: url, firstOnly: FIRST_ONLY), true) }

        // ② 商品文件夹：下面挂着 `主图/`
        let mine = SUB_DIRS.map { url.appendingPathComponent($0) }.filter(isDirectory)
        if !mine.isEmpty { return (mine.flatMap { images(in: $0, firstOnly: FIRST_ONLY) }, true) }

        // ③ 批次目录：下面一堆商品文件夹
        let batch = childDirs(of: url).flatMap { child in
            SUB_DIRS.map { child.appendingPathComponent($0) }.filter(isDirectory)
                .flatMap { images(in: $0, firstOnly: FIRST_ONLY) }
        }
        if !batch.isEmpty { return (batch, true) }

        // ④ 普通文件夹：里面直接摆着图 —— 就是这些图，**全要**。
        //    🔴 这儿不套 `FIRST_ONLY`：那条是「下载器按序号排的主图里只有首张带水印」，
        //       随便一个文件夹里的图没有这层意思，只开第一张等于把人选的东西吃掉。
        guard allowLooseFolder else { return ([], false) }
        return (images(in: url, firstOnly: false), false)
    }

    private static func images(in dir: URL, firstOnly: Bool) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let all = names.sorted()
            .map { dir.appendingPathComponent($0) }
            .filter { isImage($0) }
        // 按文件名排序后的第一张就是 `main_01` / `main_1x1_01`（下载器按序号命名，见 listing-source 落盘约定）
        return firstOnly ? Array(all.prefix(1)) : all
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
