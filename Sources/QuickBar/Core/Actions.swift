import AppKit

/// 快捷条点下去之后真正干的事。
enum Actions {

    /// 在 Finder 里打开文件夹。
    ///
    /// 刻意复用当前窗口而不是 `NSWorkspace.open`（那个会新开一个窗口，
    /// 尺寸回到默认值）——「跳转了窗口尺寸也保持住」就是靠这个。
    static func openFolder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let escaped = expanded.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            if (count of Finder windows) = 0 then
                make new Finder window to (POSIX file "\(escaped)" as alias)
            else
                set target of front Finder window to (POSIX file "\(escaped)" as alias)
            end if
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            // 没有自动化授权时退回系统默认行为。
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        }
    }

    /// 已经在跑就切到前台，没跑就启动。
    ///
    /// macOS 14 起跨应用激活是**协作式**的：像 QuickBar 这种后台程序直接调
    /// `NSRunningApplication.activate()` 会被系统静默忽略——不报错，就是不切。
    /// 所以要先 `yieldActivation` 把激活权让出去，并且真正的切换交给
    /// LaunchServices（`openApplication`）来做，它是唯一稳的路径。
    /// 已经在跑的普通应用不会被开第二个，只会被带到前台。
    static func launchOrActivate(_ item: QuickItem) {
        let running = runningInstance(of: item)

        if #available(macOS 14.0, *) {
            if let running {
                NSApp.yieldActivation(to: running)
            } else if let bundleID = item.bundleID {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID)
            }
        }

        // 最小化或隐藏过的先恢复，否则切过去看不见窗口。
        running?.unhide()

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: item.url, configuration: config) { app, error in
            if let error {
                NSLog("[QuickBar] 切换到 \(item.name) 失败: \(error.localizedDescription)")
                return
            }
            // LaunchServices 偶尔只是把进程带起来而没抢到前台，补一刀。
            guard let app else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if !app.isActive { app.activate(options: [.activateAllWindows]) }
            }
        }
    }

    static func runningInstance(of item: QuickItem) -> NSRunningApplication? {
        if let bundleID = item.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == item.path }
    }

    static func isRunning(_ item: QuickItem) -> Bool {
        item.kind == .app && runningInstance(of: item) != nil
    }

    /// 快捷条里选中一项之后的统一入口：按当前上下文决定是跳转还是打开。
    static func activate(_ item: QuickItem) {
        switch item.kind {
        case .app:
            launchOrActivate(item)
        case .folder:
            if PanelService.shared.currentPanel() != nil {
                PanelService.shared.jump(to: item.path)
            } else {
                openFolder(item.path)
            }
        }
    }
}
