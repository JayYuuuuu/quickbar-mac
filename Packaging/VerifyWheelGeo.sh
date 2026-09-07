#!/bin/bash
# 三向甩的方向判定：跑一遍断言。
#
# 为什么值得有这么个脚本：判定错了的表现是「看着指着左边那格、松手却切去了别处」，
# 人只会觉得**它很随机** —— 而这是最难从反馈里查回来的一类问题。几何是纯函数，
# 一秒钟就能全测一遍，没有理由靠推理。
#
# 第一版就是在这儿翻的：往右上 45° 甩落进了「上」，因为四等分把 45° 正好压在分界线上。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/VerifyWheelGeo.sh'
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)/geo.swift"

# 🔴 从产品代码里抠，不另抄一份 —— 抄一份测的就不是真正在跑的那套。
awk '/^@MainActor$/{exit} {print}' Sources/QuickBar/Core/WindowSwitch.swift > "$TMP"
awk '/^\/\/ MARK: - 几何/{f=1} /^\/\/ MARK: - 画$/{f=0} f{print}' Sources/QuickBar/UI/SwitchWheel.swift >> "$TMP"

cat >> "$TMP" <<'SWIFT'
let c = CGPoint(x: 1000, y: 500)      // anchor 落在屏幕上的那个点
var failed = 0
func check(_ name: String, _ dx: CGFloat, _ dy: CGFloat, _ want: SwitchLane?) {
    let got = WheelGeo.lane(at: CGPoint(x: c.x + dx, y: c.y + dy), center: c)
    let ok = got == want
    if !ok { failed += 1 }
    print("\(ok ? "OK  " : "FAIL") \(name)  (\(Int(dx)),\(Int(dy))) -> \(got.map { "\($0)" } ?? "取消")  期望 \(want.map { "\($0)" } ?? "取消")")
}

/// 🔴 设计稿最后一条实现侧要求的那一条：**轮廓的斜边必须就是判定边界**。
/// 稿子上手画的塔顶顶点是 120.21°，跟它自己声称的 55° 差 5° —— 抄下来就会漂，
/// 漂的表现是「看着指着一格、松手切去别处」。这条断言专门盯它。
func checkAngle(_ name: String, _ p: CGPoint, _ want: CGFloat) {
    let a = WheelGeo.anchor
    let deg = atan2(p.y - a.y, p.x - a.x) * 180 / .pi
    let ok = abs(deg - want) < 0.01
    if !ok { failed += 1 }
    print(String(format: "%@ %@ 顶点(%.1f,%.1f) -> %.2f°  期望 %.0f°",
                 ok ? "OK  " : "FAIL", name, p.x, p.y, deg, want))
}

print("panel \(WheelGeo.panelSize)  anchor \(WheelGeo.anchor)")
print("— 轮廓即判定 —")
let top = WheelGeo.panelSize.height - WheelGeo.cut
checkAngle("塔根左", CGPoint(x: WheelGeo.edgeX(atY: WheelGeo.shaftTop, left: true), y: WheelGeo.shaftTop), 125)
checkAngle("塔顶左", CGPoint(x: WheelGeo.edgeX(atY: top, left: true), y: top), 125)
checkAngle("塔根右", CGPoint(x: WheelGeo.edgeX(atY: WheelGeo.shaftTop, left: false), y: WheelGeo.shaftTop), 55)
checkAngle("塔顶右", CGPoint(x: WheelGeo.edgeX(atY: top, left: false), y: top), 55)
checkAngle("翼下沿左", CGPoint(x: WheelGeo.edgeX(atY: 0, left: true), y: 0), -125)
checkAngle("翼下沿右", CGPoint(x: WheelGeo.edgeX(atY: 0, left: false), y: 0), -55)

print("— 方向判定 —")
check("原地不动",       0,    0,    nil)
check("正左甩 200",   -200,   0,    .browser)
check("正右甩 200",    200,   0,    .finder)
check("正上甩 200",      0,  200,   .document)
check("正下甩 200",      0, -200,   nil)
check("左上斜甩 135", -300,  300,   .browser)
check("右上斜甩 45",   300,  300,   .finder)
check("偏上一点 70",   109,  300,   .document)
check("偏右一点 40",   300,  252,   .finder)
check("刚出死区·左",   -30,   0,    .browser)
check("死区内·左",     -20,   0,    nil)
check("甩很远·左",   -1500,  10,    .browser)
check("塔根内侧",      -38,   55,   .document)   // 贴着 125° 线的塔那一侧
check("翼根内侧",      -40,   53,   .browser)    // 同一条线的另一侧

print("— 摊开那一列 —")
func checkRow(_ name: String, _ count: Int, _ dy: CGFloat, _ want: Int) {
    let got = ListGeo.index(at: CGPoint(x: c.x, y: c.y - dy), center: c, count: count)
    let ok = got == want
    if !ok { failed += 1 }
    print("\(ok ? "OK  " : "FAIL") \(name) \(count) 个，往下 \(Int(dy))pt -> 第 \(got) 行  期望 \(want)")
}
checkRow("不动就是第一行", 5, 0, 0)
checkRow("往下一行",       5, 36, 1)
checkRow("往下到底",       5, 400, 4)
checkRow("往上夹回 0",     5, -200, 0)
checkRow("截断行不可选",   30, 999, ListGeo.maxRows - 2)

print(failed == 0 ? "全部通过" : "\(failed) 条不过")
exit(failed == 0 ? 0 : 1)
SWIFT

swift "$TMP"
