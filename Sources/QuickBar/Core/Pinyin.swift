import Foundation

/// 汉字转拼音，给快捷条的筛选用。
///
/// 用系统自带的 `CFStringTransform`（底层是 ICU），不引第三方词库：
/// 「下载」→ 转写成 `xià zài` → 去掉声调 → `xia zai`，
/// 于是全拼是 `xiazai`、首字母是 `xz`，两种都能命中。
///
/// 多音字按 ICU 的默认读音走，偶尔会不准（比如「重」固定读 zhòng）。
/// 对筛选这个场景够用——反正名字里还能用别的片段命中。
enum Pinyin {

    /// 一个条目的全部可匹配片段。
    struct Keys {
        let name: String       // 原名，小写
        let full: String       // 全拼，无分隔
        let initials: String   // 首字母
    }

    private static var cache: [String: Keys] = [:]

    static func keys(for text: String) -> Keys {
        if let hit = cache[text] { return hit }
        let computed = compute(text)
        cache[text] = computed
        return computed
    }

    private static func compute(_ text: String) -> Keys {
        let lower = text.lowercased()
        guard containsHan(text) else {
            return Keys(name: lower, full: lower, initials: lower)
        }

        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable as CFMutableString, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable as CFMutableString, nil, kCFStringTransformStripDiacritics, false)

        let syllables = tokenize(mutable as String)
        return Keys(
            name: lower,
            full: syllables.joined(),
            initials: String(syllables.compactMap(\.first))
        )
    }

    /// 转写结果里音节是用空格隔开的，但数字会和后面的音节粘在一起
    /// （"2026秋新品" 转出来是 "2026qiu xin pin"，首字母会少一个 q）。
    /// 所以字母段和数字段各自成词，其余字符一律当分隔符。
    private static func tokenize(_ romanized: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsDigit = false

        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }

        for character in romanized.lowercased() {
            if character.isLetter {
                if currentIsDigit { flush() }
                currentIsDigit = false
                current.append(character)
            } else if character.isNumber {
                if !currentIsDigit { flush() }
                currentIsDigit = true
                current.append(character)
            } else {
                flush()
                currentIsDigit = false
            }
        }
        flush()
        return tokens
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)      // 基本汉字
                || (0x3400...0x4DBF).contains(scalar.value)   // 扩展 A
                || (0xF900...0xFAFF).contains(scalar.value)   // 兼容汉字
        }
    }

    /// 打分：数字越小越贴切，nil 表示不匹配。
    ///
    /// 前缀命中排在包含命中前面——输 `xz` 的时候「下载」应该在
    /// 某个路径里碰巧含 xz 的条目上面。
    static func score(name: String, path: String, needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let keys = keys(for: name)
        let lowerPath = path.lowercased()

        if keys.name.hasPrefix(needle) { return 0 }
        if keys.full.hasPrefix(needle) { return 1 }
        if keys.initials.hasPrefix(needle) { return 2 }
        if keys.name.contains(needle) { return 3 }
        if keys.full.contains(needle) { return 4 }
        if keys.initials.contains(needle) { return 5 }
        if lowerPath.contains(needle) { return 6 }
        return nil
    }
}
