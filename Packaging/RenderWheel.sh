#!/bin/bash
# 把三向甩那块浮窗离屏渲染成 PNG，用来核对绘制层次和排版。
#
# 跟 RenderPill.sh 同一个理由：这台构建机只能 ssh 进去，**`screencapture` 在 ssh 会话里截不到屏**
# （报 could not create image from display）。而它是一块浮窗，格子排错了、选中态糊在底色里，
# 从外面一点都看不出来。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/RenderWheel.sh'   # 出图在 /tmp/wheel/
#   scp mac24g:'/tmp/wheel/*.png' .                                # 取回来看
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/wheel}"
TMP="$(mktemp -d)/render.swift"

# 🔴 直接从产品代码里抠，不另抄一份 —— 抄一份就会跟实现漂移，
#    那时候渲染出来的是"曾经的设计"，比不渲染更误导。
#    这两段是：SwitchLane / SwitchTarget（WindowSwitch.swift 顶部）
#    + 几何和绘制那半（SwitchWheel.swift 从「MARK: - 几何」到结尾）。
#    🔴 抠的范围要跟着代码走：几何常量一度被挪进 WheelGeo，这里还停在「MARK: - 画」，
#       结果脚本编不过（cannot find 'ListGeo' in scope）。改版式先看一眼这两行 awk。
awk '/^@MainActor$/{exit} {print}' Sources/QuickBar/Core/WindowSwitch.swift > "$TMP"
awk '/^\/\/ MARK: - 几何/{f=1} f{print}' Sources/QuickBar/UI/SwitchWheel.swift >> "$TMP"

cat >> "$TMP" <<'SWIFT'

func icon(_ bundleID: String) -> NSImage? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    return NSWorkspace.shared.icon(forFile: url.path)
}

func shot(_ selected: SwitchLane?, dark: Bool, empty: Bool = false, file: String, dir: String) {
    _ = NSApplication.shared
    var targets: [SwitchLane: SwitchTarget] = [:]
    if !empty {
        targets[.browser] = SwitchTarget(pid: 1, appName: "Google Chrome",
                                         icon: icon("com.google.Chrome"),
                                         windowTitle: "货品全站推广_万相台无界版")
        targets[.document] = SwitchTarget(pid: 2, appName: "wpsoffice",
                                          icon: icon("com.kingsoft.wpsoffice.mac"),
                                          windowTitle: "2026 秋季报价单.docx")
        targets[.finder] = SwitchTarget(pid: 3, appName: "访达",
                                        icon: icon("com.apple.finder"),
                                        windowTitle: "20260903-1054_LC-0902-0D76")
    }

    let v = WheelView(frame: NSRect(origin: .zero, size: WheelView.panelSize))
    v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    v.update(targets: targets, selected: selected)
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)

    // 垫一块中性底 —— 面板自己的毛玻璃是透明的，不垫底看不出格子的深浅关系。
    let size = v.bounds.size
    let canvas = NSImage(size: NSSize(width: size.width + 40, height: size.height + 40))
    canvas.lockFocus()
    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()
    rep.draw(in: NSRect(x: 20, y: 20, width: size.width, height: size.height))
    canvas.unlockFocus()
    if let t = canvas.tiffRepresentation, let b = NSBitmapImageRep(data: t),
       let png = b.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
    }
}

func shotList(_ lane: SwitchLane, _ rows: [(String?, String, String)], index: Int, dark: Bool, file: String, dir: String) {
    _ = NSApplication.shared
    let members = rows.map { r in
        SwitchTarget(pid: 1, action: .app, appName: r.1, icon: icon(r.2),
                     windowTitle: r.1, badge: r.0)
    }
    let size = ListGeo.panelSize(members.count)
    let v = WheelView(frame: NSRect(origin: .zero, size: size))
    v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    v.update(lane: lane, members: members, index: index)
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let canvas = NSImage(size: NSSize(width: size.width + 40, height: size.height + 40))
    canvas.lockFocus()
    (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.90, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: canvas.size)).fill()
    rep.draw(in: NSRect(x: 20, y: 20, width: size.width, height: size.height))
    canvas.unlockFocus()
    if let t = canvas.tiffRepresentation, let b = NSBitmapImageRep(data: t),
       let png = b.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/\(file).png"))
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/wheel"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
shot(nil,        dark: false, file: "1-刚弹出-浅", dir: dir)
shot(.browser,   dark: false, file: "2-甩左浏览器-浅", dir: dir)
shot(.document,  dark: true,  file: "3-甩上文档-深", dir: dir)
shot(.finder,    dark: true,  file: "4-甩右访达-深", dir: dir)
shot(.browser,   dark: false, empty: true, file: "5-一个都没开-浅", dir: dir)

let chrome = "com.google.Chrome"
shotList(.browser, [
    ("C店", "货品全站推广_万相台无界版", chrome),
    ("天猫", "聚水潭商品管理 · AI 电商内容助手", chrome),
    ("买家号", "淘宝网 - 淘！我喜欢", chrome),
    ("Dip", "收件箱 - aisjmy@gmail.com - Gmail", chrome),
    (nil, "Client Area - DMIT, Inc.", chrome),
], index: 0, dark: false, file: "6-摊开浏览器-浅", dir: dir)

shotList(.finder, [
    (nil, "20260903-1054_LC-0902-0D76", "com.apple.finder"),
    (nil, "2026-09", "com.apple.finder"),
    (nil, "主图1比1", "com.apple.finder"),
], index: 1, dark: true, file: "7-摊开访达-深", dir: dir)

shotList(.document, [
    ("wpsoffice", "2026 秋季报价单.docx", "com.kingsoft.wpsoffice.mac"),
    ("wpsoffice", "库存盘点表.xlsx", "com.kingsoft.wpsoffice.mac"),
    ("wpsoffice", "供应商合同.docx", "com.kingsoft.wpsoffice.mac"),
], index: 2, dark: false, file: "8-摊开文档-浅", dir: dir)
print("出图 -> \(dir)")
SWIFT

rm -rf "$OUT"
swift "$TMP" "$OUT"
ls "$OUT"
