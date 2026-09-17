#!/bin/bash
# 药丸躲窗口：跑一遍断言。
#
# 为什么值得有这个脚本：躲错了的表现是「药丸有时候跳到别处去」「有时候还是压着」，
# 人只会觉得**它很随机**。几何是纯函数，造几个窗口位置一秒钟就全测一遍。
#
# 坐标是 AppKit 那套（左下原点、y 向上）。下面的屏幕尺寸是假设的，窗口位置有一组是
# 2026-09-17 mac24g 实测的（拷贝进度框 + 浏览窗口同时在时 AX 读到的），换算时假设主屏高 1440。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/VerifyPillPlacement.sh'
set -euo pipefail
# 同 build.sh：Xcode 许可没同意时 swift / swiftc 一律拒跑，命令行工具那套不受影响
[ -d /Library/Developer/CommandLineTools ] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)/placement.swift"

# 🔴 整个文件原样拿来，不另抄一份 —— 抄一份测的就不是真正在跑的那套。
cat Sources/QuickBar/Core/PillPlacement.swift > "$TMP"

cat >> "$TMP" <<'SWIFT'

let screen = CGRect(x: 0, y: 0, width: 2560, height: 1415).insetBy(dx: 8, dy: 8)
let pill = CGSize(width: 180, height: 32)
var failed = 0, total = 0

/// AX 坐标（左上原点）的窗口 → AppKit
func win(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: 1440 - (y + h), width: w, height: h)
}
/// 访达的锚点：窗口右下角内侧 (−12, −12)，跟 `MainImagesPill.place` 一致
func corner(_ host: CGRect) -> CGRect {
    CGRect(x: host.maxX - pill.width - 12, y: host.minY + 12, width: pill.width, height: pill.height)
}

func check(_ name: String, host: CGRect, obstacles: [CGRect], _ expect: (CGRect, CGRect) -> String?) {
    total += 1
    let want = corner(host)
    let p = PillPlacement.origin(for: want, avoiding: obstacles, within: screen)
    let got = CGRect(origin: p, size: pill)
    var why = expect(got, want)
    // 通用的两条：不出屏幕；有路可躲时不压着任何障碍物
    if why == nil, !screen.contains(got) { why = "出了屏幕" }
    if why == nil, !name.contains("无路可躲"), obstacles.contains(where: { $0.intersects(got) }) { why = "还压着障碍物" }
    if why != nil { failed += 1 }
    let moved = Int(hypot(got.minX - want.minX, got.minY - want.minY))
    print("\(why == nil ? "OK  " : "FAIL") \(name)  -> (\(Int(got.minX)),\(Int(got.minY)))  挪了 \(moved)\(why.map { "  ✗ \($0)" } ?? "")")
}
func stays(_ got: CGRect, _ want: CGRect) -> String? { got.origin == want.origin ? nil : "不该动却动了" }
func moves(_ got: CGRect, _ want: CGRect) -> String? { got.origin != want.origin ? nil : "该躲没躲" }

let browser = win(820, 237, 942, 492)          // 实测：浏览窗口
let progress = win(1080, 341, 404, 88)         // 实测：同一时刻的拷贝进度框

print("— 不该动 —")
check("没有障碍物", host: browser, obstacles: [], stays)
check("实测那一轮：进度框在屏幕中间，没压到右下角", host: browser, obstacles: [progress], stays)
check("进度框离药丸正好 20 点", host: browser, obstacles: [CGRect(x: browser.maxX - 12 - 180 - 20 - 300, y: browser.minY, width: 300, height: 88)], stays)

print("— 该躲 —")
// 用户实拍的情形：进度框（404×88）正好浮在浏览窗口右下角上
let onCorner = CGRect(x: browser.maxX - 404 + 30, y: browser.minY - 20, width: 404, height: 88)
check("进度框压在右下角上", host: browser, obstacles: [onCorner], moves)
check("进度框只擦到药丸顶上 4 点 → 往下挪一小截，不往上翻过去",
      host: browser, obstacles: [CGRect(x: browser.maxX - 300, y: browser.minY + 12 + 32 - 4, width: 300, height: 88)]) { got, want in
    got.minY < want.minY ? nil : "应该往下躲"
}
check("窗口贴着屏幕底边，下面没地方 → 往上躲",
      host: CGRect(x: 600, y: 8, width: 942, height: 492),
      obstacles: [CGRect(x: 600 + 942 - 404, y: 0, width: 404, height: 88)]) { got, want in
    got.minY > want.minY ? nil : "应该往上躲"
}
check("两个进度框叠着 → 两个都躲开", host: browser,
      obstacles: [onCorner, CGRect(x: onCorner.minX, y: onCorner.maxY + 4, width: 404, height: 88)], moves)

print("— 夹回屏幕 —")
check("窗口一半拖出了屏幕右边", host: CGRect(x: 2400, y: 300, width: 942, height: 492), obstacles: []) { got, _ in
    got.maxX <= screen.maxX ? nil : "没夹回来"
}

print("— 无路可躲 —")
check("无路可躲：障碍物盖满整块屏幕 → 留在原位", host: browser, obstacles: [screen.insetBy(dx: -8, dy: -8)], stays)

print(failed == 0 ? "\n断言全过（\(total) 条）" : "\n\(failed)/\(total) 条没过")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "${TMP%.swift}" "$TMP" && "${TMP%.swift}"
