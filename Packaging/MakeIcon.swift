#!/usr/bin/env swift
// 生成 AppIcon.icns。图形和菜单栏图标同一套形：三条横杠 + 一个右尖角。
// 单独跑：swift Packaging/MakeIcon.swift <输出目录>

import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size
        // macOS 圆角矩形底
        let inset = s * 0.06
        let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
                                xRadius: s * 0.2235, yRadius: s * 0.2235)
        NSColor(calibratedRed: 0.04, green: 0.42, blue: 1.0, alpha: 1).setFill()
        body.fill()

        NSColor.white.setFill()
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.62, 0.34, 1.0),
            (0.455, 0.46, 0.78),
            (0.29, 0.25, 0.55)
        ]
        for (y, width, alpha) in bars {
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: s * 0.23, y: s * y, width: s * width, height: s * 0.078),
                         xRadius: s * 0.039, yRadius: s * 0.039).fill()
        }

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: s * 0.655, y: s * 0.375))
        chevron.line(to: NSPoint(x: s * 0.745, y: s * 0.295))
        chevron.line(to: NSPoint(x: s * 0.655, y: s * 0.215))
        chevron.lineWidth = s * 0.062
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.white.setStroke()
        chevron.stroke()
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
