#!/bin/bash
# 剪贴板跳转的「这串东西算不算一条路径」：跑一遍断言。
#
# 为什么值得有这么个脚本：这个判断同时决定**吞不吞掉 ⌘⇧G**。判松了，别的应用的
# 「查找上一个」会莫名其妙失灵；判紧了，人按下去没反应。两种都表现为「它很随机」——
# 最难从反馈里查回来的那一类。判断是纯函数，一秒钟全测一遍，没有理由靠推理。
#
#   ssh mac24g 'cd ~/quickbar-mac && ./Packaging/VerifyClipboardJump.sh'
set -euo pipefail
# 同 build.sh：Xcode 许可没同意时 swift / swiftc 一律拒跑，命令行工具那套不受影响
[ -d /Library/Developer/CommandLineTools ] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)/clip.swift"

# 🔴 从产品代码里抠，不另抄一份 —— 抄一份测的就不是真正在跑的那套。
{
  echo 'import Foundation'
  echo 'enum URLScheme {'
  awk '/^    static func allowed\(/{f=1} f{print} f&&/^    \}$/{exit}' Sources/QuickBar/Core/URLScheme.swift
  echo '}'
  echo 'enum Clip {'
  awk '/^    private static func clean\(/{f=1} f{print} f&&/^    \}$/{exit}' Sources/QuickBar/Core/ClipboardJump.swift \
    | sed 's/^    private static func clean/    static func clean/'
  echo '}'
} > "$TMP"

cat >> "$TMP" <<'SWIFT'
let home = FileManager.default.homeDirectoryForCurrentUser.path
var failed = 0
var total = 0

/// want == nil 表示「不该认」；否则是折平之后应该得到的那条路径。
func check(_ name: String, _ raw: String, _ want: String?) {
    let got = URLScheme.allowed(Clip.clean(raw))?.path
    let ok = got == want
    total += 1
    if !ok { failed += 1 }
    let shown = raw.replacingOccurrences(of: "\n", with: "\\n")
    print("\(ok ? "OK  " : "FAIL") \(name)  「\(shown)」-> \(got ?? "不认")  期望 \(want ?? "不认")")
}

// 该认的：网页上「复制路径」给出来的就是第一条这个样子。
check("素材盘上的视频", "/Volumes/拍摄源文件/2026/视频素材8月/2026-08-16 002537.mov",
      "/Volumes/拍摄源文件/2026/视频素材8月/2026-08-16 002537.mov")
check("前后带空白", "  /Volumes/x/y\n", "/Volumes/x/y")
check("包着双引号", "\"/Volumes/x/y\"", "/Volumes/x/y")
check("包着单引号", "'/Volumes/x/y'", "/Volumes/x/y")
check("file:// 且中文转义过", "file:///Volumes/%E6%8B%8D%E6%91%84/a.mov", "/Volumes/拍摄/a.mov")
check("家目录下的", "~/Desktop", home + "/Desktop")
check("家目录本身", home, home)

// 不该认的：认了就等于把别人的「查找上一个」抢走。
check("普通文本", "复制路径", nil)
check("网址", "https://ai.yujiev.com:8444/dipdip-playbook.html", nil)
check("空", "", nil)
check("只有空白", "   \n  ", nil)
check("一段话里夹着路径", "看这个 /Volumes/x/y 挺好", nil)
check("路径后面还跟着一行", "/Volumes/x/y\n还有别的", nil)
check("系统目录", "/etc/passwd", nil)
check("根", "/", nil)
// 🔴 `..` 折平之后再判前缀，绕不过去 —— 这个入口是任何人都能往剪贴板里塞东西的。
check("拿 .. 爬出素材盘", "/Volumes/x/../../etc/passwd", nil)
check("相对路径", "Volumes/x/y", nil)

print(failed == 0 ? "\n全过（\(total) 条）" : "\n\(failed)/\(total) 条没过")
exit(failed == 0 ? 0 : 1)
SWIFT

swiftc -O -o "${TMP%.swift}" "$TMP" && "${TMP%.swift}"
