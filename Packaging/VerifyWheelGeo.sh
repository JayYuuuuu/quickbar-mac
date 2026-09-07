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
print("panel \(WheelGeo.panelSize)  anchor \(WheelGeo.anchor)")
check("原地不动",       0,    0,    nil)
check("正左甩 200",   -200,   0,    .browser)
check("正右甩 200",    200,   0,    .finder)
check("正上甩 200",      0,  200,   .document)
check("正下甩 200",      0, -200,   nil)
check("左格中心",     -210,   0,    .browser)
check("右格中心",      210,   0,    .finder)
check("上格中心",        0,   68,   .document)
check("左上斜甩 135", -300,  300,   .browser)
check("右上斜甩 45",   300,  300,   .finder)
check("偏上一点 70",   109,  300,   .document)
check("偏右一点 40",   300,  252,   .finder)
check("刚出死区·左",   -60,   0,    .browser)
check("死区内·左",     -40,   0,    nil)
check("甩很远·左",   -1500,  10,    .browser)
print(failed == 0 ? "全部通过" : "\(failed) 条不过")
exit(failed == 0 ? 0 : 1)
SWIFT

swift "$TMP"
