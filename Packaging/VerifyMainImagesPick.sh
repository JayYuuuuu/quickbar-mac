#!/bin/bash
# 「选中这些东西该开哪几张图」：跑一遍断言。
#
# 为什么值得有这么个脚本：这个口径同时决定**药丸浮不浮出来**和**点下去开什么**。
# 认宽了，随手选中一个文件夹就往 PS 里灌一堆图；认窄了，人以为这软件只认采集目录
# （2026-09-09 用户就是这么以为的，而散图其实一直能开）。两种都表现成「它很随机」。
# 挑图是纯函数 + readdir，造一棵树跑一遍就全测到了。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/VerifyMainImagesPick.sh'
set -euo pipefail
# 同 build.sh：Xcode 许可没同意时 swift / swiftc 一律拒跑，命令行工具那套不受影响
[ -d /Library/Developer/CommandLineTools ] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)/pick.swift"

# 🔴 从产品代码里抠，不另抄一份 —— 抄一份测的就不是真正在跑的那套。
{
  echo 'import Foundation'
  echo 'enum MainImages {'
  awk '/^    static let SUB_DIRS/{f=1} f&&/^    static let photoshopBundleID/{exit} f{print}' Sources/QuickBar/Core/MainImages.swift
  awk '/^    struct Pick \{/{f=1} f{print} f&&/^    \}$/{exit}' Sources/QuickBar/Core/MainImages.swift
  awk '/^    \/\/ MARK: - 挑图/{f=1} f{print}' Sources/QuickBar/Core/MainImages.swift
} > "$TMP"

cat >> "$TMP" <<'SWIFT'

// ── 造一棵树：左边是采集下来的样子，右边是随便一个装着图的文件夹 ──────────────
let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qbpick")
try? fm.removeItem(at: root)
func mkdir(_ p: String) { try! fm.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true) }
func touch(_ p: String) { fm.createFile(atPath: root.appendingPathComponent(p).path, contents: Data("x".utf8)) }
func at(_ p: String) -> String { root.appendingPathComponent(p).path }

mkdir("批次/商品_1/主图");      touch("批次/商品_1/主图/main_01.jpg"); touch("批次/商品_1/主图/main_02.jpg")
mkdir("批次/商品_1/主图1比1");  touch("批次/商品_1/主图1比1/main_1x1_01.jpg")
mkdir("批次/商品_1/详情图");    touch("批次/商品_1/详情图/d_01.jpg")
mkdir("批次/商品_2/主图");      touch("批次/商品_2/主图/main_01.jpg")
mkdir("随便一个文件夹/里面还有一层")
touch("随便一个文件夹/a.jpg"); touch("随便一个文件夹/b.JPG"); touch("随便一个文件夹/c.png")
touch("随便一个文件夹/说明.txt"); touch("随便一个文件夹/.隐藏.jpg")
touch("随便一个文件夹/里面还有一层/d.jpg")
mkdir("空文件夹")

var failed = 0, total = 0
/// want: (张数, 件数, 是不是主图口径)
func check(_ name: String, _ paths: [String], loose: Bool, _ want: (Int, Int, Bool)) {
    let got = MainImages.pick(from: paths, allowLooseFolder: loose)
    let ok = got.images.count == want.0 && got.products == want.1 && got.isMainImages == want.2
    total += 1
    if !ok { failed += 1 }
    print("\(ok ? "OK  " : "FAIL") \(name)  -> \(got.images.count) 张 / \(got.products) 件 / 主图口径=\(got.isMainImages)"
          + "  期望 \(want.0) 张 / \(want.1) 件 / \(want.2)")
}

// 采集素材那条口径：只取首图，件数要跳两层数出来
check("一个商品文件夹（主图 + 1比1 各取首张）", [at("批次/商品_1")], loose: false, (2, 1, true))
check("整个批次目录（两件）",                   [at("批次")],        loose: false, (3, 2, true))
check("直接选中 主图/ 那一层",                  [at("批次/商品_1/主图")], loose: false, (1, 1, true))
// 🔴 详情图/ 不在 SUB_DIRS 里 —— 商品文件夹只挑主图，别把整件商品的图都灌进去
check("商品文件夹里的 详情图/ 不算",             [at("批次/商品_1")], loose: false, (2, 1, true))

// 人选中的就是这些图：不套首图那条，也不叫「主图」
check("选中 2 张散图",   [at("随便一个文件夹/a.jpg"), at("随便一个文件夹/b.JPG")], loose: false, (2, 2, false))
check("选中 1 张散图",   [at("随便一个文件夹/a.jpg")], loose: false, (1, 1, false))
check("普通文件夹（人选中了它）", [at("随便一个文件夹")], loose: true,  (3, 3, false))
// 🔴 没选中它、只是打开着 → 一张都不给，否则随便浏览一个有图的文件夹药丸就浮出来
check("普通文件夹（只是打开着）", [at("随便一个文件夹")], loose: false, (0, 0, false))
// 🔴 只看这一层，不递归：给的要是品牌目录，递归下去就是几千张
check("普通文件夹不递归子目录",   [at("随便一个文件夹")], loose: true,  (3, 3, false))
check("子目录自己选中才算",       [at("随便一个文件夹/里面还有一层")], loose: true, (1, 1, false))

// 混着选：「几件」这个口径不成立，别硬套
check("商品文件夹 + 一张散图", [at("批次/商品_1"), at("随便一个文件夹/a.jpg")], loose: false, (3, 3, false))

// 该给空的
check("空文件夹",       [at("空文件夹")], loose: true, (0, 0, false))
check("不是图的文件",   [at("随便一个文件夹/说明.txt")], loose: true, (0, 0, false))
check("路径根本不存在", [at("没有这个东西")], loose: true, (0, 0, false))
check("隐藏图不算",     [at("随便一个文件夹/.隐藏.jpg")], loose: true, (0, 0, false))

try? fm.removeItem(at: root)
print(failed == 0 ? "\n全过（\(total) 条）" : "\n\(failed)/\(total) 条没过")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "${TMP%.swift}" "$TMP" && "${TMP%.swift}"
