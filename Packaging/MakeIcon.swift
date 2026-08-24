#!/usr/bin/env swift
// 生成 AppIcon.icns。图形和菜单栏图标同一套形：三条横杠 + 一个右尖角。
// 单独跑：swift Packaging/MakeIcon.swift <输出目录>

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 图形和菜单栏模板图同一套形：**三条等长的横杠 + 一个右尖角**
/// （「三个常去的地方」＋「往那边去」），只是加了容器、描边加粗。版式来自设计稿
/// `QuickBar 快捷条.dc.html` 的 `1g Icon`。
///
/// 🔴 **描边随尺寸变粗**：128 档 1.25、64 档 1.35、32 档 1.6、16 档 2（都是 16 格坐标下的值）。
///    照着大图等比缩下去，16pt 上三条杠会糊成一坨灰。
/// 🔴 **不加内阴影、不加高光斜切**，只有顶部一条 1px 内高光 —— 那两样在小尺寸上
///    只会变成脏边（设计稿便签的原话）。
func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size
        let u = s / 16                       // 设计稿是在 16×16 的格子里画的
        // macOS Big Sur 之后的圆角矩形：图标本体占画布 ~90%，圆角 22.7%
        let inset = s * 0.05
        let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let body = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2266, yRadius: rect.width * 0.2266)

        // 上浅下深的蓝（设计稿的 oklch(64% .18 258) → oklch(46% .18 264)）
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSGradient(starting: NSColor(srgbRed: 62 / 255, green: 137 / 255, blue: 247 / 255, alpha: 1),
                   ending: NSColor(srgbRed: 33 / 255, green: 77 / 255, blue: 186 / 255, alpha: 1))?
            .draw(in: rect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // 顶部 1px 内高光。就这一条，不再加别的立体感。
        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0),
                                     xRadius: rect.width * 0.2266, yRadius: rect.width * 0.2266)
        highlight.lineWidth = max(1, s / 256)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)).addClip()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        highlight.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // 描边宽度按档位给（见文件头第一条）
        let stroke: CGFloat
        switch s {
        case ..<24:  stroke = 2.0
        case ..<48:  stroke = 1.6
        case ..<96:  stroke = 1.35
        default:     stroke = 1.25
        }
        // 小尺寸上把杠收短一点，免得贴到圆角边上
        let x0: CGFloat = s < 24 ? 3.6 : (s < 48 ? 3.2 : 3.0)
        let x1: CGFloat = s < 24 ? 8.6 : (s < 48 ? 9.2 : 9.6)
        let ys: [CGFloat] = s < 24 ? [5, 8, 11] : (s < 48 ? [4.6, 8, 11.4] : [4.4, 8, 11.6])

        let glyph = NSBezierPath()
        for y in ys {
            // 🔴 AppKit 的 y 向上、设计稿的 SVG y 向下。三条杠对 y=8 是对称的，
            //    翻不翻都一样；尖角也对称。所以这里直接照抄坐标。
            glyph.move(to: NSPoint(x: x0 * u, y: y * u))
            glyph.line(to: NSPoint(x: x1 * u, y: y * u))
        }
        let cx0: CGFloat = s < 24 ? 11.4 : (s < 48 ? 11.6 : 11.8)
        let cx1: CGFloat = s < 24 ? 13.0 : (s < 48 ? 13.6 : 14.0)
        let dy: CGFloat = s < 24 ? 1.8 : (s < 48 ? 2.2 : 2.5)
        glyph.move(to: NSPoint(x: cx0 * u, y: (8 - dy) * u))
        glyph.line(to: NSPoint(x: cx1 * u, y: 8 * u))
        glyph.line(to: NSPoint(x: cx0 * u, y: (8 + dy) * u))

        glyph.lineWidth = stroke * u
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        NSColor.white.setStroke()
        glyph.stroke()
        return true
    }
    return image
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let image = draw(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: iconset.appendingPathComponent("\(name).png"))
}

print("iconset -> \(iconset.path)")
