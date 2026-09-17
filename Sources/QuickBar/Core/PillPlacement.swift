import CoreGraphics

/// 药丸最后落在哪儿：先照锚点算一个位置，被宿主自己的其它窗口挡住了就挪到最近的空地方。
///
/// 纯几何，不碰 AppKit / AX —— 改完跑 `./Packaging/VerifyPillPlacement.sh`。
/// 坐标一律 AppKit（主屏左下为原点、y 向上），跟 `NSPanel.setFrameOrigin` 同一套。
///
/// 【为什么要躲】2026-09-17 用户实拍：访达往文件夹里移图，冒出来的「拷贝」进度框
/// 被药丸压住了进度条。一半是贴错了窗口（进度框抢成了访达的当前窗口，见 `WindowFollow`），
/// 另一半是就算贴对了浏览窗口，进度框也可能正好浮在它右下角上 —— 药丸是浮窗，
/// 排在所有窗口上面，压上去的就是人正盯着看的东西。
///
/// 【为什么是「挪最少的那个」】药丸的意义是「贴着这个窗口」，挪远了人就找不到它。
/// 所以只在四个方向上各试一个紧贴障碍物的位置，谁离原位近选谁；
/// 都放不下（屏幕边上挤满了）就留在原位 —— 盖住一点总比药丸没了强。
enum PillPlacement {

    /// 躲开之后跟障碍物之间留的缝。
    static let gap: CGFloat = 8

    /// - Parameters:
    ///   - preferred: 照锚点算出来的药丸矩形。
    ///   - obstacles: 挡在宿主窗口前面的、同一应用的其它窗口。
    ///   - bounds: 药丸能待的范围（所在屏幕的可见区域，已经留过边距）。
    /// - Returns: 药丸左下角该放的位置。
    static func origin(for preferred: CGRect, avoiding obstacles: [CGRect], within bounds: CGRect) -> CGPoint {
        let size = preferred.size
        let start = clamp(preferred.origin, size: size, into: bounds)
        guard blocked(CGRect(origin: start, size: size), by: obstacles) else { return start }

        var best: CGPoint?
        var bestDistance = CGFloat.infinity
        for ob in obstacles {
            let tries = [
                CGPoint(x: start.x, y: ob.maxY + gap),                  // 上
                CGPoint(x: start.x, y: ob.minY - size.height - gap),    // 下
                CGPoint(x: ob.minX - size.width - gap, y: start.y),     // 左
                CGPoint(x: ob.maxX + gap, y: start.y),                  // 右
            ]
            for t in tries {
                // 夹回屏幕会把它推回障碍物里 —— 那就是这个方向放不下，交给下面的判定去筛。
                let p = clamp(t, size: size, into: bounds)
                guard !blocked(CGRect(origin: p, size: size), by: obstacles) else { continue }
                let d = hypot(p.x - start.x, p.y - start.y)
                if d < bestDistance { best = p; bestDistance = d }
            }
        }
        return best ?? start
    }

    /// 🔴 判定放宽 1 点：候选位置正好离障碍物 `gap`，拿 `gap` 去比会压在边界上，
    ///    结果取决于浮点误差 —— 同一个位置有时算挡、有时算不挡，药丸就会来回跳。
    private static func blocked(_ r: CGRect, by obstacles: [CGRect]) -> Bool {
        obstacles.contains { $0.insetBy(dx: -(gap - 1), dy: -(gap - 1)).intersects(r) }
    }

    private static func clamp(_ p: CGPoint, size: CGSize, into b: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, b.minX), b.maxX - size.width),
                y: min(max(p.y, b.minY), b.maxY - size.height))
    }
}
