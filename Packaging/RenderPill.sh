#!/bin/bash
# 把药丸的各个状态离屏渲染成 PNG，用来核对它跟设计稿长得一样不一样。
#
# 为什么需要它：这台构建机只能 ssh 进去，**`screencapture` 在 ssh 会话里截不到屏**
# （报 could not create image from display）。而药丸是一颗浮窗，改错了颜色层次
# （1.15.1 就把实色填充排到了毛玻璃下面）从外面一点都看不出来。
# 这个脚本把 PillView 原样编进一个小程序里跑一遍，产物就是它真实的绘制结果。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/RenderPill.sh'   # 出图在 /tmp/pill/
#   scp mac24g:'/tmp/pill/*.png' .                                # 取回来看
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/pill}"
TMP="$(mktemp -d)/render.swift"

# 🔴 直接把产品代码接进来，不另抄一份 —— 抄一份就会跟实现漂移，
#    那时候渲染出来的是"曾经的设计"，比不渲染更误导。
cat Sources/QuickBar/UI/PillView.swift > "$TMP"
cat >> "$TMP" <<'SWIFT'

func shot(_ title: String, _ style: PillView.Style, _ frac: CGFloat,
          _ hover: Bool, _ press: Bool, dark: Bool, file: String, dir: String) {
    _ = NSApplication.shared
    let v = PillView(frame: NSRect(x: 0, y: 0, width: 200, height: PillView.height))
    v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    v.set(title: title, style: style, fraction: frac, animateText: false)
    v.frame = NSRect(origin: .zero, size: v.intrinsicContentSize)
    v.layoutSubtreeIfNeeded()
    if hover || press { v.mouseEntered(with: NSEvent()) }
    if press { v.mouseDown(with: NSEvent()) }
    v.layout()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    // 垫一块中性底，好看清药丸自己的颜色（浅色垫浅灰、深色垫深灰）
    let size = v.bounds.size
    let canvas = NSImage(size: NSSize(width: size.width + 40, height: size.height + 30))
    canvas.lockFocus()
    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()
    rep.draw(in: NSRect(x: 20, y: 15, width: size.width, height: size.height))
    canvas.unlockFocus()
    if let t = canvas.tiffRepresentation, let b = NSBitmapImageRep(data: t),
       let png = b.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/pill"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
shot("主图丢进 PS · 3 件 6 张", .action, 0,   false, false, dark: false, file: "1-常态-浅", dir: dir)
shot("主图丢进 PS · 3 件 6 张", .action, 0,   true,  false, dark: false, file: "2-悬停-浅", dir: dir)
shot("主图丢进 PS · 3 件 6 张", .action, 0,   false, true,  dark: false, file: "3-按下-浅", dir: dir)
shot("存回原位 · 还剩 12 张",   .action, 0.4, false, false, dark: true,  file: "4-进度-深", dir: dir)
shot("存回中…",                 .busy,   0,   false, false, dark: true,  file: "5-存回中-深", dir: dir)
shot("都存回了",                .done,   1,   false, false, dark: true,  file: "6-完成-深", dir: dir)
print("出图 -> \(dir)")
SWIFT

rm -rf "$OUT"
swift "$TMP" "$OUT"
ls "$OUT"
