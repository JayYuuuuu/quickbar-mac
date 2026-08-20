import AppKit
import ApplicationServices

/// Accessibility API 的一层薄封装。
///
/// 只做两件事：把 C 味的 `AXUIElementCopyAttributeValue` 包成 Swift 泛型，
/// 以及给系统级元素设一个消息超时——AX 调用是跨进程 IPC，
/// 对面 app 卡住时如果不设超时，我们自己的事件 tap 会被系统判定超时直接禁用。
enum AX {

    /// 面板判定要在事件 tap 回调里跑，这个超时是保命用的。
    static let messagingTimeout: Float = 0.25

    static let systemWide: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
        return el
    }()

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let arr = raw as? [AXUIElement] else { return [] }
        return arr
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute)
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw) == .success else { return nil }
        var out = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &out) else { return nil }
        return out
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &raw) == .success else { return nil }
        var out = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &out) else { return nil }
        return out
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setString(_ element: AXUIElement, _ attribute: String, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, text as CFTypeRef) == .success
    }

    /// 是否已获得「辅助功能」授权。`prompt` 为真时会弹系统授权框。
    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// 属性名里没有常量的那几个，集中放这儿，避免到处写魔法字符串。
enum AXAttr {
    static let identifier = "AXIdentifier"
    static let focusedApplication = kAXFocusedApplicationAttribute
    static let focusedWindow = kAXFocusedWindowAttribute
    static let focusedUIElement = kAXFocusedUIElementAttribute
    static let role = kAXRoleAttribute
    static let subrole = kAXSubroleAttribute
    static let windows = kAXWindowsAttribute
    static let children = kAXChildrenAttribute
    static let value = kAXValueAttribute
    static let title = kAXTitleAttribute
}
