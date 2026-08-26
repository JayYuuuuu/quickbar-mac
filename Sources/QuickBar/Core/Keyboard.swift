import AppKit

/// 合成按键。所有我们自己发出的事件都打上标记，
/// 这样自家的事件 tap 一眼就能认出来并放行，不会自己咬自己。
enum Keyboard {
    static let g: CGKeyCode = 5
    static let v: CGKeyCode = 9
    static let enter: CGKeyCode = 36
    static let escape: CGKeyCode = 53

    /// 塞进 eventSourceUserData 的暗号，认自家事件用。
    static let signature: Int64 = 0x5155_4943_4B42   // "QUICKB"

    private static let source = CGEventSource(stateID: .hidSystemState)

    static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: signature)
            event.post(tap: .cghidEventTap)
        }
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == signature
    }
}

/// 把 `NSEvent.ModifierFlags` / `CGEventFlags` 显示成 ⌘⌥⌃⇧ 的样子。
enum KeySymbols {
    static func describe(flags: CGEventFlags, keyCode: CGKeyCode) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + (name(for: keyCode) ?? "?")
    }

    static func name(for keyCode: CGKeyCode) -> String? {
        let map: [CGKeyCode: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            36: "↩", 48: "⇥", 49: "空格", 53: "esc",
            // 功能键那排。🔴 **F13–F20 的键码不连号**（实测 SDK 的 HIToolbox/Events.h），
            // 别按 F13+n 推。少了这几条，设置页和药丸上的快捷键会显示成「?」。
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        return map[keyCode]
    }
}
