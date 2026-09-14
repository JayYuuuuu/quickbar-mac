#!/bin/bash
# 「什么时候向 PS 问一次还剩几张」：跑一遍断言，再拿同一段模拟输入比新旧两套规则各问几次。
#
# 为什么值得有这个脚本：问少了，药丸该出来不出来、数字不对；问多了，人修图时 PS 被一直打扰
# （2026-09-14 顾婉娜那台：两三秒一发，PS 偶尔回 -1750，旧版每次都弹框）。
# 两种都表现成「它很随机」，而这是纯逻辑，造输入跑一遍就全测到了。
#
# ⚠️ 模拟那半是**模拟**：输入节奏是写死的假设（见 scenario），数只说明两套规则在同一段输入下差多少，
#    不代表真人一天发多少。真实数字要去用户机器上看 AE 日志（见 CLAUDE.md「远程看 AE 往返的真实耗时」）。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/VerifyPSSyncPolicy.sh'
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)/policy.swift"

# 🔴 整个文件原样拿来，不另抄一份 —— 抄一份测的就不是真正在跑的那套。
cat Sources/QuickBar/Core/PSSyncPolicy.swift > "$TMP"

cat >> "$TMP" <<'SWIFT'

// ── 断言 ─────────────────────────────────────────────────────────────
let win = CGRect(x: 0, y: 25, width: 2560, height: 1415)   // PS 窗口（Quartz 坐标）
var failed = 0, total = 0
var windowReads = 0
func winProvider() -> CGRect? { windowReads += 1; return win }
func check(_ name: String, _ got: Bool, _ want: Bool) {
    total += 1
    if got != want { failed += 1 }
    print("\(got == want ? "OK  " : "FAIL") \(name)  -> \(got)  期望 \(want)")
}
func mouse(_ from: CGPoint?, _ to: CGPoint) -> UserInput { UserInput(kind: .mouseUp(down: from, up: to)) }
func key(_ code: CGKeyCode, cmd: Bool = false) -> UserInput { UserInput(kind: .key(code: code, command: cmd)) }
func may(_ i: UserInput) -> Bool { PSSyncPolicy.mayChangeDocuments(i, psWindow: winProvider) }

let canvasA = CGPoint(x: 900, y: 700), canvasB = CGPoint(x: 1100, y: 760)

check("点标签页上的 ×（窗口里点一下）", may(mouse(CGPoint(x: 800, y: 60), CGPoint(x: 800, y: 60))), true)
check("数位笔点一下抖了 3 个点，仍算点", may(mouse(canvasA, CGPoint(x: 902, y: 702))), true)
check("在画布上画一笔", may(mouse(canvasA, canvasB)), false)
check("从 PS 窗口外（访达后台窗口）拖进来", may(mouse(CGPoint(x: 2600, y: 400), canvasA)), true)
check("拿不到 PS 窗口位置时，拖也算",
      PSSyncPolicy.mayChangeDocuments(mouse(canvasA, canvasB), psWindow: { nil }), true)
check("右键（没有按下位置）", may(mouse(nil, canvasA)), true)
check("⌘W", may(key(13, cmd: true)), true)
check("⌘Z（接受算进来）", may(key(6, cmd: true)), true)
check("B 键换画笔", may(key(11)), false)
check("[ 调笔刷大小", may(key(33)), false)
check("空格（抓手）", may(key(49)), false)
check("F15 存回原位（存回自己会校准）", may(key(113)), false)
check("回车（对话框）", may(key(36)), true)
check("小键盘回车", may(key(76)), true)
check("Esc", may(key(53)), true)
windowReads = 0
_ = may(mouse(canvasA, canvasA)); _ = may(key(13, cmd: true)); _ = may(key(11)); _ = may(mouse(nil, canvasA))
check("点和按键不去读窗口位置（不为每一下付一次 AX）", windowReads == 0, true)
check("动过：2.1 秒该问", PSSyncPolicy.due(sinceLastSync: 2.1, dirty: true, hasRemaining: true), true)
check("动过：1.9 秒不问", PSSyncPolicy.due(sinceLastSync: 1.9, dirty: true, hasRemaining: true), false)
check("没动、药丸没出来：29 秒不问", PSSyncPolicy.due(sinceLastSync: 29, dirty: false, hasRemaining: false), false)
check("没动、药丸没出来：31 秒该问", PSSyncPolicy.due(sinceLastSync: 31, dirty: false, hasRemaining: false), true)
check("没动、药丸在：59 秒不问", PSSyncPolicy.due(sinceLastSync: 59, dirty: false, hasRemaining: true), false)
check("没动、药丸在：61 秒该问", PSSyncPolicy.due(sinceLastSync: 61, dirty: false, hasRemaining: true), true)

// ── 模拟：同一段 10 分钟输入，新旧两套规则各问 PS 几次 ─────────────────────
// 跟 MainImagesPill 一致的节奏：心跳每 1.5 秒一跳；被认下的输入另外在 0.12 秒后补一跳；
// t=0 刚切到 PS 时问一发（新规则 2 秒后再补一发）。PS 回话按即时算，药丸一直有数。
// 旧规则（v1.18 ~ v1.24.1）已经从代码里删了，这里照原样写：任何输入都算，间隔 2 / 10 / 30 秒。
struct Ev { let t: Double; let input: UserInput }

/// 假设的一段修图：每分钟干 45 秒、停 15 秒看图；干的时候每 1.3 秒一下（画一笔或点一下）；
/// 每 20 秒点一次工具栏，每 45 秒 ⌘Z，每 60 秒按一次 F15 存回。
func scenario(taps: Bool) -> [Ev] {
    var evs: [Ev] = []
    var t = 1.0
    while t < 600 {
        if t.truncatingRemainder(dividingBy: 60) < 45 {
            evs.append(Ev(t: t, input: taps ? mouse(canvasA, canvasA) : mouse(canvasA, canvasB)))
        }
        t += 1.3
    }
    for s in stride(from: 10.0, to: 600, by: 20) { evs.append(Ev(t: s, input: mouse(CGPoint(x: 30, y: 300), CGPoint(x: 30, y: 300)))) }
    for s in stride(from: 17.0, to: 600, by: 45) { evs.append(Ev(t: s, input: key(6, cmd: true))) }
    for s in stride(from: 55.0, to: 600, by: 60) { evs.append(Ev(t: s, input: key(113))) }
    return evs.sorted { $0.t < $1.t }
}

enum Item { case tick, input(Bool) }

func simulate(_ evs: [Ev], old: Bool) -> Int {
    var items: [(Double, Item)] = stride(from: 1.5, to: 600, by: 1.5).map { ($0, .tick) }
    for e in evs {
        let counts = old ? true : PSSyncPolicy.mayChangeDocuments(e.input, psWindow: { win })
        items.append((e.t, .input(counts)))
        if counts { items.append((e.t + 0.12, .tick)) }
    }
    items.sort { $0.0 < $1.0 }
    var asks = 1, last = 0.0, dirty = !old
    for (t, item) in items {
        switch item {
        case .input(let counts):
            if counts { dirty = true }
        case .tick:
            let due = old ? (t - last) > (dirty ? 2 : 30)
                          : PSSyncPolicy.due(sinceLastSync: t - last, dirty: dirty, hasRemaining: true)
            if due { asks += 1; last = t; dirty = false }
        }
    }
    return asks
}

print("")
for (name, taps) in [("拖着画为主", false), ("一下一下点为主（污点修复那种）", true)] {
    let evs = scenario(taps: taps)
    print("模拟 · \(name)：10 分钟 \(evs.count) 下输入 → 旧规则问 PS \(simulate(evs, old: true)) 次，新规则 \(simulate(evs, old: false)) 次")
}

print(failed == 0 ? "\n断言全过（\(total) 条）" : "\n\(failed)/\(total) 条没过")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "${TMP%.swift}" "$TMP" && "${TMP%.swift}"
