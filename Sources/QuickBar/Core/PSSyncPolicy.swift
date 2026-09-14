import CoreGraphics
import Foundation

/// 事件 tap 看到的一下输入。只留判断「PS 里开着几张图会不会变」要用的那几样。
/// 坐标一律是 Quartz 全局坐标（主屏左上角为原点、y 向下），跟 `CGEvent.location` 一致。
struct UserInput {
    enum Kind {
        /// 松开了鼠标。`down` 是按下那一刻的位置；右键、或者没看到那次按下，就是 nil。
        case mouseUp(down: CGPoint?, up: CGPoint)
        /// 按下了一个键。`command`：当时按着 ⌘。
        case key(code: CGKeyCode, command: Bool)
    }
    let kind: Kind
}

/// 什么时候向 PS 问一次「还开着几张能存回的图」（药丸上那个数）。
///
/// 纯逻辑，不碰 AppKit —— 改完跑 `./Packaging/VerifyPSSyncPolicy.sh`。
///
/// 【为什么不再是「人一动就问」】v1.18 起任何一次松开鼠标 / 按键都算（最多 2 秒一发）。
/// 可人在 PS 里绝大多数输入是**在画布上画**，画一笔不会让文档数变。
/// 2026-09-14 顾婉娜那台（数位笔修图）：她修图时 QuickBar 两三秒就问 PS 一次，
/// PS 偶尔回 -1750、偶尔 4~7 秒才回 —— 问得越勤，撞上得越多。
///
/// 文档数只会被这几样改变，所以只认这几样：
/// · **点**（按下到松开几乎没挪）：标签页上的 ×、菜单、对话框里的「不存储」、最近打开的文件；
/// · **⌘ 组合键**：⌘W / ⌘O / ⌘N / ⌘⇧S…（⌘Z 也会被算进来，那个频率可以接受，不值得开名单）；
/// · **回车 / Esc**：对话框用键盘答的那一下；
/// · **从 PS 窗口外面开始的拖**：从访达后台窗口把图拖进 PS，PS 不会被激活，只有这一下看得见。
/// 切到 PS 那一刻另有激活通知接着（见 `MainImagesPill.tick`），不归这里管。
enum PSSyncPolicy {

    /// 人刚做了一下「可能改了文档数」的操作：两发之间至少隔这么久。
    static let afterInput: TimeInterval = 2
    /// 没人动过、药丸没浮出来时的兜底。
    static let idleHidden: TimeInterval = 30
    /// 没人动过、药丸已经在屏幕上时的兜底。再问只是纠正数字，慢一点没人察觉。
    static let idleShown: TimeInterval = 60
    /// 按下到松开挪过这么多点才算「拖」。数位笔点一下会抖一两个点。
    static let dragThreshold: CGFloat = 6

    /// 这一下输入会不会改变 PS 里开着几张图。
    ///
    /// - Parameter psWindow: PS 最前窗口的矩形（Quartz 坐标）。**只有拖的时候才会被调用** ——
    ///   它背后是一次跨进程 AX 读取，点和按键用不着它，不该为每一下输入付这个钱。
    static func mayChangeDocuments(_ input: UserInput, psWindow: () -> CGRect?) -> Bool {
        switch input.kind {
        case let .key(code, command):
            // 36 回车、76 小键盘回车、53 Esc
            return command || code == 36 || code == 76 || code == 53
        case let .mouseUp(down, up):
            guard let down else { return true }
            if hypot(up.x - down.x, up.y - down.y) <= dragThreshold { return true }
            // 🔴 拿不到窗口在哪就当它可能改了：宁可多问一发，也别让药丸该出来的时候不出来。
            guard let window = psWindow() else { return true }
            return !window.contains(down)
        }
    }

    /// 这一跳该不该问。
    /// - Parameter dirty: 上次问过之后，有过一下 `mayChangeDocuments` 为真的输入（或者刚切到 PS）。
    /// - Parameter hasRemaining: 药丸上现在有数（`Photoshop.remaining > 0`）。
    static func due(sinceLastSync: TimeInterval, dirty: Bool, hasRemaining: Bool) -> Bool {
        sinceLastSync > (dirty ? afterInput : (hasRemaining ? idleShown : idleHidden))
    }
}
